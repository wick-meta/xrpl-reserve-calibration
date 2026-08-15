# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class IsolatedTransactionClientTest < Minitest::Test
  class Connection < XrplReserveStudy::PrivateNetworkConnection
    def initialize(finality: nil)
      super(endpoint_uri: "https://127.0.0.1:5005/", endpoint_sha256: "a" * 64,
            client_certificate_sha256: "b" * 64, network_id: "candidate-task3")
      @finality = finality || { "hash" => "A" * 64, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => 9, "ledger_hash" => "C" * 64, "network_id" => "candidate-task3", "fee_drops" => 12 }
    end
    def handshake; expected_identity; end
    def wallet_propose(passphrase:); { "account_id" => "rRuntimeSigner", "secret" => +"runtime-secret" }; end
    def fund_account(account:, amount_drops:, root_secret:); { "hash" => "A" * 64 }; end
    def submit_recipe(recipe:, owner:, signer:); { "steps" => recipe.creation_steps.map { { "hash" => "A" * 64 } } }; end
    def validated_transaction(hash:); @finality; end
    def ledger_counts(ledger_index:, ledger_hash:); { "validated" => true, "network_id" => "candidate-task3", "ledger_index" => ledger_index, "ledger_hash" => ledger_hash, "classifier_version" => "owner-object-classifier-v1", "account_roots" => 0, "class_counts" => {}, "locked_xrp_drops" => 0, "released_xrp_drops" => 0 }; end
    def amendment_active?(amendment:); true; end
    def resource_snapshot; { "rss_bytes" => 1 }; end
  end

  def test_rejects_a_public_connection_before_any_adapter_operation
    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) do
      XrplReserveStudy::PrivateNetworkConnection.new(endpoint_uri: "https://example.test/", endpoint_sha256: "a" * 64, client_certificate_sha256: "b" * 64, network_id: "candidate-task3")
    end
    assert_equal "private network connection is invalid", error.message
  end

  def test_rejects_a_generic_transport_that_claims_to_be_isolated
    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { XrplReserveStudy::IsolatedTransactionClient.new(transport: Object.new) }
    assert_equal "private network transaction adapter is required", error.message
  end

  def test_rejects_a_subclass_attempt_and_a_mismatched_handshake
    assert_raises(TypeError) { Class.new(XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter) }
    connection = Connection.new
    connection.define_singleton_method(:handshake) { expected_identity.merge("network_id" => "candidate-relay") }
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { adapter_for(connection) }
  end

  def test_accepts_only_a_validated_successful_final_transaction_with_the_requested_hash
    client = client_for(Connection.new(finality: { "hash" => "B" * 64, "validated" => true, "engine_result" => "tesSUCCESS", "ledger_index" => 9, "ledger_hash" => "C" * 64, "network_id" => "candidate-task3", "fee_drops" => 12 }))
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.validated_transaction(hash: "A" * 64) }
  end

  def test_rejects_a_recipe_that_did_not_come_from_the_recipe_registry
    client = client_for(Connection.new)
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.submit_recipe(recipe: { "transaction_type" => "OfferCreate" }, owner: "rOwner", signer: Object.new) }
  end

  def test_does_not_expose_an_arbitrary_rpc_escape_hatch_or_mutable_identity
    connection = Connection.new
    client = client_for(connection)
    refute_respond_to client, :call
    refute client.instance_variable_get(:@identity).fetch("network_id").frozen? == false
  end

  private

  def adapter_for(connection)
    XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter.new(connection: connection)
  end

  def client_for(connection)
    XrplReserveStudy::IsolatedTransactionClient.new(transport: adapter_for(connection))
  end
end
