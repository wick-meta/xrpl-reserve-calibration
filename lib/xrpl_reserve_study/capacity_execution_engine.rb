# frozen_string_literal: true

require "digest"
require "time"

module XrplReserveStudy
  class CapacityExecutionError < StudyError
    attr_reader :code, :record

    def initialize(code, record)
      @code = code
      @record = record
      super("capacity transaction execution failed (#{code})")
    end
  end

  class CapacityExecutionEngine
    AUTHORITY_SHA256 = "97380bed40c76b624c97982ed49a1962550d74dfa990a5075f8824feedadc95b"
    SOURCE_ACCOUNT = WorkloadGenerator::SOURCE_ACCOUNT
    NETWORK_ID = WorkloadGenerator::NETWORK_ID
    BUILD_VERSION = "3.3.0"
    FEE_DROPS = "10"
    FLAGS = 2_147_483_648
    HASH_PATTERN = /\A[A-F0-9]{64}\z/
    BLOB_PATTERN = /\A[A-F0-9]+\z/
    SIGNING_PUBLIC_KEY_PATTERN = /\A[A-F0-9]{66}\z/
    SIGNING_RESPONSE_KEYS = %w[deprecated hash status tx_blob tx_json].freeze
    SIGNING_TX_JSON_KEYS = %w[
      Account DeliverMax Destination Fee Flags LastLedgerSequence NetworkID Sequence
      SigningPubKey TransactionType TxnSignature
    ].freeze
    SIGNING_UNSIGNED_FIELDS = %w[
      TransactionType Account Destination Fee Sequence NetworkID Flags LastLedgerSequence
    ].freeze
    MAX_DEPRECATED_BYTES = 256
    MIN_SIGNATURE_BYTES = 68
    MAX_SIGNATURE_BYTES = 72

    def initialize(client:, clock: -> { Time.now.utc })
      @client = client
      @clock = clock
      locked = LockedCapacityInputs.new(error_class: CapacityExecutionInputError)
      @study_id = locked.study.data.fetch("study_id")
      @study_sha256 = locked.input_sha256.fetch("study/reserve-calibration-v1.yml")
    end

    def execute(inputs:, secret:)
      record = base_record(inputs)
      fail_execution!("invalid-signing-authority", record) unless valid_secret?(secret)

      intent = inputs.fetch("intent")
      run = inputs.fetch("run")
      server = rpc("server_info")
      ledger = validate_server!(server, run, record)
      preflight_index = ledger.fetch("seq")
      record["preflight_validated_ledger_index"] = preflight_index

      source = rpc("account_info", { "account" => SOURCE_ACCOUNT, "ledger_index" => "validated" })
      sequence = validate_source!(source, intent, preflight_index, record)
      transaction = transaction_json(intent, sequence, preflight_index)

      signing = rpc("sign", { "offline" => true, "tx_json" => transaction }, secret: secret)
      blob, transaction_hash = validate_signing!(signing, transaction, record)

      record["attempted_transactions"] = 1
      preliminary = rpc("submit", { "tx_blob" => blob, "fail_hard" => true })
      validate_preliminary!(preliminary, record)

      advancement = rpc("ledger_accept")
      validate_advancement!(advancement, preflight_index, record)
      record["ledger_advancements"] = 1

      transaction_result = rpc("tx", { "transaction" => transaction_hash, "binary" => false })
      validate_transaction!(transaction_result, transaction_hash, intent, preflight_index, record)
      destination = rpc("account_info", { "account" => intent.fetch("destination_account"), "ledger_index" => "validated" })
      validate_destination!(destination, intent, preflight_index, record)

      record["status"] = "passed"
      record["validated_successes"] = 1
      record["final_validated_ledger_index"] = transaction_result.fetch("ledger_index")
      record["final_validated_ledger_hash"] = transaction_result.fetch("ledger_hash")
      record["outcomes"] = [{
        "ordinal" => intent.fetch("ordinal"),
        "destination_account" => intent.fetch("destination_account"),
        "transaction_hash" => transaction_hash,
        "preliminary_engine_result" => preliminary.fetch("engine_result"),
        "final_transaction_result" => transaction_result.dig("meta", "TransactionResult"),
        "validated_ledger_index" => transaction_result.fetch("ledger_index"),
        "account_root_balance_drops" => destination.dig("account_data", "Balance")
      }]
      record["finished_at"] = timestamp
      deep_freeze(record)
    rescue CapacityExecutionError => error
      raise error
    rescue CapacityRpcError
      fail_execution!("rpc-failure", record || fallback_record)
    rescue KeyError, TypeError, ArgumentError
      fail_execution!("invalid-execution-inputs", record || fallback_record)
    rescue StandardError
      fail_execution!("execution-failure", record || fallback_record)
    ensure
      erase_secret!(secret)
    end

    private

    def valid_secret?(secret)
      return false unless secret.is_a?(String)
      constant_time_equal?(Digest::SHA256.hexdigest(secret), AUTHORITY_SHA256)
    end

    def erase_secret!(secret)
      return unless secret.is_a?(String) && !secret.frozen?
      secret.bytesize.times { |index| secret.setbyte(index, 0) }
      secret.clear
    end

    def rpc(command, parameters = {}, secret: nil)
      return @client.call(command) if parameters.empty? && secret.nil?
      return @client.call(command, parameters) if secret.nil?

      @client.call(command, parameters, secret: secret)
    end

    def validate_server!(response, run, record)
      info = response["info"] if response.is_a?(Hash)
      fail_execution!("invalid-server-info", record) unless info.is_a?(Hash)
      fail_execution!("unexpected-build-version", record) unless info["build_version"] == BUILD_VERSION
      fail_execution!("unexpected-network-id", record) unless info["network_id"] == NETWORK_ID
      fail_execution!("unexpected-peer-count", record) unless info["peers"] == 0
      fail_execution!("unexpected-validation-quorum", record) unless info["validation_quorum"] == 0
      ledger = info["validated_ledger"]
      valid_ledger = ledger.is_a?(Hash) && ledger["seq"] == 2 &&
        ledger["reserve_base_xrp"] == run.fetch("base_reserve_xrp") &&
        ledger["hash"].is_a?(String) && ledger["hash"].match?(HASH_PATTERN)
      fail_execution!("invalid-preflight-ledger", record) unless valid_ledger
      ledger
    end

    def validate_source!(response, intent, preflight_index, record)
      account = response["account_data"] if response.is_a?(Hash)
      valid = response.is_a?(Hash) && response["validated"] == true &&
        response["ledger_index"] == preflight_index && account.is_a?(Hash) &&
        account["Account"] == SOURCE_ACCOUNT && account["Sequence"] == 1 &&
        decimal_string?(account["Balance"])
      fail_execution!("invalid-source-account", record) unless valid
      required = Integer(intent.fetch("amount_drops"), 10) + Integer(FEE_DROPS, 10)
      fail_execution!("insufficient-source-balance", record) if Integer(account.fetch("Balance"), 10) < required
      account.fetch("Sequence")
    end

    def transaction_json(intent, sequence, preflight_index)
      {
        "TransactionType" => "Payment",
        "Account" => SOURCE_ACCOUNT,
        "Destination" => intent.fetch("destination_account"),
        "Amount" => intent.fetch("amount_drops"),
        "Fee" => FEE_DROPS,
        "Sequence" => sequence,
        "NetworkID" => NETWORK_ID,
        "Flags" => FLAGS,
        "LastLedgerSequence" => preflight_index + 2
      }
    end

    def validate_signing!(response, transaction, record)
      signed_transaction = response["tx_json"] if response.is_a?(Hash)
      valid_shape = response.is_a?(Hash) && response.keys.sort == SIGNING_RESPONSE_KEYS &&
        response["status"] == "success" && bounded_string?(response["deprecated"], MAX_DEPRECATED_BYTES) &&
        signed_transaction.is_a?(Hash) && signed_transaction.keys.sort == SIGNING_TX_JSON_KEYS &&
        SIGNING_UNSIGNED_FIELDS.all? { |field| signed_transaction[field].eql?(transaction.fetch(field)) } &&
        !signed_transaction.key?("Amount") && signed_transaction["DeliverMax"] == transaction.fetch("Amount") &&
        signed_transaction["SigningPubKey"].is_a?(String) &&
        signed_transaction["SigningPubKey"].match?(SIGNING_PUBLIC_KEY_PATTERN) &&
        valid_signature?(signed_transaction["TxnSignature"])
      fail_execution!("invalid-signing-response", record) unless valid_shape
      blob = response["tx_blob"]
      transaction_hash = response["hash"]
      fail_execution!("invalid-transaction-blob", record) unless blob.is_a?(String) &&
        blob.bytesize.between?(2, 1_048_576) && blob.bytesize.even? && blob.match?(BLOB_PATTERN)
      fail_execution!("invalid-transaction-hash", record) unless
        transaction_hash.is_a?(String) && transaction_hash.match?(HASH_PATTERN)
      [blob, transaction_hash]
    end

    def validate_preliminary!(response, record)
      valid = response.is_a?(Hash) && response["accepted"] == true && response["applied"] == true &&
        response["queued"] == false && response["engine_result"] == "tesSUCCESS"
      fail_execution!("submission-not-preliminarily-successful", record) unless valid
    end

    def validate_advancement!(response, preflight_index, record)
      valid = response.is_a?(Hash) && response["ledger_current_index"] == preflight_index + 2
      fail_execution!("unexpected-ledger-advancement", record) unless valid
    end

    def validate_transaction!(response, transaction_hash, intent, preflight_index, record)
      tx_json = response["tx_json"] if response.is_a?(Hash)
      valid = response.is_a?(Hash) && response["validated"] == true &&
        response["ledger_index"] == preflight_index + 1 && response["ledger_hash"].is_a?(String) &&
        response["ledger_hash"].match?(HASH_PATTERN) && response["hash"] == transaction_hash &&
        tx_json.is_a?(Hash) && tx_json["Account"] == SOURCE_ACCOUNT &&
        tx_json["Destination"] == intent.fetch("destination_account") &&
        !tx_json.key?("Amount") && tx_json["DeliverMax"].eql?(intent.fetch("amount_drops")) &&
        tx_json["NetworkID"].eql?(NETWORK_ID) &&
        response["meta"].is_a?(Hash) && response.dig("meta", "TransactionResult") == "tesSUCCESS"
      fail_execution!("transaction-not-validated-success", record) unless valid
    end

    def validate_destination!(response, intent, preflight_index, record)
      account = response["account_data"] if response.is_a?(Hash)
      valid = response.is_a?(Hash) && response["validated"] == true &&
        response["ledger_index"] == preflight_index + 1 && account.is_a?(Hash) &&
        account["Account"] == intent.fetch("destination_account") &&
        account["Balance"] == intent.fetch("amount_drops")
      fail_execution!("destination-account-not-validated", record) unless valid
    end

    def base_record(inputs)
      run = inputs.fetch("run")
      {
        "schema_version" => "capacity-execution-v1",
        "study_id" => @study_id,
        "study_sha256" => @study_sha256,
        "run_id" => run.fetch("run_id"),
        "config_sha256" => inputs.fetch("config_sha256"),
        "workload_sha256" => deep_copy(inputs.fetch("workload_sha256")),
        "execution_scope" => "functional-smoke",
        "counted_run" => false,
        "pilot_complete" => false,
        "base_reserve_xrp" => run.fetch("base_reserve_xrp"),
        "base_reserve_drops" => (run.fetch("base_reserve_xrp") * 1_000_000).round,
        "account_count" => run.fetch("account_count"),
        "repetition" => run.fetch("repetition"),
        "started_at" => timestamp,
        "status" => "aborted",
        "attempted_transactions" => 0,
        "validated_successes" => 0,
        "ledger_advancements" => 0,
        "outcomes" => []
      }
    end

    def fallback_record
      {
        "schema_version" => "capacity-execution-v1", "execution_scope" => "functional-smoke",
        "counted_run" => false, "pilot_complete" => false, "started_at" => timestamp,
        "status" => "aborted", "attempted_transactions" => 0, "validated_successes" => 0,
        "ledger_advancements" => 0, "outcomes" => []
      }
    end

    def fail_execution!(code, record)
      sanitized = deep_copy(record)
      sanitized["status"] = sanitized.fetch("attempted_transactions", 0).positive? ? "failed" : "aborted"
      sanitized["error_code"] = code
      sanitized["finished_at"] = timestamp
      raise CapacityExecutionError.new(code, deep_freeze(sanitized))
    end

    def timestamp
      value = @clock.call
      raise TypeError unless value.is_a?(Time)
      value.utc.iso8601(6)
    end

    def decimal_string?(value)
      value.is_a?(String) && value.match?(/\A(?:0|[1-9][0-9]*)\z/)
    end

    def bounded_string?(value, maximum_bytes)
      value.is_a?(String) && value.bytesize.between?(1, maximum_bytes)
    end

    def valid_signature?(value)
      value.is_a?(String) && value.bytesize.even? &&
        (value.bytesize / 2).between?(MIN_SIGNATURE_BYTES, MAX_SIGNATURE_BYTES) && value.match?(BLOB_PATTERN)
    end

    def constant_time_equal?(left, right)
      return false unless left.bytesize == right.bytesize
      left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array
        value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
