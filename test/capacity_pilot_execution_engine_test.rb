# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CapacityPilotExecutionEngineTest < Minitest::Test
  SOURCE = XrplReserveStudy::WorkloadGenerator::SOURCE_ACCOUNT
  DESTINATIONS = %w[
    rPh7FjNmSnqQGC5zni2dA52UpxgYMy4Yc3
    rwKFceaiJ3eFYUYWrhAamfV8Z4wei5FJxq
    rrmaT2jDvv1cCzL5zLsav1XX2hXx9iXHz
  ].freeze
  LEDGER_HASHES = ("A".."F").map { |character| character * 64 }.freeze
  TX_HASHES = %w[7 8 9].map { |character| character * 64 }.freeze
  BLOB = "AB" * 32
  PUBLIC_KEY = "A" * 66
  SIGNATURE = "B" * 140

  class Client
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(command, parameters = {}, secret: nil)
      @calls << [command, Marshal.load(Marshal.dump(parameters)), secret&.dup]
      response = @responses.shift
      raise response if response.is_a?(Exception)
      Marshal.load(Marshal.dump(response))
    end
  end

  def test_runs_only_the_exact_schedule_and_returns_closed_sanitized_records
    client = Client.new(responses_for(ordinal: 1, preflight: 2, source_balance: "2000000"))
    engine = build_engine(client)
    authority = +"stubbed-authority"
    record = nil

    engine.stub(:valid_authority?, true) do
      engine.with_authority(authority) do |session|
        record = session.execute_scheduled(
          measurement_sample_sequence: 1,
          previous_ledger: ledger(2, LEDGER_HASHES[0])
        )
      end
    end

    assert_equal %w[server_info account_info sign submit ledger_accept tx account_info], client.calls.map(&:first)
    assert_equal({ "account" => SOURCE, "ledger_hash" => LEDGER_HASHES[0] }, client.calls.fetch(1).fetch(1))
    assert_equal execution_keys.sort, record.keys.sort
    assert_equal [1, 1, DESTINATIONS[0], TX_HASHES[0], 3, LEDGER_HASHES[1]], [
      record["ordinal"], record["measurement_sample_sequence"], record["destination_account"],
      record["transaction_hash"], record["validated_ledger_index"], record["validated_ledger_hash"]
    ]
    assert_equal "validated-success", record["status"]
    assert_equal false, record["counted_run"]
    assert record.frozen?
    assert_empty authority
    assert_sanitized(record)
  end

  def test_prepares_signing_and_submission_before_separately_advancing_the_ledger
    client = Client.new(responses_for(ordinal: 1, preflight: 2, source_balance: "2000000"))
    engine = build_engine(client)
    record = nil
    engine.stub(:valid_authority?, true) do
      engine.with_authority(+"stubbed-authority") do |session|
        attempt = session.prepare_scheduled(
          measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0])
        )
        assert attempt.frozen?
        assert_equal %w[server_info account_info sign submit], client.calls.map(&:first)
        refute_includes client.calls.map(&:first), "ledger_accept"
        record = session.advance_scheduled(attempt: attempt)
      end
    end
    assert_equal %w[server_info account_info sign submit ledger_accept tx account_info], client.calls.map(&:first)
    assert_equal "validated-success", record["status"]
  end

  def test_reports_the_ledger_advance_boundary_before_finality_and_destination_checks
    client = Client.new(responses_for(ordinal: 1, preflight: 2, source_balance: "2000000"))
    engine = build_engine(client)
    boundary_calls = nil

    engine.stub(:valid_authority?, true) do
      engine.with_authority(+"stubbed-authority") do |session|
        attempt = session.prepare_scheduled(
          measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0])
        )
        session.advance_scheduled(attempt: attempt, on_ledger_advance: lambda {
          boundary_calls = client.calls.map(&:first)
        })
      end
    end

    assert_equal %w[server_info account_info sign submit ledger_accept], boundary_calls
    assert_equal %w[server_info account_info sign submit ledger_accept tx account_info], client.calls.map(&:first)
  end

  def test_enforces_all_three_ordinals_without_retry_or_reordering
    responses = []
    responses.concat(responses_for(ordinal: 1, preflight: 2, source_balance: "2000000"))
    responses.concat(responses_for(ordinal: 2, preflight: 451, source_balance: "1499990"))
    responses.concat(responses_for(ordinal: 3, preflight: 901, source_balance: "999980"))
    engine = build_engine(Client.new(responses))
    records = nil

    engine.stub(:valid_authority?, true) do
      engine.with_authority(+"stubbed-authority") do |session|
        records = [
          session.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0])),
          session.execute_scheduled(measurement_sample_sequence: 450, previous_ledger: ledger(451, LEDGER_HASHES[2])),
          session.execute_scheduled(measurement_sample_sequence: 900, previous_ledger: ledger(901, LEDGER_HASHES[4]))
        ]
        assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
          session.execute_scheduled(measurement_sample_sequence: 900, previous_ledger: ledger(902, LEDGER_HASHES[5]))
        end
      end
    end

    assert_equal [1, 2, 3], records.map { |record| record["ordinal"] }
    assert_equal [1, 450, 900], records.map { |record| record["measurement_sample_sequence"] }
    assert_equal 3, engine.completed_records.length
  end

  def test_rejects_invalid_bundle_schedule_and_mutable_inputs_before_rpc
    mutations = [
      ->(bundle) { bundle["intents"].reverse! },
      ->(bundle) { bundle["intents"][0]["ordinal"] = 2 },
      ->(bundle) { bundle["intents"][0]["transaction_type"] = "OfferCreate" },
      ->(bundle) { bundle["intents"][0]["network_id"] = 21_338.0 },
      ->(bundle) { bundle["intents"][0]["destination_account"] = DESTINATIONS[1] },
      ->(bundle) { bundle["extra"] = "forbidden" }
    ]
    mutations.each do |mutation|
      candidate = mutable_bundle
      mutation.call(candidate)
      deep_freeze(candidate)
      assert_raises(XrplReserveStudy::CapacityPilotExecutionError) { build_engine(Client.new([]), candidate) }
    end
    assert_raises(XrplReserveStudy::CapacityPilotExecutionError) { build_engine(Client.new([]), mutable_bundle) }
  end

  def test_rejects_and_erases_invalid_authority_before_rpc
    client = Client.new([])
    authority = +"invalid-authority"
    error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
      build_engine(client).with_authority(authority) { flunk "authority was accepted" }
    end
    assert_equal "invalid-signing-authority", error.code
    assert_empty authority
    assert_empty client.calls
  end

  def test_rejects_schedule_type_order_and_previous_ledger_mutations_without_rpc
    [[450, ledger(2, LEDGER_HASHES[0])], [1.0, ledger(2, LEDGER_HASHES[0])], [1, ledger(3, LEDGER_HASHES[0])],
     [1, { "validated_ledger_index" => 2, "validated_ledger_hash" => LEDGER_HASHES[0], "extra" => 1 }]].each do |sequence, previous|
      client = Client.new([])
      engine = build_engine(client)
      error = nil
      engine.stub(:valid_authority?, true) do
        engine.with_authority(+"stubbed-authority") do |session|
          error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
            session.execute_scheduled(measurement_sample_sequence: sequence, previous_ledger: previous)
          end
        end
      end
      assert_empty client.calls
      assert_equal 0, error.progress["completed_transaction_count"]
    end
  end

  def test_rejects_each_runtime_boundary_and_preserves_only_completed_progress
    mutations = {
      "build" => [0, ->(value) { value.dig("info")["build_version"] = "3.2.0" }],
      "network" => [0, ->(value) { value.dig("info")["network_id"] = 1 }],
      "peers" => [0, ->(value) { value.dig("info")["peers"] = 1 }],
      "quorum" => [0, ->(value) { value.dig("info")["validation_quorum"] = 1 }],
      "reserve" => [0, ->(value) { value.dig("info", "validated_ledger")["reserve_base_xrp"] = 1 }],
      "ledger index" => [0, ->(value) { value.dig("info", "validated_ledger")["seq"] = 3 }],
      "ledger hash" => [0, ->(value) { value.dig("info", "validated_ledger")["hash"] = LEDGER_HASHES[1] }],
      "source identity" => [1, ->(value) { value.dig("account_data")["Account"] = DESTINATIONS[0] }],
      "source sequence" => [1, ->(value) { value.dig("account_data")["Sequence"] = 2 }],
      "source balance" => [1, ->(value) { value.dig("account_data")["Balance"] = "500009" }],
      "source hash absent" => [1, ->(value) { value.delete("ledger_hash") }],
      "source hash malformed" => [1, ->(value) { value["ledger_hash"] = "a" * 64 }],
      "source hash moved" => [1, ->(value) { value["ledger_hash"] = LEDGER_HASHES[1] }],
      "source index moved" => [1, ->(value) { value["ledger_index"] += 1 }],
      "source extra response" => [1, ->(value) { value["extra"] = true }],
      "source extra account field" => [1, ->(value) { value.fetch("account_data")["extra"] = true }],
      "source nil account flags" => [1, ->(value) { value["account_flags"] = nil }],
      "source unknown account flag" => [1, ->(value) { value["account_flags"] = { "unknown" => false } }],
      "signing unsigned field" => [2, ->(value) { value.dig("tx_json")["NetworkID"] = 1 }],
      "blob" => [2, ->(value) { value["tx_blob"] = "A" * 1_048_578 }],
      "hash" => [2, ->(value) { value["hash"] = "a" * 64 }],
      "preliminary" => [3, ->(value) { value["engine_result"] = "tecFAILED" }],
      "advancement" => [4, ->(value) { value["ledger_current_index"] = 5 }],
      "finality" => [5, ->(value) { value["validated"] = false }],
      "final index" => [5, ->(value) { value["ledger_index"] = 4 }],
      "final hash" => [5, ->(value) { value["ledger_hash"] = LEDGER_HASHES[2] }],
      "final result" => [5, ->(value) { value.dig("meta")["TransactionResult"] = "tecFAILED" }],
      "destination" => [6, ->(value) { value.dig("account_data")["Account"] = SOURCE }],
      "destination balance" => [6, ->(value) { value.dig("account_data")["Balance"] = "1" }]
    }
    mutations.each do |name, (index, mutation)|
      responses = responses_for(ordinal: 1, preflight: 2, source_balance: "2000000")
      mutation.call(responses.fetch(index))
      client = Client.new(responses)
      error = nil
      authority = +"stubbed-authority"
      engine = build_engine(client)
      engine.stub(:valid_authority?, true) do
        error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError, name) do
          engine.with_authority(authority) do |session|
            session.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0]))
          end
        end
      end
      assert_equal 0, error.progress["completed_transaction_count"], name
      expected_validated = (name.start_with?("destination") || name == "final hash") ? 1 : 0
      assert_equal expected_validated, error.progress["validated_transaction_count"], name
      assert_empty authority, name
      assert_sanitized(error.progress, name)
      refute_includes error.message, BLOB, name
    end
  end

  def test_rpc_failure_and_interruption_are_sanitized_and_terminal
    [XrplReserveStudy::CapacityRpcError.new("raw #{BLOB}"), Interrupt.new("raw #{BLOB}")].each do |failure|
      responses = responses_for(ordinal: 1, preflight: 2, source_balance: "2000000")
      responses[2] = failure
      engine = build_engine(Client.new(responses))
      authority = +"stubbed-authority"
      error = nil
      engine.stub(:valid_authority?, true) do
        error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
          engine.with_authority(authority) do |session|
            session.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0]))
          end
        end
      end
      assert_empty authority
      assert_sanitized(error.progress)
      assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
        engine.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0]))
      end
    end
  end

  def test_interruption_after_validated_finality_preserves_count_without_fabricating_a_record
    responses = responses_for(ordinal: 1, preflight: 2, source_balance: "2000000")
    responses[6] = Interrupt.new("controlled interruption")
    engine = build_engine(Client.new(responses))
    error = nil
    engine.stub(:valid_authority?, true) do
      error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
        engine.with_authority(+"stubbed-authority") do |session|
          session.execute_scheduled(
            measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0])
          )
        end
      end
    end
    assert_equal "interrupted", error.code
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 0, error.progress["completed_transaction_count"]
    assert_empty error.progress["completed_records"]
  end

  def test_rejects_every_missing_or_extra_signing_field_and_string_bound
    mutations = []
    %w[deprecated hash status tx_blob tx_json].each do |key|
      mutations << ->(response) { response.delete(key) }
    end
    %w[Account DeliverMax Destination Fee Flags LastLedgerSequence NetworkID Sequence SigningPubKey TransactionType TxnSignature].each do |key|
      mutations << ->(response) { response.fetch("tx_json").delete(key) }
    end
    mutations.concat([
      ->(response) { response["extra"] = true },
      ->(response) { response.fetch("tx_json")["extra"] = true },
      ->(response) { response["deprecated"] = "x" * 257 },
      ->(response) { response.fetch("tx_json")["SigningPubKey"] = "A" * 65 },
      ->(response) { response.fetch("tx_json")["TxnSignature"] = "B" * 135 }
    ])

    mutations.each_with_index do |mutation, index|
      responses = responses_for(ordinal: 1, preflight: 2, source_balance: "2000000")
      mutation.call(responses.fetch(2))
      error = first_execution_error(responses)
      assert_includes %w[invalid-signing-response invalid-transaction-blob invalid-transaction-hash], error.code, index
      assert_equal 0, error.progress["validated_transaction_count"], index
      assert_sanitized(error.progress, index)
    end
  end

  def test_rejects_source_balance_drift_across_successive_ordinals
    responses = responses_for(ordinal: 1, preflight: 2, source_balance: "2000000")
    responses.concat(responses_for(ordinal: 2, preflight: 451, source_balance: "1499991"))
    engine = build_engine(Client.new(responses))
    error = nil
    engine.stub(:valid_authority?, true) do
      engine.with_authority(+"stubbed-authority") do |session|
        session.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0]))
        error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
          session.execute_scheduled(measurement_sample_sequence: 450, previous_ledger: ledger(451, LEDGER_HASHES[2]))
        end
      end
    end
    assert_equal "unexpected-source-balance", error.code
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 1, error.progress["completed_transaction_count"]
  end

  private

  def build_engine(client, bundle = pilot_bundle)
    XrplReserveStudy::CapacityPilotExecutionEngine.new(client: client, pilot_bundle: bundle)
  end

  def pilot_bundle
    deep_freeze(mutable_bundle)
  end

  def mutable_bundle
    {
      "run" => { "run_id" => "r0500000-a000010000-n01", "base_reserve_xrp" => 0.5, "account_count" => 10_000, "repetition" => 1 },
      "intents" => DESTINATIONS.each_with_index.map do |destination, index|
        { "ordinal" => index + 1, "transaction_type" => "Payment", "source_account" => SOURCE,
          "destination_account" => destination, "amount_drops" => "500000", "network_id" => 21_338 }
      end
    }
  end

  def responses_for(ordinal:, preflight:, source_balance:)
    destination = DESTINATIONS.fetch(ordinal - 1)
    final_hash = LEDGER_HASHES.fetch((ordinal * 2) - 1)
    transaction_hash = TX_HASHES.fetch(ordinal - 1)
    transaction = {
      "TransactionType" => "Payment", "Account" => SOURCE, "Destination" => destination,
      "Amount" => "500000", "Fee" => "10", "Sequence" => ordinal, "NetworkID" => 21_338,
      "Flags" => 2_147_483_648, "LastLedgerSequence" => preflight + 2
    }
    [
      { "info" => { "build_version" => "3.3.0", "network_id" => 21_338, "peers" => 0,
        "validation_quorum" => 0, "validated_ledger" => { "seq" => preflight, "hash" => LEDGER_HASHES.fetch((ordinal - 1) * 2), "reserve_base_xrp" => 0.5 } } },
      { "status" => "success", "validated" => true, "ledger_index" => preflight,
        "ledger_hash" => LEDGER_HASHES.fetch((ordinal - 1) * 2),
        "account_data" => { "Account" => SOURCE, "Sequence" => ordinal, "Balance" => source_balance,
          "Flags" => 0, "LedgerEntryType" => "AccountRoot", "OwnerCount" => 0,
          "PreviousTxnID" => LEDGER_HASHES.fetch((ordinal - 1) * 2), "PreviousTxnLgrSeq" => 1,
          "index" => LEDGER_HASHES.fetch((ordinal - 1) * 2) },
        "account_flags" => {} },
      signing_response(transaction, transaction_hash),
      { "accepted" => true, "applied" => true, "queued" => false, "engine_result" => "tesSUCCESS" },
      { "ledger_current_index" => preflight + 2 },
      { "validated" => true, "ledger_index" => preflight + 1, "ledger_hash" => final_hash,
        "hash" => transaction_hash, "meta" => { "TransactionResult" => "tesSUCCESS" },
        "tx_json" => { "Account" => SOURCE, "Destination" => destination, "DeliverMax" => "500000", "NetworkID" => 21_338, "Sequence" => ordinal } },
      { "validated" => true, "ledger_index" => preflight + 1, "ledger_hash" => final_hash,
        "account_data" => { "Account" => destination, "Balance" => "500000" } }
    ]
  end

  def signing_response(transaction, transaction_hash)
    signed = transaction.dup
    signed["DeliverMax"] = signed.delete("Amount")
    signed["SigningPubKey"] = PUBLIC_KEY
    signed["TxnSignature"] = SIGNATURE
    { "deprecated" => "test-only", "hash" => transaction_hash, "status" => "success", "tx_blob" => BLOB, "tx_json" => signed }
  end

  def ledger(index, hash)
    deep_freeze("validated_ledger_index" => index, "validated_ledger_hash" => hash)
  end

  def execution_keys
    %w[schema_version execution_scope run_id ordinal destination_account measurement_sample_sequence transaction_hash preliminary_result final_result validated_ledger_index validated_ledger_hash destination_accountroot_verified status counted_run]
  end

  def assert_sanitized(value, label = nil)
    encoded = JSON.generate(value)
    refute_match(/secret|seed|private|signed|signature|SigningPubKey|TxnSignature|tx_blob/i, encoded, label)
    refute_includes encoded, BLOB, label
  end

  def first_execution_error(responses)
    engine = build_engine(Client.new(responses))
    authority = +"stubbed-authority"
    error = nil
    engine.stub(:valid_authority?, true) do
      error = assert_raises(XrplReserveStudy::CapacityPilotExecutionError) do
        engine.with_authority(authority) do |session|
          session.execute_scheduled(measurement_sample_sequence: 1, previous_ledger: ledger(2, LEDGER_HASHES[0]))
        end
      end
    end
    assert_empty authority
    error
  end

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
    when Array then value.each { |nested| deep_freeze(nested) }
    end
    value.freeze
  end
end
