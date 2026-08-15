# frozen_string_literal: true

module XrplReserveStudy
  class IsolatedTransactionClientError < StudyError; end

  # Connection boundary: implementations must perform their own RPC I/O, but
  # the adapter only accepts a loopback endpoint after this handshake matches.
  class PrivateNetworkConnection
    def initialize(endpoint_uri:, endpoint_sha256:, client_certificate_sha256:, network_id:)
      @expected = { "endpoint_uri" => endpoint_uri, "endpoint_sha256" => endpoint_sha256,
                    "client_certificate_sha256" => client_certificate_sha256, "network_id" => network_id }
      validate_expected!
      @expected.each { |key, value| @expected[key] = value.dup.freeze }
      @expected.freeze
    end

    def expected_identity; @expected; end
    def handshake; raise NotImplementedError, "private connection must implement handshake"; end

    private

    def validate_expected!
      uri = @expected.fetch("endpoint_uri")
      private_uri = uri.is_a?(String) && uri.match?(%r{\Ahttps://(?:127\.0\.0\.1|\[::1\]|localhost)(?::\d+)?/\z})
      hashes = %w[endpoint_sha256 client_certificate_sha256].all? { |key| @expected[key].is_a?(String) && @expected[key].match?(/\A[a-f0-9]{64}\z/) }
      raise IsolatedTransactionClientError, "private network connection is invalid" unless private_uri && hashes && @expected["network_id"].is_a?(String) && @expected["network_id"].match?(/\Acandidate-[a-z0-9-]+\z/)
    end
  end

  # Final operation gateway. No subclass can replace its verification or
  # forward authorities to a separately selected relay.
  class PinnedPrivateNetworkTransactionAdapter
    def self.inherited(*)
      raise TypeError, "pinned private transaction adapter is final"
    end

    def initialize(connection:)
      raise IsolatedTransactionClientError, "private network connection is required" unless connection.is_a?(PrivateNetworkConnection)
      observed = connection.handshake
      expected = connection.expected_identity
      unless observed.is_a?(Hash) && observed.keys.sort == expected.keys.sort && observed == expected
        raise IsolatedTransactionClientError, "private network handshake did not match pinned identity"
      end
      @connection = connection
      @endpoint_identity = expected
      freeze
    end

    def isolated?; true; end
    def endpoint_identity; @endpoint_identity; end
    def wallet_propose(**args); @connection.wallet_propose(**args); end
    def fund_account(**args); @connection.fund_account(**args); end
    def submit_recipe(**args); @connection.submit_recipe(**args); end
    def validated_transaction(**args); @connection.validated_transaction(**args); end
    def ledger_counts(**args); @connection.ledger_counts(**args); end
    def amendment_active?(**args); @connection.amendment_active?(**args); end
    def resource_snapshot; @connection.resource_snapshot; end
  end

  # Restricts state construction to a small, explicit private-network protocol.
  class IsolatedTransactionClient < PrivateWalletProposeAdapter
    ALLOWED_METHODS = %i[
      isolated? wallet_propose fund_account submit_recipe validated_transaction
      ledger_counts amendment_active? resource_snapshot
    ].freeze

    def initialize(transport:)
      unless transport.is_a?(PinnedPrivateNetworkTransactionAdapter)
        raise IsolatedTransactionClientError, "private network transaction adapter is required"
      end
      required = ALLOWED_METHODS - [:isolated?]
      unless required.all? { |method| transport.respond_to?(method) }
        raise IsolatedTransactionClientError, "isolated transaction transport is invalid"
      end
      @transport = transport
      @identity = transport.endpoint_identity
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
      response = @transport.submit_recipe(recipe: recipe, owner: owner, signer: signer)
      steps = response.is_a?(Hash) ? response["steps"] : nil
      unless steps.is_a?(Array) && steps.length == recipe.creation_steps.length
        raise IsolatedTransactionClientError, "isolated recipe submission is invalid"
      end
      normalized = steps.map { |step| submitted_response!(step) }
      { "steps" => normalized }.freeze
    end

    def validated_transaction(hash:)
      ensure_isolated!
      hash = transaction_hash!(hash)
      response = @transport.validated_transaction(hash: hash)
      unless response.is_a?(Hash) && response["hash"] == hash && response["validated"] == true &&
             %w[tesSUCCESS success].include?(response["engine_result"] || response["result"]) &&
             response["ledger_index"].is_a?(Integer) && response["ledger_index"].positive? && transaction_hash?(response["ledger_hash"]) &&
             response["network_id"] == @identity.fetch("network_id") &&
             response["fee_drops"].is_a?(Integer) && response["fee_drops"] >= 0
        raise IsolatedTransactionClientError, "isolated transaction finality is invalid"
      end

      response.slice("hash", "validated", "engine_result", "result", "ledger_index", "ledger_hash", "network_id", "fee_drops").freeze
    end

    def ledger_counts(finality:)
      ensure_isolated!
      validate_finality_binding!(finality)
      response = @transport.ledger_counts(ledger_index: finality.fetch("ledger_index"), ledger_hash: finality.fetch("ledger_hash"))
      unless response.is_a?(Hash) && response["validated"] == true && response["network_id"] == @identity.fetch("network_id") &&
             response["ledger_index"] == finality.fetch("ledger_index") && response["ledger_hash"] == finality.fetch("ledger_hash") &&
             response["classifier_version"] == "owner-object-classifier-v1"
        raise IsolatedTransactionClientError, "isolated ledger counts are invalid"
      end

      response.slice("validated", "network_id", "ledger_index", "ledger_hash", "classifier_version", "account_roots", "class_counts", "locked_xrp_drops", "released_xrp_drops").freeze
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

    def validate_finality_binding!(value)
      unless value.is_a?(Hash) && value["validated"] == true && value["network_id"] == @identity.fetch("network_id") &&
             value["ledger_index"].is_a?(Integer) && value["ledger_index"].positive? && transaction_hash?(value["ledger_hash"])
        raise IsolatedTransactionClientError, "isolated ledger finality binding is invalid"
      end
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
