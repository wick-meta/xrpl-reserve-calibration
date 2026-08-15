# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class IsolatedTransactionClientTest < Minitest::Test
  class Transport
    def initialize(isolated: true, finality: nil)
      @isolated = isolated
      @finality = finality || { "hash" => "A" * 64, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => 9, "fee_drops" => 12 }
    end

    def isolated?; @isolated; end
    def wallet_propose(passphrase:); { "account_id" => "rRuntimeSigner", "secret" => +"runtime-secret" }; end
    def fund_account(account:, amount_drops:, root_secret:); { "hash" => "A" * 64 }; end
    def submit_recipe(recipe:, owner:, signer:); { "hash" => "A" * 64 }; end
    def validated_transaction(hash:); @finality; end
    def ledger_counts; { "account_roots" => 0, "owner_objects" => {}, "locked_xrp_drops" => 0, "released_xrp_drops" => 0 }; end
    def amendment_active?(amendment:); true; end
    def resource_snapshot; { "rss_bytes" => 1 }; end
  end

  def test_rejects_a_non_isolated_transport_before_forwarding_a_wallet_request
    client = XrplReserveStudy::IsolatedTransactionClient.new(transport: Transport.new(isolated: false))

    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.wallet_propose(passphrase: "authority") }

    assert_equal "isolated transaction client requires an isolated endpoint", error.message
  end

  def test_accepts_only_a_validated_successful_final_transaction_with_the_requested_hash
    transport = Transport.new(finality: { "hash" => "B" * 64, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => 9, "fee_drops" => 12 })
    client = XrplReserveStudy::IsolatedTransactionClient.new(transport: transport)

    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.validated_transaction(hash: "A" * 64) }

    assert_equal "isolated transaction finality is invalid", error.message
  end

  def test_rejects_a_recipe_that_did_not_come_from_the_recipe_registry
    client = XrplReserveStudy::IsolatedTransactionClient.new(transport: Transport.new)

    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) do
      client.submit_recipe(recipe: { "transaction_type" => "OfferCreate" }, owner: "rOwner", signer: Object.new)
    end

    assert_equal "owner object recipe is not allowlisted", error.message
  end

  def test_does_not_expose_an_arbitrary_rpc_escape_hatch
    client = XrplReserveStudy::IsolatedTransactionClient.new(transport: Transport.new)

    refute_respond_to client, :call
  end
end
