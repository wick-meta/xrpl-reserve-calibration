# frozen_string_literal: true

require "digest"
require "openssl"

module XrplReserveStudy
  class SignerPoolError < StudyError; end

  # Boundary type for the sole runtime-capable wallet generation operation.
  # Concrete adapters may only expose a private-network wallet_propose call.
  class PrivateWalletProposeAdapter
    def wallet_propose(passphrase:)
      raise NotImplementedError, "private wallet_propose adapter must implement wallet_propose"
    end
  end

  class SignerPool
    Signer = Struct.new(:account, :secret, :context, keyword_init: true)

    def initialize(profile_id:, cell_id:, authority_reader:, wallet_propose_adapter:, audit_sink: nil)
      raise SignerPoolError, "wallet_propose adapter is not allowlisted" unless wallet_propose_adapter.is_a?(PrivateWalletProposeAdapter)
      raise SignerPoolError, "authority reader is invalid" unless authority_reader.respond_to?(:call)

      @profile_id = required_text(profile_id, "profile_id")
      @cell_id = required_text(cell_id, "cell_id")
      @authority_reader = authority_reader
      @wallet_propose_adapter = wallet_propose_adapter
      @audit_sink = audit_sink
      @audit_records = []
    end

    def with_signer(role:, ordinal:)
      raise SignerPoolError, "block is required" unless block_given?

      context = signer_context(role, ordinal)
      authority = @authority_reader.call
      raise SignerPoolError, "missing signing authority" unless authority.is_a?(String) && !authority.empty?

      passphrase = OpenSSL::HMAC.hexdigest("SHA256", authority, context)
      response = @wallet_propose_adapter.wallet_propose(passphrase: passphrase)
      account = response.is_a?(Hash) ? response["account_id"] : nil
      secret = response.is_a?(Hash) ? response["secret"] : nil
      unless account.is_a?(String) && !account.empty? && secret.is_a?(String) && !secret.empty?
        raise SignerPoolError, "private wallet_propose response is invalid"
      end

      record_audit(context, account)
      yield Signer.new(account: account, secret: secret, context: context)
    ensure
      wipe!(authority)
      wipe!(passphrase)
      wipe!(secret)
    end

    def audit_records
      @audit_records.map(&:dup).freeze
    end

    private

    def signer_context(role, ordinal)
      role = required_text(role, "role")
      raise SignerPoolError, "ordinal is invalid" unless ordinal.is_a?(Integer) && ordinal >= 0

      [@profile_id, @cell_id, role, ordinal].join("\0")
    end

    def required_text(value, name)
      raise SignerPoolError, "#{name} is invalid" unless value.is_a?(String) && !value.empty?

      value.dup.freeze
    end

    def record_audit(context, account)
      record = { "context" => context, "account_sha256" => Digest::SHA256.hexdigest(account) }.freeze
      @audit_records << record
      @audit_sink.call(record) if @audit_sink
    end

    def wipe!(value)
      return unless value.is_a?(String) && !value.frozen?

      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end
  end

  DeterministicSignerPool = SignerPool
end
