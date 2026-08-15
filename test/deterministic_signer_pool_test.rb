# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require_relative "../lib/xrpl_reserve_study"

class DeterministicSignerPoolTest < Minitest::Test
  class CapturingWalletProposeAdapter < XrplReserveStudy::PrivateWalletProposeAdapter
    attr_reader :passphrase, :received_hmac, :returned_secret

    def wallet_propose(passphrase:)
      @passphrase = passphrase
      @received_hmac = passphrase.dup
      @returned_secret = +"ephemeral-returned-secret"
      { "account_id" => "rDeterministicSigner", "secret" => @returned_secret }
    end
  end

  def test_derives_the_expected_context_and_erases_runtime_secrets_after_yield
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
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "runtime-authority", expected_context), adapter.received_hmac
    assert_empty authority
    assert_empty adapter.passphrase
    assert_empty adapter.returned_secret
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
