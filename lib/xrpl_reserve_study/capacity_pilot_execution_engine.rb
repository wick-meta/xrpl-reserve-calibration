# frozen_string_literal: true

require "digest"

module XrplReserveStudy
  class CapacityPilotExecutionError < StudyError
    attr_reader :code, :progress

    def initialize(code, progress)
      @code = code
      @progress = progress
      super("capacity pilot transaction execution failed (#{code})")
    end
  end

  class CapacityPilotExecutionEngine
    PendingAttempt = Struct.new(
      :schedule, :intent, :preflight, :source_balance, :source_sequence,
      :transaction_hash, :preliminary_result, keyword_init: true
    )
    private_constant :PendingAttempt

    AUTHORITY_SHA256 = CapacityExecutionEngine::AUTHORITY_SHA256
    SOURCE_ACCOUNT = WorkloadGenerator::SOURCE_ACCOUNT
    BUILD_VERSION = "3.3.0"
    NETWORK_ID = WorkloadGenerator::NETWORK_ID
    FEE_DROPS = "10"
    FLAGS = 2_147_483_648
    HASH_PATTERN = /\A[A-F0-9]{64}\z/
    BLOB_PATTERN = /\A[A-F0-9]+\z/
    PUBLIC_KEY_PATTERN = /\A[A-F0-9]{66}\z/
    SIGNATURE_PATTERN = /\A[A-F0-9]{136,144}\z/
    SIGNING_KEYS = %w[deprecated hash status tx_blob tx_json].freeze
    SIGNED_TRANSACTION_KEYS = %w[
      Account DeliverMax Destination Fee Flags LastLedgerSequence NetworkID Sequence
      SigningPubKey TransactionType TxnSignature
    ].freeze
    UNSIGNED_TRANSACTION_KEYS = %w[
      TransactionType Account Destination Amount Fee Sequence NetworkID Flags LastLedgerSequence
    ].freeze
    LEDGER_KEYS = %w[validated_ledger_index validated_ledger_hash].freeze
    EXECUTION_KEYS = %w[
      schema_version execution_scope run_id ordinal destination_account
      measurement_sample_sequence transaction_hash preliminary_result final_result
      validated_ledger_index validated_ledger_hash destination_accountroot_verified status counted_run
    ].freeze
    MAX_BLOB_BYTES = 1_048_576
    MAX_DEPRECATED_BYTES = 256
    MAX_UINT32 = 4_294_967_295
    ACCOUNT_FLAG_KEYS = %w[
      allowTrustLineClawback defaultRipple depositAuth disableMasterKey disallowIncomingCheck
      disallowIncomingNFTokenOffer disallowIncomingPayChan disallowIncomingTrustline
      disallowIncomingXRP globalFreeze noFreeze passwordSpent requireAuthorization
      requireDestinationTag
    ].freeze

    attr_reader :completed_records, :validated_transaction_count

    def initialize(client:, pilot_bundle:)
      @client = client
      @completed_records = [].freeze
      @terminal = false
      @session_active = false
      @session_used = false
      @authority = nil
      @previous_source_balance = nil
      @validated_transaction_count = 0
      @pending_attempt = nil
      locked = LockedCapacityInputs.new(error_class: CapacityPilotExecutionError)
      @protocol = locked.pilot_protocol.data
      @study = locked.study
      @pilot_bundle = validate_bundle!(pilot_bundle, locked)
      @schedule = @protocol.fetch("transaction_schedule")
    rescue CapacityPilotExecutionError
      raise
    rescue StandardError
      raise CapacityPilotExecutionError.new("invalid-pilot-bundle", empty_progress)
    end

    def with_authority(authority)
      reject!("invalid-engine-state", terminal: false) if @session_active || @session_used || @terminal
      reject!("invalid-signing-authority", terminal: false) unless valid_authority?(authority)

      @session_active = true
      @session_used = true
      @authority = authority
      yield self
    rescue CapacityPilotExecutionError
      raise
    ensure
      erase_string!(@authority)
      erase_string!(authority)
      @authority = nil
      @session_active = false
    end

    def prepare_scheduled(measurement_sample_sequence:, previous_ledger:)
      reject!("inactive-authority-session", terminal: false) unless @session_active && @authority
      reject!("engine-is-terminal", terminal: false) if @terminal
      reject!("pending-attempt-exists", terminal: false) if @pending_attempt

      schedule = expected_schedule!
      unless measurement_sample_sequence.instance_of?(Integer) &&
             measurement_sample_sequence == schedule.fetch("measurement_sample_sequence")
        reject!("unexpected-transaction-schedule", terminal: false)
      end
      validate_previous_ledger!(previous_ledger, measurement_sample_sequence)

      intent = @pilot_bundle.fetch("intents").fetch(schedule.fetch("ordinal") - 1)
      signing = nil
      blob = nil
      transaction_hash = nil
      preliminary = nil
      begin
        preflight = validate_server!(rpc("server_info"), previous_ledger)
        source_balance, source_sequence = validate_source!(
          rpc("account_info", {
            "account" => SOURCE_ACCOUNT,
            "ledger_hash" => preflight.fetch("validated_ledger_hash")
          }),
          intent, preflight
        )
        transaction = transaction_json(intent, source_sequence, preflight.fetch("validated_ledger_index"))

        signing = rpc("sign", { "offline" => true, "tx_json" => transaction }, secret: @authority)
        blob, transaction_hash = validate_signing!(signing, transaction)
        erase_signing_response!(signing)
        signing = nil

        preliminary = rpc("submit", { "tx_blob" => blob, "fail_hard" => true })
        validate_preliminary!(preliminary)
        erase_string!(blob)
        blob = nil

        @pending_attempt = deep_freeze(PendingAttempt.new(
          schedule: schedule, intent: intent, preflight: preflight,
          source_balance: source_balance, source_sequence: source_sequence,
          transaction_hash: transaction_hash.dup,
          preliminary_result: preliminary.fetch("engine_result").dup
        ))
      rescue CapacityPilotExecutionError
        @terminal = true
        raise
      rescue CapacityRpcError
        @terminal = true
        reject!("rpc-failure")
      rescue Interrupt
        @terminal = true
        reject!("interrupted")
      rescue StandardError
        @terminal = true
        reject!("execution-failure")
      ensure
        erase_string!(blob)
        erase_signing_response!(signing)
        erase_sensitive_values!(preliminary)
      end
      @pending_attempt
    end

    def advance_scheduled(attempt:, on_ledger_advance: nil)
      reject!("inactive-authority-session", terminal: false) unless @session_active && @authority
      reject!("engine-is-terminal", terminal: false) if @terminal
      reject!("invalid-pending-attempt", terminal: false) unless
        attempt.instance_of?(PendingAttempt) && @pending_attempt.equal?(attempt)
      reject!("invalid-ledger-advance-observer", terminal: false) unless
        on_ledger_advance.nil? || on_ledger_advance.respond_to?(:call)

      final = destination = nil
      begin
        validate_advancement!(rpc("ledger_accept"), attempt.preflight.fetch("validated_ledger_index"))
        on_ledger_advance.call if on_ledger_advance
        final = rpc("tx", { "transaction" => attempt.transaction_hash, "binary" => false })
        validate_final!(
          final, attempt.transaction_hash, attempt.intent,
          attempt.preflight.fetch("validated_ledger_index"), attempt.source_sequence
        )
        @validated_transaction_count += 1
        destination = rpc(
          "account_info", { "account" => attempt.intent.fetch("destination_account"), "ledger_index" => "validated" }
        )
        validate_destination!(destination, attempt.intent, final)

        record = execution_record(
          attempt.schedule, attempt.intent, attempt.transaction_hash, attempt.preliminary_result, final
        )
        @previous_source_balance = attempt.source_balance
        @completed_records = deep_freeze(@completed_records + [record])
        @pending_attempt = nil
        record
      rescue CapacityPilotExecutionError
        @terminal = true
        raise
      rescue CapacityRpcError
        @terminal = true
        reject!("rpc-failure")
      rescue Interrupt
        @terminal = true
        reject!("interrupted")
      rescue StandardError
        @terminal = true
        reject!("execution-failure")
      ensure
        erase_sensitive_values!(final)
        erase_sensitive_values!(destination)
      end
    end

    def execute_scheduled(measurement_sample_sequence:, previous_ledger:)
      attempt = prepare_scheduled(
        measurement_sample_sequence: measurement_sample_sequence, previous_ledger: previous_ledger
      )
      advance_scheduled(attempt: attempt)
    end

    private

    def validate_bundle!(bundle, locked)
      reject!("invalid-pilot-bundle", terminal: false) unless bundle.instance_of?(Hash) && deeply_frozen?(bundle)
      reject!("invalid-pilot-bundle", terminal: false) unless bundle.keys == %w[run intents]

      run = @study.plan.fetch("runs").find do |candidate|
        candidate.fetch("run_id") == @protocol.fetch("representative_run_id")
      end
      reject!("invalid-pilot-bundle", terminal: false) unless exact_graph?(bundle.fetch("run"), run)

      generator = WorkloadGenerator.new(inputs: locked)
      expected_intents = 1.upto(@protocol.fetch("pilot_accounts")).map do |ordinal|
        {
          "ordinal" => ordinal,
          "transaction_type" => @protocol.fetch("transaction_type"),
          "source_account" => SOURCE_ACCOUNT,
          "destination_account" => generator.__send__(:derived_destination, run.fetch("run_id"), ordinal),
          "amount_drops" => ((run.fetch("base_reserve_xrp") * 1_000_000).round).to_s,
          "network_id" => NETWORK_ID
        }
      end
      reject!("invalid-pilot-bundle", terminal: false) unless exact_graph?(bundle.fetch("intents"), expected_intents)
      bundle
    end

    def expected_schedule!
      index = @completed_records.length
      reject!("attempt-limit-exhausted", terminal: false) unless index < @schedule.length
      @schedule.fetch(index)
    end

    def validate_previous_ledger!(ledger, sequence)
      valid = ledger.instance_of?(Hash) && deeply_frozen?(ledger) && ledger.keys == LEDGER_KEYS &&
        ledger.fetch("validated_ledger_index").instance_of?(Integer) &&
        ledger.fetch("validated_ledger_index") == sequence + 1 && valid_hash?(ledger.fetch("validated_ledger_hash"))
      reject!("invalid-previous-ledger", terminal: false) unless valid
    rescue KeyError
      reject!("invalid-previous-ledger", terminal: false)
    end

    def validate_server!(response, previous)
      info = response["info"] if response.instance_of?(Hash)
      ledger = info["validated_ledger"] if info.instance_of?(Hash)
      run = @pilot_bundle.fetch("run")
      valid = info.instance_of?(Hash) && exact_string?(info["build_version"], BUILD_VERSION) &&
        info["network_id"].instance_of?(Integer) && info["network_id"] == NETWORK_ID &&
        info["peers"].instance_of?(Integer) && info["peers"].zero? &&
        info["validation_quorum"].instance_of?(Integer) && info["validation_quorum"].zero? &&
        ledger.instance_of?(Hash) && ledger["seq"].instance_of?(Integer) &&
        ledger["seq"] == previous.fetch("validated_ledger_index") &&
        valid_hash?(ledger["hash"]) && ledger["hash"].eql?(previous.fetch("validated_ledger_hash")) &&
        ledger["reserve_base_xrp"].instance_of?(Float) && ledger["reserve_base_xrp"].eql?(run.fetch("base_reserve_xrp"))
      reject!("invalid-server-state") unless valid
      previous
    end

    def validate_source!(response, intent, preflight)
      account = response["account_data"] if response.instance_of?(Hash)
      ordinal = intent.fetch("ordinal")
      valid = response.instance_of?(Hash) && response.keys.all? { |key| key.instance_of?(String) } &&
        (response.keys - %w[account_data account_flags ledger_hash ledger_index status validated]).empty? &&
        %w[account_data ledger_hash ledger_index validated].all? { |key| response.key?(key) } &&
        (!response.key?("status") || exact_string?(response["status"], "success")) &&
        response["validated"].equal?(true) &&
        response["ledger_index"].instance_of?(Integer) &&
        response["ledger_index"] == preflight.fetch("validated_ledger_index") &&
        valid_hash?(response["ledger_hash"]) &&
        response["ledger_hash"].eql?(preflight.fetch("validated_ledger_hash")) &&
        account.instance_of?(Hash) && account.keys.all? { |key| key.instance_of?(String) } &&
        exact_string?(account["Account"], SOURCE_ACCOUNT) &&
        (account.keys - %w[Account Balance Flags LedgerEntryType OwnerCount PreviousTxnID PreviousTxnLgrSeq Sequence index]).empty? &&
        %w[Account Balance Sequence].all? { |key| account.key?(key) } &&
        account["Sequence"].instance_of?(Integer) && account["Sequence"] == ordinal && decimal_string?(account["Balance"]) &&
        valid_optional_source_fields?(account) && valid_optional_account_index?(account) &&
        (!response.key?("account_flags") || valid_account_flags?(response["account_flags"]))
      reject!("invalid-source-state") unless valid
      balance = Integer(account.fetch("Balance"), 10)
      cost = Integer(intent.fetch("amount_drops"), 10) + Integer(FEE_DROPS, 10)
      remaining = @protocol.fetch("pilot_accounts") - ordinal + 1
      reject!("insufficient-source-balance") if balance < cost * remaining
      if @previous_source_balance && balance != @previous_source_balance - cost
        reject!("unexpected-source-balance")
      end
      [balance, account.fetch("Sequence")]
    end

    def valid_optional_source_fields?(account)
      return false if account.key?("Flags") && !uint32?(account["Flags"])
      return false if account.key?("LedgerEntryType") && !exact_string?(account["LedgerEntryType"], "AccountRoot")
      return false if account.key?("OwnerCount") && !uint32?(account["OwnerCount"])
      return false if account.key?("PreviousTxnID") && !valid_hash?(account["PreviousTxnID"])
      return false if account.key?("PreviousTxnLgrSeq") && !uint32?(account["PreviousTxnLgrSeq"])

      true
    end

    def valid_optional_account_index?(account)
      !account.key?("index") || valid_hash?(account["index"])
    end

    def valid_account_flags?(flags)
      flags.instance_of?(Hash) && (flags.keys - ACCOUNT_FLAG_KEYS).empty? &&
        flags.all? { |key, value| key.instance_of?(String) && (value.equal?(true) || value.equal?(false)) }
    end

    def uint32?(value)
      value.instance_of?(Integer) && value.between?(0, MAX_UINT32)
    end

    def transaction_json(intent, sequence, ledger_index)
      {
        "TransactionType" => "Payment", "Account" => SOURCE_ACCOUNT,
        "Destination" => intent.fetch("destination_account"), "Amount" => intent.fetch("amount_drops"),
        "Fee" => FEE_DROPS, "Sequence" => sequence, "NetworkID" => NETWORK_ID, "Flags" => FLAGS,
        "LastLedgerSequence" => ledger_index + 2
      }
    end

    def validate_signing!(response, transaction)
      signed = response["tx_json"] if response.instance_of?(Hash)
      expected_signed = transaction.reject { |key, _| key == "Amount" }.merge("DeliverMax" => transaction.fetch("Amount"))
      valid = response.instance_of?(Hash) && response.keys.sort == SIGNING_KEYS &&
        exact_string?(response["status"], "success") &&
        bounded_string?(response["deprecated"], MAX_DEPRECATED_BYTES) && signed.instance_of?(Hash) &&
        signed.keys.sort == SIGNED_TRANSACTION_KEYS &&
        expected_signed.all? { |key, value| signed[key].eql?(value) } &&
        signed["SigningPubKey"].instance_of?(String) && signed["SigningPubKey"].match?(PUBLIC_KEY_PATTERN) &&
        signed["TxnSignature"].instance_of?(String) && signed["TxnSignature"].bytesize.even? &&
        signed["TxnSignature"].match?(SIGNATURE_PATTERN)
      reject!("invalid-signing-response") unless valid
      blob = response["tx_blob"]
      hash = response["hash"]
      reject!("invalid-transaction-blob") unless blob.instance_of?(String) &&
        blob.bytesize.between?(2, MAX_BLOB_BYTES) && blob.bytesize.even? && blob.match?(BLOB_PATTERN)
      reject!("invalid-transaction-hash") unless valid_hash?(hash)
      [blob.dup, hash.dup]
    end

    def validate_preliminary!(response)
      valid = response.instance_of?(Hash) && response["accepted"].equal?(true) &&
        response["applied"].equal?(true) && response["queued"].equal?(false) &&
        exact_string?(response["engine_result"], "tesSUCCESS")
      reject!("submission-not-preliminarily-successful") unless valid
    end

    def validate_advancement!(response, preflight_index)
      valid = response.instance_of?(Hash) && response["ledger_current_index"].instance_of?(Integer) &&
        response["ledger_current_index"] == preflight_index + 2
      reject!("unexpected-ledger-advancement") unless valid
    end

    def validate_final!(response, transaction_hash, intent, preflight_index, sequence)
      transaction = response["tx_json"] if response.instance_of?(Hash)
      valid = response.instance_of?(Hash) && response["validated"].equal?(true) &&
        response["ledger_index"].instance_of?(Integer) && response["ledger_index"] == preflight_index + 1 &&
        valid_hash?(response["ledger_hash"]) && valid_hash?(response["hash"]) &&
        response["hash"].eql?(transaction_hash) && response["meta"].instance_of?(Hash) &&
        exact_string?(response.dig("meta", "TransactionResult"), "tesSUCCESS") &&
        transaction.instance_of?(Hash) && exact_string?(transaction["Account"], SOURCE_ACCOUNT) &&
        exact_string?(transaction["Destination"], intent.fetch("destination_account")) &&
        !transaction.key?("Amount") && transaction["DeliverMax"].eql?(intent.fetch("amount_drops")) &&
        transaction["NetworkID"].instance_of?(Integer) && transaction["NetworkID"] == NETWORK_ID &&
        transaction["Sequence"].instance_of?(Integer) && transaction["Sequence"] == sequence
      reject!("transaction-not-validated-success") unless valid
    end

    def validate_destination!(response, intent, final)
      account = response["account_data"] if response.instance_of?(Hash)
      valid = response.instance_of?(Hash) && response["validated"].equal?(true) &&
        response["ledger_index"].instance_of?(Integer) && response["ledger_index"] == final.fetch("ledger_index") &&
        valid_hash?(response["ledger_hash"]) && response["ledger_hash"].eql?(final.fetch("ledger_hash")) &&
        account.instance_of?(Hash) && exact_string?(account["Account"], intent.fetch("destination_account")) &&
        exact_string?(account["Balance"], intent.fetch("amount_drops"))
      reject!("destination-accountroot-not-verified") unless valid
    end

    def execution_record(schedule, intent, transaction_hash, preliminary_result, final)
      record = {
        "schema_version" => "capacity-pilot-execution-v1", "execution_scope" => "non-counted-pilot",
        "run_id" => @protocol.fetch("representative_run_id"), "ordinal" => schedule.fetch("ordinal"),
        "destination_account" => intent.fetch("destination_account"),
        "measurement_sample_sequence" => schedule.fetch("measurement_sample_sequence"),
        "transaction_hash" => transaction_hash.dup, "preliminary_result" => preliminary_result.dup,
        "final_result" => final.dig("meta", "TransactionResult"),
        "validated_ledger_index" => final.fetch("ledger_index"),
        "validated_ledger_hash" => final.fetch("ledger_hash"),
        "destination_accountroot_verified" => true, "status" => "validated-success", "counted_run" => false
      }
      reject!("invalid-execution-record") unless record.keys == EXECUTION_KEYS
      deep_freeze(record)
    end

    def rpc(command, parameters = {}, secret: nil)
      return @client.call(command) if parameters.empty? && secret.nil?
      return @client.call(command, parameters) if secret.nil?
      @client.call(command, parameters, secret: secret)
    end

    def valid_authority?(authority)
      authority.is_a?(String) && !authority.frozen? &&
        constant_time_equal?(Digest::SHA256.hexdigest(authority), AUTHORITY_SHA256)
    end

    def erase_signing_response!(response)
      return unless response.instance_of?(Hash)
      erase_string!(response["tx_blob"])
      signed = response["tx_json"]
      return unless signed.instance_of?(Hash)
      erase_string!(signed["SigningPubKey"])
      erase_string!(signed["TxnSignature"])
    end

    def erase_sensitive_values!(value)
      case value
      when Hash
        value.each do |key, nested|
          if String(key).match?(/secret|seed|private|signed|signature|signing|tx_blob/i)
            erase_nested_strings!(nested)
          else
            erase_sensitive_values!(nested)
          end
        end
      when Array
        value.each { |nested| erase_sensitive_values!(nested) }
      end
    end

    def erase_nested_strings!(value)
      case value
      when String then erase_string!(value)
      when Hash then value.each_value { |nested| erase_nested_strings!(nested) }
      when Array then value.each { |nested| erase_nested_strings!(nested) }
      end
    end

    def erase_string!(value)
      return unless value.is_a?(String) && !value.frozen?
      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end

    def reject!(code, terminal: true)
      @terminal = true if terminal
      raise CapacityPilotExecutionError.new(code, progress)
    end

    def progress
      deep_freeze(
        "validated_transaction_count" => @validated_transaction_count,
        "completed_transaction_count" => @completed_records.length,
        "completed_records" => deep_copy(@completed_records)
      )
    end

    def empty_progress
      deep_freeze("validated_transaction_count" => 0, "completed_transaction_count" => 0, "completed_records" => [])
    end

    def valid_hash?(value)
      value.instance_of?(String) && value.match?(HASH_PATTERN)
    end

    def decimal_string?(value)
      value.instance_of?(String) && value.match?(/\A(?:0|[1-9][0-9]*)\z/)
    end

    def bounded_string?(value, maximum)
      value.instance_of?(String) && value.bytesize.between?(1, maximum)
    end

    def exact_string?(value, expected)
      value.instance_of?(String) && value.eql?(expected)
    end

    def constant_time_equal?(left, right)
      return false unless left.bytesize == right.bytesize
      left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
    end

    def deeply_frozen?(value)
      return false unless value.frozen?
      case value
      when Hash then value.all? { |key, nested| deeply_frozen?(key) && deeply_frozen?(nested) }
      when Array then value.all? { |nested| deeply_frozen?(nested) }
      else true
      end
    end

    def exact_graph?(actual, expected)
      return false unless actual.instance_of?(expected.class)
      case expected
      when Hash
        actual.keys == expected.keys && expected.all? { |key, nested| exact_graph?(actual.fetch(key), nested) }
      when Array
        actual.length == expected.length && expected.each_index.all? { |index| exact_graph?(actual.fetch(index), expected.fetch(index)) }
      else
        actual.eql?(expected)
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      when Struct then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
