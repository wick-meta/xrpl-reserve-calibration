# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require_relative "../lib/xrpl_reserve_study"

class DeterministicSignerPoolTest < Minitest::Test
  class CapturingWalletProposeAdapter < XrplReserveStudy::PrivateWalletProposeAdapter
    attr_reader :passphrases, :received_hmacs, :returned_secrets

    def initialize(response: nil)
      @response = response
      @passphrases = []
      @received_hmacs = []
      @returned_secrets = []
    end

    def wallet_propose(passphrase:)
      @passphrases << passphrase
      @received_hmacs << passphrase.dup
      response = @response || { "account_id" => "rDeterministicSigner", "secret" => +"ephemeral-returned-secret" }
      @returned_secrets << response["secret"] if response.is_a?(Hash) && response["secret"].is_a?(String)
      response
    end
  end

  def test_derives_the_expected_context_without_consuming_reader_owned_authority
    authority = +"runtime-authority"
    adapter = CapturingWalletProposeAdapter.new
    pool = XrplReserveStudy::SignerPool.new(
      profile_id: "complete-reserves-calibrated-v1",
      cell_id: "cell-001",
      authority_reader: -> { authority },
      wallet_propose_adapter: adapter
    )

    observed = pool.with_signer(role: "owner", ordinal: 7) do |signer|
      { account: signer.account, secret: signer.secret.dup, context: signer.context }
    end

    expected_context = ["complete-reserves-calibrated-v1", "cell-001", "owner", 7].join("\0")
    assert_equal "rDeterministicSigner", observed.fetch(:account)
    assert_equal "ephemeral-returned-secret", observed.fetch(:secret)
    assert_equal expected_context, observed.fetch(:context)
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "runtime-authority", expected_context), adapter.received_hmacs.fetch(0)
    assert_equal "runtime-authority", authority
    assert_empty adapter.passphrases.fetch(0)
    assert_empty adapter.returned_secrets.fetch(0)
  end

  def test_reuses_one_reader_authority_for_multiple_signers
    authority = +"runtime-authority"
    adapter = CapturingWalletProposeAdapter.new
    pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { authority }, wallet_propose_adapter: adapter
    )

    pool.with_signer(role: "owner", ordinal: 0) { |_signer| :first }
    pool.with_signer(role: "owner", ordinal: 1) { |_signer| :second }

    assert_equal "runtime-authority", authority
    assert_equal 2, adapter.received_hmacs.length
    assert_equal 2, pool.audit_records.length
    assert adapter.passphrases.all?(&:empty?)
    assert adapter.returned_secrets.all?(&:empty?)
  end

  def test_wipes_local_runtime_buffers_when_the_signer_block_raises
    authority = +"runtime-authority"
    adapter = CapturingWalletProposeAdapter.new
    pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { authority }, wallet_propose_adapter: adapter
    )

    assert_raises(RuntimeError) { pool.with_signer(role: "owner", ordinal: 0) { raise "boom" } }

    assert_equal "runtime-authority", authority
    assert_empty adapter.passphrases.fetch(0)
    assert_empty adapter.returned_secrets.fetch(0)
  end

  def test_rejects_invalid_wallet_response_and_wipes_derived_passphrase
    adapter = CapturingWalletProposeAdapter.new(response: { "account_id" => "rDeterministicSigner" })
    pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { +"runtime-authority" }, wallet_propose_adapter: adapter
    )

    error = assert_raises(XrplReserveStudy::SignerPoolError) { pool.with_signer(role: "owner", ordinal: 0) { |_signer| } }

    assert_equal "private wallet_propose response is invalid", error.message
    assert_empty adapter.passphrases.fetch(0)
  end

  def test_rejects_frozen_authority_and_returned_secret
    adapter = CapturingWalletProposeAdapter.new
    frozen_authority_pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { "frozen-authority".freeze }, wallet_propose_adapter: adapter
    )
    authority_error = assert_raises(XrplReserveStudy::SignerPoolError) { frozen_authority_pool.with_signer(role: "owner", ordinal: 0) { |_signer| } }

    frozen_secret_adapter = CapturingWalletProposeAdapter.new(response: { "account_id" => "rDeterministicSigner", "secret" => "frozen-secret".freeze })
    frozen_secret_pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { +"runtime-authority" }, wallet_propose_adapter: frozen_secret_adapter
    )
    secret_error = assert_raises(XrplReserveStudy::SignerPoolError) { frozen_secret_pool.with_signer(role: "owner", ordinal: 0) { |_signer| } }

    assert_equal "signing authority must be mutable", authority_error.message
    assert_equal "private wallet_propose secret must be mutable", secret_error.message
    assert_empty frozen_secret_adapter.passphrases.fetch(0)
  end

  def test_audit_records_include_only_context_and_a_public_account_hash
    adapter = CapturingWalletProposeAdapter.new
    pool = XrplReserveStudy::SignerPool.new(
      profile_id: "profile", cell_id: "cell", authority_reader: -> { +"authority" }, wallet_propose_adapter: adapter
    )

    pool.with_signer(role: "issuer", ordinal: 2) { |_signer| :used }
    record = pool.audit_records.fetch(0)

    assert_equal ["profile", "cell", "issuer", 2].join("\0"), record.fetch("context")
    assert_equal Digest::SHA256.hexdigest("rDeterministicSigner"), record.fetch("account_sha256")
    assert_equal %w[account_sha256 context], record.keys.sort
    refute_includes record.values.join, "authority"
    refute_includes record.values.join, "secret"
  end

  def test_rejects_an_unallowlisted_wallet_adapter_before_reading_authority
    read = false

    error = assert_raises(XrplReserveStudy::SignerPoolError) do
      XrplReserveStudy::SignerPool.new(
        profile_id: "profile", cell_id: "cell", authority_reader: -> { read = true; +"authority" },
        wallet_propose_adapter: Object.new
      )
    end

    assert_equal "wallet_propose adapter is not allowlisted", error.message
    refute read
  end
end
