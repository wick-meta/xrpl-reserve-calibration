# frozen_string_literal: true

module XrplReserveStudy
  class IsolatedTransactionClientError < StudyError; end

  # Restricts state construction to a small, explicit private-network protocol.
  class IsolatedTransactionClient < PrivateWalletProposeAdapter
    ALLOWED_METHODS = %i[
      isolated? wallet_propose fund_account submit_recipe validated_transaction
      ledger_counts amendment_active? resource_snapshot
    ].freeze

    def initialize(transport:)
      required = ALLOWED_METHODS - [:isolated?]
      unless transport && transport.respond_to?(:isolated?) && required.all? { |method| transport.respond_to?(method) }
        raise IsolatedTransactionClientError, "isolated transaction transport is invalid"
      end

      @transport = transport
    end

    def isolated?
      @transport.isolated? == true
    end

    def wallet_propose(passphrase:)
      ensure_isolated!
      response = @transport.wallet_propose(passphrase: passphrase)
      valid_wallet_response!(response)
    end

    def fund_account(account:, amount_drops:, root_secret:)
      ensure_isolated!
      validate_account!(account)
      raise IsolatedTransactionClientError, "funding amount is invalid" unless amount_drops.is_a?(Integer) && amount_drops.positive?
      require_secret!(root_secret)
      submitted_response!(@transport.fund_account(account: account, amount_drops: amount_drops, root_secret: root_secret))
    end

    def submit_recipe(recipe:, owner:, signer:)
      ensure_isolated!
      unless recipe.is_a?(OwnerObjectRecipeRegistry::Recipe)
        raise IsolatedTransactionClientError, "owner object recipe is not allowlisted"
      end
      validate_account!(owner)
      unless signer.respond_to?(:account) && signer.respond_to?(:secret) && signer.account == owner
        raise IsolatedTransactionClientError, "runtime signer does not match owner"
      end
      require_secret!(signer.secret)
      submitted_response!(@transport.submit_recipe(recipe: recipe, owner: owner, signer: signer))
    end

    def validated_transaction(hash:)
      ensure_isolated!
      hash = transaction_hash!(hash)
      response = @transport.validated_transaction(hash: hash)
      unless response.is_a?(Hash) && response["hash"] == hash && response["validated"] == true &&
             %w[tesSUCCESS success].include?(response["engine_result"] || response["result"]) &&
             response["ledger_index"].is_a?(Integer) && response["ledger_index"].positive? &&
             response["fee_drops"].is_a?(Integer) && response["fee_drops"] >= 0
        raise IsolatedTransactionClientError, "isolated transaction finality is invalid"
      end

      response.slice("hash", "validated", "engine_result", "result", "ledger_index", "fee_drops").freeze
    end

    def ledger_counts
      ensure_isolated!
      response = @transport.ledger_counts
      raise IsolatedTransactionClientError, "isolated ledger counts are invalid" unless response.is_a?(Hash)

      response
    end

    def amendment_active?(amendment:)
      ensure_isolated!
      raise IsolatedTransactionClientError, "amendment identifier is invalid" unless amendment.is_a?(String) && !amendment.empty?

      @transport.amendment_active?(amendment: amendment) == true
    end

    def resource_snapshot
      ensure_isolated!
      response = @transport.resource_snapshot
      raise IsolatedTransactionClientError, "isolated resource snapshot is invalid" unless response.is_a?(Hash)

      response
    end

    private

    def ensure_isolated!
      raise IsolatedTransactionClientError, "isolated transaction client requires an isolated endpoint" unless isolated?
    end

    def valid_wallet_response!(response)
      unless response.is_a?(Hash) && valid_account?(response["account_id"]) && response["secret"].is_a?(String) && !response["secret"].empty? && !response["secret"].frozen?
        raise IsolatedTransactionClientError, "private wallet proposal is invalid"
      end

      response.slice("account_id", "secret")
    end

    def submitted_response!(response)
      raise IsolatedTransactionClientError, "isolated transaction submission is invalid" unless response.is_a?(Hash) && transaction_hash?(response["hash"])

      { "hash" => response.fetch("hash") }.freeze
    end

    def validate_account!(value)
      raise IsolatedTransactionClientError, "account is invalid" unless valid_account?(value)
    end

    def valid_account?(value)
      value.is_a?(String) && !value.empty?
    end

    def require_secret!(value)
      raise IsolatedTransactionClientError, "runtime signing authority is invalid" unless value.is_a?(String) && !value.empty?
    end

    def transaction_hash!(value)
      raise IsolatedTransactionClientError, "transaction hash is invalid" unless transaction_hash?(value)

      value
    end

    def transaction_hash?(value)
      value.is_a?(String) && value.match?(/\A[A-F0-9]{64}\z/)
    end
  end
end
