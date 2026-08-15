# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require_relative "../lib/xrpl_reserve_study"
require_relative "task3_loopback_mtls_rpc_server"

class CompleteReservesSeedBuilderTest < Minitest::Test
  class SeedRpcState
    attr_reader :funded_accounts, :funding_amounts, :recipes, :fund_calls, :account_balances,
                :recipe_requests, :submission_attempts

    def initialize(class_counts: { "offer" => 1 }, fail_fund: false, fail_finality: 0,
                   fee_drops: 10, enforce_submission_limits: true, reported_balance: nil,
                   reported_account: nil,
                   resource_snapshot: { "rss_bytes" => 1024, "ledger_entries" => 3 })
      @funded_accounts = []
      @funding_amounts = []
      @recipes = []
      @recipe_requests = []
      @submission_attempts = []
      @fund_calls = 0
      @class_counts = class_counts
      @remaining_fund_failures = fail_fund == true ? 1 : (fail_fund == false ? 0 : Integer(fail_fund))
      @remaining_finality_failures = fail_finality
      @fee_drops = fee_drops
      @enforce_submission_limits = enforce_submission_limits
      @reported_balance = reported_balance
      @reported_account = reported_account
      @resource_snapshot = resource_snapshot
      @sequence = 0
      @transactions = {}
      @account_balances = {}
    end

    def call(method, params)
      case method
      when "wallet_propose" then wallet_propose(params)
      when "fund_account" then fund_account(params)
      when "submit_recipe" then submit_recipe(params)
      when "validated_transaction" then validated_transaction(params)
      when "ledger_counts" then ledger_counts(params)
      when "amendment_active" then true
      when "resource_snapshot" then @resource_snapshot
      else raise "unexpected RPC method: #{method}"
      end
    end

    private

    def wallet_propose(params)
      passphrase = params.fetch("passphrase")
      { "account_id" => "r#{passphrase[0, 20]}", "secret" => +"runtime-secret-#{passphrase[0, 8]}" }
    end

    def fund_account(params)
      @fund_calls += 1
      if @remaining_fund_failures.positive?
        @remaining_fund_failures -= 1
        raise XrplReserveStudy::IsolatedTransactionClientError, "injected funding failure"
      end
      account = params.fetch("account")
      amount_drops = params.fetch("amount_drops")
      @funded_accounts << account
      @funding_amounts << amount_drops
      @account_balances[account] = amount_drops
      response(kind: "fund", account: account)
    end

    def submit_recipe(params)
      fees = Array.new(params.fetch("creation_steps").length, @fee_drops)
      @submission_attempts << params
      if @enforce_submission_limits
        raise "recipe fee exceeds submitted maximum" if fees.any? { |fee| fee > params.fetch("max_fee_drops_per_step") }
        remaining = @account_balances.fetch(params.fetch("owner")) - fees.sum
        raise "recipe would consume account reserve" if remaining < params.fetch("reserve_floor_drops")
      end
      @recipes << params.fetch("recipe_kind")
      @recipe_requests << params
      { "steps" => fees.map { |fee| response(kind: "recipe", account: params.fetch("owner"), fee_drops: fee) } }
    end

    def validated_transaction(params)
      if @remaining_finality_failures.positive?
        @remaining_finality_failures -= 1
        raise XrplReserveStudy::IsolatedTransactionClientError, "ambiguous finality"
      end
      hash = params.fetch("hash")
      transaction = @transactions.fetch(hash)
      if transaction.fetch(:kind) == "recipe" && !transaction[:applied]
        @account_balances[transaction.fetch(:account)] -= transaction.fetch(:fee_drops)
        transaction[:applied] = true
      end
      balance = @reported_balance || @account_balances.fetch(transaction.fetch(:account))
      { "hash" => hash, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => @sequence + 1,
        "ledger_hash" => "F" * 64, "network_id" => "candidate-task3", "fee_drops" => transaction.fetch(:fee_drops),
        "account" => @reported_account || transaction.fetch(:account), "account_balance_drops" => balance }
    end

    def ledger_counts(params)
      { "validated" => true, "network_id" => "candidate-task3", "ledger_index" => params.fetch("ledger_index"), "ledger_hash" => params.fetch("ledger_hash"),
        "classifier_version" => "owner-object-classifier-v1", "account_roots" => 2, "class_counts" => @class_counts, "locked_xrp_drops" => 2_200_000, "released_xrp_drops" => 0 }
    end

    def response(kind:, account:, fee_drops: @fee_drops)
      @sequence += 1
      hash = format("%064X", @sequence)
      @transactions[hash] = { kind: kind, account: account, fee_drops: fee_drops }
      { "hash" => hash }
    end
  end

  CELL = {
    "cell_id" => "seed-cell-1", "profile_id" => "complete-reserves-calibrated-v1",
    "account_root_target" => 2, "owned_object_target" => 1,
    "base_reserve_drops" => 1_000_000, "owner_reserve_drops" => 200_000, "fee_headroom_drops_per_step" => 10,
    "execution_limits" => { "max_batch_size" => 2, "max_retries" => 0, "deadline_seconds" => 30 }
  }.freeze
  WORKLOAD = {
    "accounts" => [{ "ordinal" => 1, "account_id" => "account-1" }, { "ordinal" => 2, "account_id" => "account-2" }],
    "objects" => [{ "ordinal" => 1, "object_type" => "offer", "owner" => "object-owner-1", "controller_ordinal" => 1 }]
  }.freeze

  def setup
    @servers = []
    @connections = []
  end

  def teardown
    @connections.each(&:close)
    @servers.each(&:stop)
  end

  def test_builds_a_non_counted_seed_state_with_exact_final_counts_and_sanitized_measurements
    transport = SeedRpcState.new
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
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
    assert_equal [1_000_000, 1_200_010], transport.funding_amounts.sort
  end

  def test_rejects_a_public_client_before_reading_the_protected_authority
    read = false
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: Object.new
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { read = true; +"protected-root-authority" })
    end

    assert_equal "isolated transaction client is required", error.message
    refute read
  end

  def test_rejects_final_ledger_counts_that_do_not_match_the_workload
    transport = SeedRpcState.new(class_counts: { "offer" => 2 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "final ledger counts do not match workload", error.message
  end

  def test_rejects_missing_resource_measurements
    transport = SeedRpcState.new(resource_snapshot: {})
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "resource snapshot is invalid", error.message
  end

  def test_does_not_retry_a_submission_when_the_approved_profile_disallows_retries
    transport = SeedRpcState.new(fail_fund: true)
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    assert_equal 1, transport.fund_calls
  end

  def test_wipes_the_reader_authority_after_a_successful_build
    authority = +"protected-root-authority"
    transport = SeedRpcState.new
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { authority })

    assert_empty authority
  end

  def test_counts_a_failed_submission_when_an_approved_retry_later_succeeds
    transport = SeedRpcState.new(fail_fund: 1)
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 1, "deadline_seconds" => 30 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })

    assert_equal 4, result.fetch("attempted_transactions")
    assert_equal 3, result.fetch("validated_transactions")
    assert_equal 3, transport.fund_calls
  end

  def test_rejects_non_finite_resource_measurements
    transport = SeedRpcState.new(resource_snapshot: { "rss_bytes" => Float::NAN })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    assert_equal "private network RPC returned an error", error.message
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
    transport = SeedRpcState.new(class_counts: { "offer" => 2, "trust_line" => 1 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
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
    transport = SeedRpcState.new(class_counts: { "xchain_owned_create_account_claim_id" => 1 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: CELL, workload: compound, secret_reader: -> { +"protected-root-authority" })

    assert_equal 4, result.fetch("validated_transactions")
    assert_equal 40, result.fetch("burned_fee_drops")
  end

  def test_rejects_a_finality_that_arrives_after_the_approved_deadline
    ticks = [0.0, 0.0, 0.0, 2.0]
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 0, "deadline_seconds" => 1.0 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: client_for(SeedRpcState.new), clock: -> { ticks.shift || 2.0 }
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "complete reserves seed deadline exceeded", error.message
  end

  def test_polls_an_ambiguous_finality_without_resubmitting_the_funded_account
    transport = SeedRpcState.new(fail_finality: 1)
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 1, "deadline_seconds" => 30 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(transport), clock: -> { 10.0 })

    result = builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })

    assert_equal 2, transport.fund_calls
    assert_equal 3, result.fetch("attempted_transactions")
  end

  def test_accepts_a_frozen_legacy_workload_without_mutating_it
    workload = {
      "accounts" => WORKLOAD.fetch("accounts").map(&:dup).map(&:freeze).freeze,
      "objects" => [{ "ordinal" => 1, "object_type" => "offer", "owner" => "legacy-owner" }.freeze].freeze
    }.freeze
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(SeedRpcState.new), clock: -> { 10.0 })

    result = builder.build(cell: CELL, workload: workload, secret_reader: -> { +"protected-root-authority" })

    assert_equal 3, result.fetch("validated_transactions")
    refute workload.fetch("objects").first.key?("controller_ordinal")
  end

  def test_never_resubmits_after_two_ambiguous_finality_failures
    transport = SeedRpcState.new(fail_finality: 2)
    cell = CELL.merge("execution_limits" => { "max_batch_size" => 2, "max_retries" => 1, "deadline_seconds" => 30 })
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(transport), clock: -> { 10.0 })

    assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: cell, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    assert_equal 1, transport.fund_calls
  end

  def test_rejects_zero_or_undersized_recipe_fee_headroom
    zero = CELL.merge("fee_headroom_drops_per_step" => 0)
    high_fee = SeedRpcState.new(fee_drops: 11, enforce_submission_limits: false)
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(high_fee), clock: -> { 10.0 })

    zero_error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: zero, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end
    headroom_error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "positive fee headroom is required", zero_error.message
    assert_equal "observed recipe fee exceeds approved headroom", headroom_error.message
  end

  def test_submits_an_enforced_fee_ceiling_and_reserve_floor_before_any_recipe_hash_exists
    transport = SeedRpcState.new(fee_drops: 11)
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(transport), clock: -> { 10.0 })

    assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    request = transport.submission_attempts.fetch(0)
    assert_equal 10, request.fetch("max_fee_drops_per_step")
    assert_equal 1_200_000, request.fetch("reserve_floor_drops")
    assert_empty transport.recipes
    assert_equal 1_200_010, transport.account_balances.values.max
  end

  def test_rejects_an_observed_recipe_balance_below_the_required_reserve
    transport = SeedRpcState.new(enforce_submission_limits: false, reported_balance: 1_199_999)
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(transport), clock: -> { 10.0 })

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "observed recipe balance is below required reserve", error.message
  end

  def test_rejects_a_reserve_balance_reported_for_a_different_account
    transport = SeedRpcState.new(enforce_submission_limits: false, reported_account: "rDifferentAccount")
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(client: client_for(transport), clock: -> { 10.0 })

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })
    end

    assert_equal "observed recipe balance is not bound to the owner", error.message
  end

  private

  def client_for(state)
    server = Task3LoopbackMutualTlsRpcServer.new { |method, params| state.call(method, params) }
    @servers << server
    connection = XrplReserveStudy::PrivateNetworkConnection.new(**server.connection_options)
    @connections << connection
    adapter = XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter.new(connection: connection)
    XrplReserveStudy::IsolatedTransactionClient.new(transport: adapter)
  end
end
