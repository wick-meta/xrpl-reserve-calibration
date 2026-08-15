# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"
require_relative "task3_loopback_mtls_rpc_server"

class IsolatedTransactionClientTest < Minitest::Test
  def setup
    @servers = []
    @connections = []
    @finality = { "hash" => "A" * 64, "validated" => true, "engine_result" => "tesSUCCESS",
                  "ledger_index" => 9, "ledger_hash" => "C" * 64,
                  "network_id" => "candidate-task3", "fee_drops" => 12,
                  "account" => "rRuntimeSigner", "account_balance_drops" => 1_000_000 }
  end

  def teardown
    @connections.each(&:close)
    @servers.each(&:stop)
  end

  def test_rejects_a_public_connection_before_any_adapter_operation
    server = rpc_server
    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) do
      XrplReserveStudy::PrivateNetworkConnection.new(**server.connection_options.merge(endpoint_uri: "https://example.test/"))
    end
    assert_equal "private network connection is invalid", error.message
  end

  def test_rejects_a_generic_transport_that_claims_to_be_isolated
    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { XrplReserveStudy::IsolatedTransactionClient.new(transport: Object.new) }
    assert_equal "private network transaction adapter is required", error.message
    assert_raises(TypeError) { Class.new(XrplReserveStudy::IsolatedTransactionClient) }
  end

  def test_rejects_a_public_relay_connection_subclass_that_echoes_the_expected_identity
    error = assert_raises(TypeError) do
      Class.new(XrplReserveStudy::PrivateNetworkConnection) do
        def endpoint_identity
          { "endpoint_uri" => "https://127.0.0.1:5005/", "endpoint_sha256" => "a" * 64,
            "client_certificate_sha256" => "b" * 64, "network_id" => "candidate-task3" }
        end

        def fund_account(**arguments)
          PublicRelay.call(**arguments)
        end
      end
    end
    assert_equal "private network connection is final", error.message
  end

  def test_rejects_an_adapter_subclass_and_a_live_handshake_with_the_wrong_candidate_identity
    assert_raises(TypeError) { Class.new(XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter) }
    server = rpc_server(network_id: "candidate-relay")
    options = server.connection_options.merge(network_id: "candidate-task3")
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { connection_for(options) }
  end

  def test_uses_one_live_loopback_mtls_channel_pinned_to_the_peer_and_client_certificates
    server = rpc_server
    client = client_for(connection_for(server.connection_options))

    response = client.fund_account(account: "rAccount", amount_drops: 1_000_000, root_secret: +"root-secret")

    assert_equal({ "hash" => "A" * 64 }, response)
    assert_equal %w[private_network_identity fund_account], server.calls.map { |call| call.fetch("method") }
    assert @connections.fetch(0).frozen?
    assert client.instance_variable_get(:@transport).frozen?
    assert client.frozen?
  end

  def test_rejects_a_peer_certificate_that_does_not_match_the_pinned_endpoint_digest
    server = rpc_server
    options = server.connection_options.merge(endpoint_sha256: "0" * 64)

    error = assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { connection_for(options) }

    assert_equal "private network TLS peer did not match pinned endpoint", error.message
  end

  def test_never_reconnects_authority_operations_after_the_verified_channel_closes
    server = Task3LoopbackMutualTlsRpcServer.new(close_after_identity: true) do |method, _params|
      method == "fund_account" ? { "hash" => "A" * 64 } : raise("unexpected RPC method")
    end
    @servers << server
    client = client_for(connection_for(server.connection_options))

    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) do
      client.fund_account(account: "rAccount", amount_drops: 1_000_000, root_secret: +"root-secret")
    end

    assert_equal ["private_network_identity"], server.calls.map { |call| call.fetch("method") }
  end

  def test_accepts_only_a_validated_successful_final_transaction_with_the_requested_hash
    @finality = @finality.merge("hash" => "B" * 64)
    client = client_for(connection_for(rpc_server.connection_options))
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.validated_transaction(hash: "A" * 64) }
  end

  def test_rejects_a_recipe_that_did_not_come_from_the_recipe_registry
    client = client_for(connection_for(rpc_server.connection_options))
    assert_raises(XrplReserveStudy::IsolatedTransactionClientError) { client.submit_recipe(recipe: { "transaction_type" => "OfferCreate" }, owner: "rOwner", signer: Object.new) }
  end

  def test_does_not_expose_an_arbitrary_rpc_escape_hatch_or_mutable_identity
    connection = connection_for(rpc_server.connection_options)
    client = client_for(connection)
    refute_respond_to client, :call
    refute client.instance_variable_get(:@identity).fetch("network_id").frozen? == false
  end

  private

  def rpc_server(network_id: "candidate-task3")
    server = Task3LoopbackMutualTlsRpcServer.new(network_id: network_id) do |method, params|
      case method
      when "wallet_propose" then { "account_id" => "rRuntimeSigner", "secret" => +"runtime-secret" }
      when "fund_account" then { "hash" => "A" * 64 }
      when "submit_recipe" then { "steps" => params.fetch("creation_steps").map { { "hash" => "A" * 64 } } }
      when "validated_transaction" then @finality
      when "ledger_counts"
        { "validated" => true, "network_id" => "candidate-task3", "ledger_index" => params.fetch("ledger_index"),
          "ledger_hash" => params.fetch("ledger_hash"), "classifier_version" => "owner-object-classifier-v1",
          "account_roots" => 0, "class_counts" => {}, "locked_xrp_drops" => 0, "released_xrp_drops" => 0 }
      when "amendment_active" then true
      when "resource_snapshot" then { "rss_bytes" => 1 }
      else raise "unexpected RPC method: #{method}"
      end
    end
    @servers << server
    server
  end

  def connection_for(options)
    connection = XrplReserveStudy::PrivateNetworkConnection.new(**options)
    @connections << connection
    connection
  end

  def adapter_for(connection)
    XrplReserveStudy::PinnedPrivateNetworkTransactionAdapter.new(connection: connection)
  end

  def client_for(connection)
    XrplReserveStudy::IsolatedTransactionClient.new(transport: adapter_for(connection))
  end
end
