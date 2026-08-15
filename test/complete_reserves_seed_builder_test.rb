# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesSeedBuilderTest < Minitest::Test
  class IsolatedTransport < XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter
    attr_reader :funded_accounts, :funding_amounts, :recipes, :fund_calls

    def initialize(isolated: true, class_counts: { "offer" => 1 }, fail_fund: false)
      super(endpoint_identity: {
        "adapter_kind" => "pinned-private-network-candidate-v1", "authenticated" => true,
        "endpoint_sha256" => "b" * 64, "network_id" => "candidate-task3", "public_endpoint" => false
      })
      @isolated = isolated
      @funded_accounts = []
      @funding_amounts = []
      @recipes = []
      @fund_calls = 0
      @class_counts = class_counts
      @remaining_fund_failures = fail_fund == true ? 1 : (fail_fund == false ? 0 : Integer(fail_fund))
      @sequence = 0
    end

    def isolated?; @isolated; end

    def wallet_propose(passphrase:)
      { "account_id" => "r#{passphrase[0, 20]}", "secret" => +"runtime-secret-#{passphrase[0, 8]}" }
    end

    def fund_account(account:, amount_drops:, root_secret:)
      @fund_calls += 1
      if @remaining_fund_failures.positive?
        @remaining_fund_failures -= 1
        raise XrplReserveStudy::IsolatedTransactionClientError, "injected funding failure"
      end
      @funded_accounts << account
      @funding_amounts << amount_drops
      response
    end

    def submit_recipe(recipe:, owner:, signer:)
      @recipes << recipe.kind
      { "steps" => recipe.creation_steps.map { response } }
    end

    def validated_transaction(hash:)
      { "hash" => hash, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => @sequence + 1,
        "ledger_hash" => "F" * 64, "network_id" => "candidate-task3", "fee_drops" => 10 }
    end

    def ledger_counts(ledger_index:, ledger_hash:)
      { "validated" => true, "network_id" => "candidate-task3", "ledger_index" => ledger_index, "ledger_hash" => ledger_hash,
        "classifier_version" => "owner-object-classifier-v1", "account_roots" => 2, "class_counts" => @class_counts, "locked_xrp_drops" => 2_200_000, "released_xrp_drops" => 0 }
    end

    def amendment_active?(amendment:); true; end
    def resource_snapshot; { "rss_bytes" => 1024, "ledger_entries" => 3 }; end

    private

    def response
      @sequence += 1
      { "hash" => format("%064X", @sequence) }
    end
  end

  CELL = {
    "cell_id" => "seed-cell-1", "profile_id" => "complete-reserves-calibrated-v1",
    "account_root_target" => 2, "owned_object_target" => 1,
    "base_reserve_drops" => 1_000_000, "owner_reserve_drops" => 200_000,
    "execution_limits" => { "max_batch_size" => 2, "max_retries" => 0, "deadline_seconds" => 30 }
  }.freeze
  WORKLOAD = {
    "accounts" => [{ "ordinal" => 1, "account_id" => "account-1" }, { "ordinal" => 2, "account_id" => "account-2" }],
    "objects" => [{ "ordinal" => 1, "object_type" => "offer", "owner" => "object-owner-1", "controller_ordinal" => 1 }]
  }.freeze

  def test_builds_a_non_counted_seed_state_with_exact_final_counts_and_sanitized_measurements
    transport = IsolatedTransport.new
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })

    assert_equal false, result.fetch("counted_run")
    assert_equal 2, result.fetch("classified_ledger_evidence").fetch("account_roots")
    assert_equal({ "offer" => 1 }, result.fetch("classified_ledger_evidence").fetch("class_counts"))
    assert_equal 3, result.fetch("validated_transactions")
    assert_equal 30, result.fetch("burned_fee_drops")
    assert_equal 2_200_000, result.fetch("locked_xrp_drops")
    assert_equal 0, result.fetch("released_xrp_drops")
    assert_equal %w[after before], result.fetch("resource_snapshots").map { |entry| entry.fetch("phase") }.sort
    assert_equal %w[offer], transport.recipes
    assert_equal [1_000_000, 1_200_000], transport.funding_amounts.sort
  end

  def test_rejects_a_public_client_before_reading_the_protected_authority
    read = false
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: IsolatedTransport.new(isolated: false))
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { read = true; +"protected-root-authority" })
    end

    assert_equal "isolated transaction client is required", error.message
    refute read
  end

  def test_rejects_final_ledger_counts_that_do_not_match_the_workload
    transport = IsolatedTransport.new
    transport.define_singleton_method(:ledger_counts) do |ledger_index:, ledger_hash:|
      { "validated" => true, "network_id" => "candidate-task3", "ledger_index" => ledger_index, "ledger_hash" => ledger_hash,
        "classifier_version" => "owner-object-classifier-v1", "account_roots" => 2, "class_counts" => { "offer" => 2 }, "locked_xrp_drops" => 2_400_000, "released_xrp_drops" => 0 }
    end
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "final ledger counts do not match workload", error.message
  end

  def test_rejects_missing_resource_measurements
    transport = IsolatedTransport.new
    transport.define_singleton_method(:resource_snapshot) { {} }
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "resource snapshot is invalid", error.message
  end

  def test_does_not_retry_a_submission_when_the_approved_profile_disallows_retries
    transport = IsolatedTransport.new(fail_fund: true)
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    assert_equal 1, transport.fund_calls
  end

  def test_wipes_the_reader_authority_after_a_successful_build
    authority = +"protected-root-authority"
    transport = IsolatedTransport.new
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { authority })

    assert_empty authority
  end

  def test_counts_a_failed_submission_when_an_approved_retry_later_succeeds
    transport = IsolatedTransport.new(fail_fund: 1)
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 1, "deadline_seconds" => 30 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })

    assert_equal 4, result.fetch("attempted_transactions")
    assert_equal 3, result.fetch("validated_transactions")
    assert_equal 3, transport.fund_calls
  end

  def test_rejects_non_finite_resource_measurements
    transport = IsolatedTransport.new
    transport.define_singleton_method(:resource_snapshot) { { "rss_bytes" => Float::NAN } }
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    assert_equal "resource snapshot is invalid", error.message
  end

  def test_accepts_controller_mapping_from_a_generated_complete_reserves_workload
    distribution = { "account_roots" => 2, "class_counts" => { "offer" => 2, "trust_line" => 1 } }
    run = XrplReserveStudy::CompleteReservesStudy.new(File.expand_path("../study/complete-reserves-v1.yml", __dir__))
                                                .plan(distribution: { "account_roots" => 2, "owned_objects" => 3 })
                                                .fetch("runs").find { |candidate| candidate.fetch("scale") == 1.0 }
    directory = File.expand_path("../capacity/runtime/task-3-generated-#{Process.pid}-#{rand(1_000_000)}", __dir__)
    XrplReserveStudy::CompleteReservesWorkload.new.generate(run: run, distribution: distribution, output_dir: directory)
    workload = {
      "accounts" => File.readlines(File.join(directory, "accounts.jsonl"), chomp: true).map { |line| JSON.parse(line) },
      "objects" => File.readlines(File.join(directory, "objects.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    }
    cell = CELL.merge("account_root_target" => 2, "owned_object_target" => 3)
    transport = IsolatedTransport.new(class_counts: { "offer" => 2, "trust_line" => 1 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: cell, workload: workload, secret_reader: -> { +"protected-root-authority" })

    assert_equal({ "offer" => 2, "trust_line" => 1 }, result.fetch("classified_ledger_evidence").fetch("class_counts"))
    assert workload.fetch("objects").all? { |object| object.fetch("controller_ordinal").between?(1, 2) }
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  def test_records_every_step_of_a_compound_recipe
    compound = {
      "accounts" => WORKLOAD.fetch("accounts"),
      "objects" => [{ "ordinal" => 1, "object_type" => "xchain_owned_create_account_claim_id", "owner" => "compound-owner", "controller_ordinal" => 1 }]
    }
    transport = IsolatedTransport.new(class_counts: { "xchain_owned_create_account_claim_id" => 1 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: CELL, workload: compound, secret_reader: -> { +"protected-root-authority" })

    assert_equal 4, result.fetch("validated_transactions")
    assert_equal 40, result.fetch("burned_fee_drops")
  end

  def test_rejects_a_finality_that_arrives_after_the_approved_deadline
    ticks = [0.0, 0.0, 0.0, 2.0]
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 0, "deadline_seconds" => 1.0 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: IsolatedTransport.new), clock: -> { ticks.shift || 2.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "complete reserves seed deadline exceeded", error.message
  end
end
