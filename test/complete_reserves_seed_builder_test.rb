# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesSeedBuilderTest < Minitest::Test
  class IsolatedTransport
    attr_reader :funded_accounts, :recipes

    def initialize(isolated: true)
      @isolated = isolated
      @funded_accounts = []
      @recipes = []
      @sequence = 0
    end

    def isolated?; @isolated; end

    def wallet_propose(passphrase:)
      { "account_id" => "r#{passphrase[0, 20]}", "secret" => +"runtime-secret-#{passphrase[0, 8]}" }
    end

    def fund_account(account:, amount_drops:, root_secret:)
      @funded_accounts << account
      response
    end

    def submit_recipe(recipe:, owner:, signer:)
      @recipes << recipe.kind
      response
    end

    def validated_transaction(hash:)
      { "hash" => hash, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => @sequence + 1, "fee_drops" => 10 }
    end

    def ledger_counts
      { "account_roots" => 2, "owner_objects" => { "offer" => 1 }, "locked_xrp_drops" => 2_200_000, "released_xrp_drops" => 0 }
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
    "objects" => [{ "ordinal" => 1, "object_type" => "offer", "owner" => "account-1" }]
  }.freeze

  def test_builds_a_non_counted_seed_state_with_exact_final_counts_and_sanitized_measurements
    transport = IsolatedTransport.new
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: transport), clock: -> { 10.0 }
    )

    result = builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { +"protected-root-authority" })

    assert_equal false, result.fetch("counted_run")
    assert_equal 2, result.fetch("validated_account_roots")
    assert_equal({ "offer" => 1 }, result.fetch("validated_owner_objects"))
    assert_equal 3, result.fetch("validated_transactions")
    assert_equal 30, result.fetch("burned_fee_drops")
    assert_equal 2_200_000, result.fetch("locked_xrp_drops")
    assert_equal 0, result.fetch("released_xrp_drops")
    assert_equal %w[after before], result.fetch("resource_snapshots").map { |entry| entry.fetch("phase") }.sort
    assert_equal %w[offer], transport.recipes
  end

  def test_rejects_a_public_client_before_reading_the_protected_authority
    read = false
    builder = XrplReserveStudy::CompleteReservesSeedBuilder.new(
      client: XrplReserveStudy::IsolatedTransactionClient.new(transport: IsolatedTransport.new(isolated: false))
    )

    error = assert_raises(XrplReserveStudy::CompleteReservesSeedBuilderError) do
      builder.build(cell: CELL, workload: WORKLOAD, secret_reader: -> { read = true; +"protected-root-authority" })
    end

    assert_equal "isolated candidate network is required", error.message
    refute read
  end

  def test_rejects_final_ledger_counts_that_do_not_match_the_workload
    transport = IsolatedTransport.new
    transport.define_singleton_method(:ledger_counts) do
      { "account_roots" => 2, "owner_objects" => { "offer" => 2 }, "locked_xrp_drops" => 2_400_000, "released_xrp_drops" => 0 }
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
end
