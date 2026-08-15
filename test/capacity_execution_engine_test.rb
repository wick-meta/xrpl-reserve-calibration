# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CapacityExecutionEngineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
  DESTINATION = "rPh7FjNmSnqQGC5zni2dA52UpxgYMy4Yc3"
  BLOB = "AB" * 32
  TX_HASH = "B" * 64
  LEDGER_HASH = "C" * 64
  SIGNING_PUBLIC_KEY = "A" * 66
  SIGNATURE = "B" * 140
  SIGNING_TOP_LEVEL_KEYS = %w[deprecated hash status tx_blob tx_json].freeze
  SIGNING_TX_JSON_KEYS = %w[
    Account DeliverMax Destination Fee Flags LastLedgerSequence NetworkID Sequence
    SigningPubKey TransactionType TxnSignature
  ].freeze

  class ScriptedClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(command, parameters = {}, secret: nil)
      @calls << [command, Marshal.load(Marshal.dump(parameters)), secret&.dup]
      response = @responses.fetch(@calls.length - 1)
      raise response if response.is_a?(Exception)
      Marshal.load(Marshal.dump(response))
    end
  end

  def test_executes_exactly_one_offline_signed_transaction_and_records_validated_success
    client = ScriptedClient.new(success_responses)
    secret = +"positive-path-stubbed-secret"
    record = engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }

    assert_equal %w[server_info account_info sign submit ledger_accept tx account_info], client.calls.map(&:first)
    assert_equal({ "account" => SOURCE, "ledger_index" => "validated" }, client.calls[1][1])
    assert_equal({ "offline" => true, "tx_json" => expected_transaction }, client.calls[2][1])
    assert_equal "positive-path-stubbed-secret", client.calls[2][2]
    assert_equal({ "tx_blob" => BLOB, "fail_hard" => true }, client.calls[3][1])
    assert_equal({}, client.calls[4][1])
    assert_equal({ "transaction" => TX_HASH, "binary" => false }, client.calls[5][1])
    assert_equal({ "account" => DESTINATION, "ledger_index" => "validated" }, client.calls[6][1])

    assert_equal "capacity-execution-v1", record.fetch("schema_version")
    assert_equal "functional-smoke", record.fetch("execution_scope")
    assert_equal false, record.fetch("counted_run")
    assert_equal false, record.fetch("pilot_complete")
    assert_equal "passed", record.fetch("status")
    assert_equal 1, record.fetch("attempted_transactions")
    assert_equal 1, record.fetch("validated_successes")
    assert_equal 1, record.fetch("ledger_advancements")
    assert_equal 2, record.fetch("preflight_validated_ledger_index")
    assert_equal 3, record.fetch("final_validated_ledger_index")
    assert_equal LEDGER_HASH, record.fetch("final_validated_ledger_hash")
    assert_equal({
      "ordinal" => 1,
      "destination_account" => DESTINATION,
      "transaction_hash" => TX_HASH,
      "preliminary_engine_result" => "tesSUCCESS",
      "final_transaction_result" => "tesSUCCESS",
      "validated_ledger_index" => 3,
      "account_root_balance_drops" => "500000"
    }, record.fetch("outcomes").fetch(0))
    assert_equal "2026-08-04T00:00:00.000000Z", record.fetch("started_at")
    assert_equal "2026-08-04T00:00:01.000000Z", record.fetch("finished_at")
    assert_sanitized(record, "positive-path-stubbed-secret")
    assert_empty secret
  end

  def test_rejects_wrong_authority_before_any_rpc_call_and_clears_secret
    client = ScriptedClient.new([])
    secret = +"not-the-standalone-genesis-authority"
    error = assert_raises(XrplReserveStudy::CapacityExecutionError) do
      engine(client).execute(inputs: inputs, secret: secret)
    end
    assert_equal "invalid-signing-authority", error.code
    assert_equal "aborted", error.record.fetch("status")
    assert_empty client.calls
    assert_empty secret
    assert_sanitized(error.record, "not-the-standalone-genesis-authority")
  end

  def test_rejects_every_preflight_and_transaction_boundary_with_sanitized_errors
    failures = {
      "wrong build" => [0, ->(r) { r.dig("info")["build_version"] = "3.2.0" }],
      "wrong network" => [0, ->(r) { r.dig("info")["network_id"] = 1 }],
      "peers" => [0, ->(r) { r.dig("info")["peers"] = 1 }],
      "quorum" => [0, ->(r) { r.dig("info")["validation_quorum"] = 1 }],
      "reserve" => [0, ->(r) { r.dig("info", "validated_ledger")["reserve_base_xrp"] = 1 }],
      "source missing" => [1, ->(r) { r.delete("account_data") }],
      "source account" => [1, ->(r) { r.dig("account_data")["Account"] = DESTINATION }],
      "source sequence" => [1, ->(r) { r.dig("account_data")["Sequence"] = 2 }],
      "source balance" => [1, ->(r) { r.dig("account_data")["Balance"] = "500009" }],
      "accepted" => [3, ->(r) { r["accepted"] = false }],
      "applied" => [3, ->(r) { r["applied"] = false }],
      "queued" => [3, ->(r) { r["queued"] = true }],
      "preliminary result" => [3, ->(r) { r["engine_result"] = "tecFAILED" }],
      "ledger index" => [4, ->(r) { r["ledger_current_index"] = 5 }],
      "tx absent" => [5, ->(r) { r.clear }],
      "tx unvalidated" => [5, ->(r) { r["validated"] = false }],
      "tx hash" => [5, ->(r) { r["hash"] = "D" * 64 }],
      "tx ledger" => [5, ->(r) { r["ledger_index"] = 4 }],
      "tx result" => [5, ->(r) { r.dig("meta")["TransactionResult"] = "tecFAILED" }],
      "tx account" => [5, ->(r) { r.fetch("tx_json")["Account"] = DESTINATION }],
      "tx destination" => [5, ->(r) { r.fetch("tx_json")["Destination"] = SOURCE }],
      "tx network" => [5, ->(r) { r.fetch("tx_json")["NetworkID"] = 1 }],
      "destination missing" => [6, ->(r) { r.delete("account_data") }],
      "destination account" => [6, ->(r) { r.dig("account_data")["Account"] = SOURCE }],
      "destination balance" => [6, ->(r) { r.dig("account_data")["Balance"] = "499999" }]
    }

    failures.each do |name, (index, mutation)|
      responses = success_responses
      mutation.call(responses.fetch(index))
      client = ScriptedClient.new(responses)
      secret = +"failure-path-stubbed-secret"
      error = assert_raises(XrplReserveStudy::CapacityExecutionError, name) do
        engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }
      end
      assert_match(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, error.code, name)
      assert_includes %w[failed aborted], error.record.fetch("status"), name
      refute_equal "passed", error.record.fetch("status"), name
      assert_equal error.code, error.record.fetch("error_code"), name
      assert_sanitized(error.record, "failure-path-stubbed-secret")
      refute_includes error.message, "failure-path-stubbed-secret"
      refute_includes error.message, BLOB
      assert_empty secret
    end
  end

  def test_rejects_invalid_api_v2_final_payment_amount_shapes
    {
      "missing DeliverMax" => ->(response) { response.fetch("tx_json").delete("DeliverMax") },
      "wrong DeliverMax" => ->(response) { response.fetch("tx_json")["DeliverMax"] = "1" },
      "Amount only" => ->(response) { response.fetch("tx_json").delete("DeliverMax"); response.fetch("tx_json")["Amount"] = "500000" },
      "both amount aliases" => ->(response) { response.fetch("tx_json")["Amount"] = "500000" },
      "type-mismatched DeliverMax" => ->(response) { response.fetch("tx_json")["DeliverMax"] = 500_000 }
    }.each do |name, mutation|
      assert_final_transaction_failure(name, &mutation)
    end
  end

  def test_rejects_invalid_api_v2_nested_final_transaction_shape
    {
      "missing tx_json" => ->(response) { response.delete("tx_json") },
      "non-Hash tx_json" => ->(response) { response["tx_json"] = "not-a-transaction" },
      "fields only at top level" => lambda { |response|
        nested = response.delete("tx_json")
        response.merge!(nested)
      },
      "missing nested Account" => ->(response) { response.fetch("tx_json").delete("Account") },
      "wrong nested Account" => ->(response) { response.fetch("tx_json")["Account"] = DESTINATION },
      "missing nested Destination" => ->(response) { response.fetch("tx_json").delete("Destination") },
      "wrong nested Destination" => ->(response) { response.fetch("tx_json")["Destination"] = SOURCE },
      "missing nested NetworkID" => ->(response) { response.fetch("tx_json").delete("NetworkID") },
      "wrong nested NetworkID" => ->(response) { response.fetch("tx_json")["NetworkID"] = 1 },
      "float nested NetworkID" => ->(response) { response.fetch("tx_json")["NetworkID"] = 21_338.0 }
    }.each do |name, mutation|
      assert_final_transaction_failure(name, &mutation)
    end
  end

  def test_does_not_persist_sensitive_nested_final_transaction_material
    responses = success_responses
    responses.fetch(5).fetch("tx_json")["secret"] = "test-only-sensitive-nested-value"
    responses.fetch(5).fetch("tx_json")["raw_key"] = "test-only-sensitive-nested-value"
    client = ScriptedClient.new(responses)
    secret = +"nested-final-material-test-secret"
    record = engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }

    assert_equal "passed", record.fetch("status")
    assert_sanitized(record, "nested-final-material-test-secret")
    refute_includes JSON.generate(record), "test-only-sensitive-nested-value"
    assert_empty secret
  end

  def test_accepts_the_complete_real_shaped_signing_response_without_persisting_signing_fields
    client = ScriptedClient.new(success_responses)
    secret = +"real-shaped-signing-test-secret"
    record = engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }

    signing = client.calls.fetch(2)
    assert_equal "sign", signing.fetch(0)
    assert_equal expected_transaction, signing.fetch(1).fetch("tx_json")
    assert_equal BLOB, client.calls.fetch(3).fetch(1).fetch("tx_blob")
    assert_equal TX_HASH, client.calls.fetch(5).fetch(1).fetch("transaction")
    assert_sanitized(record, "real-shaped-signing-test-secret")
    assert_empty secret
  end

  def test_rejects_mutation_of_each_unsigned_field_in_the_signing_response
    mutations = {
      "TransactionType" => "OfferCreate",
      "Account" => DESTINATION,
      "Destination" => SOURCE,
      "Fee" => "11",
      "Sequence" => 2,
      "NetworkID" => 1,
      "Flags" => 0,
      "LastLedgerSequence" => 5
    }

    mutations.each do |field, value|
      assert_signing_failure("unsigned #{field}") do |signing|
        signing.fetch("tx_json")[field] = value
      end
    end
  end

  def test_rejects_equal_valued_float_substitutions_for_unsigned_integer_fields
    {
      "Sequence" => 1.0,
      "NetworkID" => 21_338.0,
      "Flags" => 2_147_483_648.0,
      "LastLedgerSequence" => 4.0
    }.each do |field, value|
      assert_signing_failure("float #{field}") do |signing|
        signing.fetch("tx_json")[field] = value
      end
    end
  end

  def test_rejects_missing_wrong_or_duplicated_amount_aliases_in_the_signing_response
    {
      "missing DeliverMax" => ->(signed) { signed.delete("DeliverMax") },
      "wrong DeliverMax" => ->(signed) { signed["DeliverMax"] = "1" },
      "Amount alias" => ->(signed) { signed["Amount"] = "500000" },
      "both amount aliases" => ->(signed) { signed["DeliverMax"] = "1"; signed["Amount"] = "500000" }
    }.each do |name, mutation|
      assert_signing_failure(name) { |signing| mutation.call(signing.fetch("tx_json")) }
    end
  end

  def test_rejects_every_missing_or_extra_signing_response_key
    SIGNING_TOP_LEVEL_KEYS.each do |key|
      assert_signing_failure("missing top-level #{key}") { |signing| signing.delete(key) }
    end
    SIGNING_TX_JSON_KEYS.each do |key|
      assert_signing_failure("missing tx_json #{key}") { |signing| signing.fetch("tx_json").delete(key) }
    end
    assert_signing_failure("extra top-level key") { |signing| signing["unexpected"] = "test-only" }
    assert_signing_failure("extra tx_json key") { |signing| signing.fetch("tx_json")["unexpected"] = "test-only" }
  end

  def test_rejects_non_success_status_and_invalid_deprecated_values
    {
      "wrong status" => ->(signing) { signing["status"] = "error" },
      "missing deprecated" => ->(signing) { signing["deprecated"] = nil },
      "empty deprecated" => ->(signing) { signing["deprecated"] = "" },
      "oversized deprecated" => ->(signing) { signing["deprecated"] = "x" * 257 }
    }.each do |name, mutation|
      assert_signing_failure(name, &mutation)
    end
  end

  def test_rejects_malformed_signing_public_key_signature_hash_and_blob
    {
      "lowercase public key" => ->(signing) { signing.dig("tx_json")["SigningPubKey"] = "a" * 66 },
      "short public key" => ->(signing) { signing.dig("tx_json")["SigningPubKey"] = "A" * 65 },
      "invalid public key" => ->(signing) { signing.dig("tx_json")["SigningPubKey"] = "G" * 66 },
      "lowercase signature" => ->(signing) { signing.dig("tx_json")["TxnSignature"] = "b" * 140 },
      "odd signature" => ->(signing) { signing.dig("tx_json")["TxnSignature"] = "B" * 139 },
      "short signature" => ->(signing) { signing.dig("tx_json")["TxnSignature"] = "B" * 134 },
      "long signature" => ->(signing) { signing.dig("tx_json")["TxnSignature"] = "B" * 146 },
      "invalid signature" => ->(signing) { signing.dig("tx_json")["TxnSignature"] = "G" * 140 },
      "lowercase hash" => ->(signing) { signing["hash"] = "b" * 64 },
      "short hash" => ->(signing) { signing["hash"] = "B" * 63 },
      "invalid hash" => ->(signing) { signing["hash"] = "G" * 64 },
      "lowercase blob" => ->(signing) { signing["tx_blob"] = "ab" * 32 },
      "odd blob" => ->(signing) { signing["tx_blob"] = "A" * 63 },
      "empty blob" => ->(signing) { signing["tx_blob"] = "" },
      "oversized blob" => ->(signing) { signing["tx_blob"] = "A" * 1_048_578 }
    }.each do |name, mutation|
      assert_signing_failure(name, &mutation)
    end
  end

  def test_rejects_added_secret_raw_key_and_signed_material_fields_with_sanitized_records
    %w[secret seed private_key privateKey signing_key raw_key].each do |field|
      assert_signing_failure("top-level #{field}") { |signing| signing[field] = "test-only-disallowed-value" }
      assert_signing_failure("tx_json #{field}") { |signing| signing.fetch("tx_json")[field] = "test-only-disallowed-value" }
    end
  end

  def test_rpc_errors_are_sanitized_and_secret_is_cleared
    responses = success_responses
    responses[2] = XrplReserveStudy::CapacityRpcError.new("raw RPC payload #{BLOB}")
    client = ScriptedClient.new(responses)
    secret = +"rpc-error-secret"
    error = assert_raises(XrplReserveStudy::CapacityExecutionError) do
      engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }
    end
    assert_equal "rpc-failure", error.code
    refute_includes error.message, BLOB
    assert_sanitized(error.record, "rpc-error-secret")
    assert_empty secret
  end

  def test_execution_schema_is_closed_and_has_no_secret_or_signed_material_properties
    schema = JSON.parse(File.binread(File.join(ROOT, "schemas", "capacity-execution-v1.schema.json")))
    properties = schema.fetch("properties")

    assert_equal "https://json-schema.org/draft/2020-12/schema", schema.fetch("$schema")
    assert_equal false, schema.fetch("additionalProperties")
    assert_equal "capacity-execution-v1", properties.fetch("schema_version").fetch("const")
    assert_equal "functional-smoke", properties.fetch("execution_scope").fetch("const")
    assert_equal false, properties.fetch("counted_run").fetch("const")
    assert_equal false, properties.fetch("pilot_complete").fetch("const")
    refute properties.keys.any? { |key| key.match?(/secret|seed|private_key|signed|tx_blob/i) }
    outcome = properties.fetch("outcomes").fetch("items")
    assert_equal false, outcome.fetch("additionalProperties")
  end

  private

  def engine(client)
    moments = [Time.utc(2026, 8, 4, 0, 0, 0), Time.utc(2026, 8, 4, 0, 0, 1)]
    XrplReserveStudy::CapacityExecutionEngine.new(client: client, clock: -> { moments.shift || moments.last })
  end

  def inputs
    {
      "run" => {
        "run_id" => "r0500000-a000010000-n01", "base_reserve_xrp" => 0.5,
        "account_count" => 10_000, "repetition" => 1
      },
      "config_sha256" => "a" * 64,
      "workload_sha256" => { "accounts.jsonl" => "b" * 64, "manifest.json" => "c" * 64 },
      "intent" => {
        "ordinal" => 1, "transaction_type" => "Payment", "source_account" => SOURCE,
        "destination_account" => DESTINATION, "amount_drops" => "500000", "network_id" => 21_338
      }
    }
  end

  def expected_transaction
    {
      "TransactionType" => "Payment", "Account" => SOURCE, "Destination" => DESTINATION,
      "Amount" => "500000", "Fee" => "10", "Sequence" => 1, "NetworkID" => 21_338,
      "Flags" => 2_147_483_648, "LastLedgerSequence" => 4
    }
  end

  def success_responses
    [
      { "info" => { "build_version" => "3.3.0", "network_id" => 21_338, "peers" => 0,
                      "validation_quorum" => 0, "validated_ledger" => {
                        "reserve_base_xrp" => 0.5, "seq" => 2, "hash" => "A" * 64
                      } } },
      { "validated" => true, "ledger_index" => 2,
        "account_data" => { "Account" => SOURCE, "Sequence" => 1, "Balance" => "1000000" } },
      signing_response,
      { "accepted" => true, "applied" => true, "queued" => false, "engine_result" => "tesSUCCESS" },
      { "ledger_current_index" => 4 },
      { "validated" => true, "ledger_index" => 3, "ledger_hash" => LEDGER_HASH, "hash" => TX_HASH,
        "meta" => { "TransactionResult" => "tesSUCCESS" }, "tx_json" => {
          "Account" => SOURCE, "Destination" => DESTINATION, "DeliverMax" => "500000", "NetworkID" => 21_338
        } },
      { "validated" => true, "ledger_index" => 3,
        "account_data" => { "Account" => DESTINATION, "Balance" => "500000" } }
    ]
  end

  def signing_response
    {
      "deprecated" => "test-only deprecated field",
      "hash" => TX_HASH,
      "status" => "success",
      "tx_blob" => BLOB,
      "tx_json" => {
        "Account" => SOURCE,
        "DeliverMax" => "500000",
        "Destination" => DESTINATION,
        "Fee" => "10",
        "Flags" => 2_147_483_648,
        "LastLedgerSequence" => 4,
        "NetworkID" => 21_338,
        "Sequence" => 1,
        "SigningPubKey" => SIGNING_PUBLIC_KEY,
        "TransactionType" => "Payment",
        "TxnSignature" => SIGNATURE
      }
    }
  end

  def assert_signing_failure(name)
    responses = success_responses
    yield responses.fetch(2)
    client = ScriptedClient.new(responses)
    secret = +"signing-validation-test-secret"
    error = assert_raises(XrplReserveStudy::CapacityExecutionError, name) do
      engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }
    end

    assert_includes %w[invalid-signing-response invalid-transaction-blob invalid-transaction-hash], error.code, name
    assert_equal "aborted", error.record.fetch("status"), name
    assert_sanitized(error.record, "signing-validation-test-secret")
    refute_includes error.message, "signing-validation-test-secret", name
    refute_includes error.message, "test-only-disallowed-value", name
    assert_empty secret, name
  end

  def assert_final_transaction_failure(name)
    responses = success_responses
    yield responses.fetch(5)
    client = ScriptedClient.new(responses)
    secret = +"final-payment-validation-test-secret"
    error = assert_raises(XrplReserveStudy::CapacityExecutionError, name) do
      engine(client).stub(:valid_secret?, true) { |subject| subject.execute(inputs: inputs, secret: secret) }
    end

    assert_equal "transaction-not-validated-success", error.code, name
    assert_equal "failed", error.record.fetch("status"), name
    assert_sanitized(error.record, "final-payment-validation-test-secret")
    refute_includes error.message, "final-payment-validation-test-secret", name
    assert_empty secret, name
  end

  def assert_sanitized(value, secret)
    serialized = JSON.generate(value)
    refute_includes serialized, secret
    refute_includes serialized, BLOB
    refute_match(/secret_hash|signing_response|SigningPubKey|TxnSignature|tx_blob/i, serialized)
  end
end
