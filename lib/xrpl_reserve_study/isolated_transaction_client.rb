# frozen_string_literal: true

require "digest"
require "ipaddr"
require "json"
require "net/http"
require "openssl"
require "uri"

module XrplReserveStudy
  class IsolatedTransactionClientError < StudyError; end

  # Concrete, final connection boundary. It owns one loopback mTLS channel and
  # performs every authority-bearing RPC on the channel it verified at start.
  class PrivateNetworkConnection
    MAX_RESPONSE_BYTES = 1_048_576

    class PinnedPersistentHttp < Net::HTTP
      private

      def begin_transport(request)
        unavailable = @socket.nil? || @socket.closed?
        if @last_communicated
          unavailable ||= @last_communicated + @keep_alive_timeout < Process.clock_gettime(Process::CLOCK_MONOTONIC)
          unavailable ||= @socket.io.to_io.wait_readable(0) && @socket.eof? unless unavailable
        end
        raise IOError, "verified private network channel is closed" if unavailable

        request.update_uri(address, port, use_ssl?)
        request["host"] ||= addr_port
      end
    end
    private_constant :PinnedPersistentHttp

    def self.inherited(*)
      raise TypeError, "private network connection is final"
    end

    def initialize(endpoint_uri:, endpoint_sha256:, client_certificate_sha256:, network_id:,
                   client_certificate:, client_key:, ca_certificate:,
                   open_timeout: 5, read_timeout: 30)
      @uri = validated_uri(endpoint_uri)
      validate_hash!(endpoint_sha256)
      validate_hash!(client_certificate_sha256)
      validate_network_id!(network_id)
      validate_credentials!(client_certificate, client_key, ca_certificate)
      unless Digest::SHA256.hexdigest(client_certificate.to_der) == client_certificate_sha256
        raise IsolatedTransactionClientError, "private network client certificate did not match pinned identity"
      end

      @lock = Mutex.new
      @http = build_http(client_certificate, client_key, ca_certificate, open_timeout, read_timeout)
      @http.start
      verify_peer!(endpoint_sha256)
      observed = rpc("private_network_identity", {})
      unless observed.is_a?(Hash) && observed.keys.sort == %w[client_certificate_sha256 network_id] &&
             observed["network_id"] == network_id &&
             observed["client_certificate_sha256"] == client_certificate_sha256
        raise IsolatedTransactionClientError, "private network live identity did not match pinned identity"
      end

      @endpoint_identity = {
        "endpoint_uri" => endpoint_uri.dup.freeze,
        "endpoint_sha256" => endpoint_sha256.dup.freeze,
        "client_certificate_sha256" => client_certificate_sha256.dup.freeze,
        "network_id" => network_id.dup.freeze
      }.freeze
      freeze
    rescue IsolatedTransactionClientError
      close
      raise
    rescue JSON::ParserError, OpenSSL::SSL::SSLError, SocketError, SystemCallError,
           IOError, Timeout::Error, URI::InvalidURIError => error
      close
      raise IsolatedTransactionClientError, "private network TLS connection failed: #{error.class}"
    end

    def endpoint_identity
      @endpoint_identity
    end

    def wallet_propose(passphrase:)
      rpc("wallet_propose", "passphrase" => passphrase)
    end

    def fund_account(account:, amount_drops:, root_secret:)
      rpc("fund_account", "account" => account, "amount_drops" => amount_drops, "root_secret" => root_secret)
    end

    def submit_recipe(recipe:, owner:, signer:, max_fee_drops_per_step:, reserve_floor_drops:)
      rpc(
        "submit_recipe",
        "recipe_kind" => recipe.kind,
        "creation_steps" => recipe.creation_steps,
        "owner" => owner,
        "signer_secret" => signer.secret,
        "max_fee_drops_per_step" => max_fee_drops_per_step,
        "reserve_floor_drops" => reserve_floor_drops
      )
    end

    def validated_transaction(hash:)
      rpc("validated_transaction", "hash" => hash)
    end

    def ledger_counts(ledger_index:, ledger_hash:)
      rpc("ledger_counts", "ledger_index" => ledger_index, "ledger_hash" => ledger_hash)
    end

    def amendment_active?(amendment:)
      rpc("amendment_active", "amendment" => amendment) == true
    end

    def resource_snapshot
      rpc("resource_snapshot", {})
    end

    def close
      return unless defined?(@http) && @http

      @lock ? @lock.synchronize { @http.finish if @http.started? } : @http.finish
    rescue IOError
      nil
    end

    private

    def validated_uri(value)
      uri = URI.parse(value)
      host = uri.host.to_s.delete_prefix("[").delete_suffix("]")
      address = IPAddr.new(host)
      valid = value.is_a?(String) && uri.is_a?(URI::HTTPS) && address.loopback? &&
              uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path == "/"
      raise IsolatedTransactionClientError, "private network connection is invalid" unless valid

      uri
    rescue IPAddr::InvalidAddressError, URI::InvalidURIError, TypeError
      raise IsolatedTransactionClientError, "private network connection is invalid"
    end

    def validate_hash!(value)
      raise IsolatedTransactionClientError, "private network connection is invalid" unless value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
    end

    def validate_network_id!(value)
      raise IsolatedTransactionClientError, "private network connection is invalid" unless value.is_a?(String) && value.match?(/\Acandidate-[a-z0-9-]+\z/)
    end

    def validate_credentials!(certificate, key, ca_certificate)
      valid = certificate.is_a?(OpenSSL::X509::Certificate) &&
              key.is_a?(OpenSSL::PKey::PKey) && certificate.check_private_key(key) &&
              ca_certificate.is_a?(OpenSSL::X509::Certificate)
      raise IsolatedTransactionClientError, "private network mTLS credentials are invalid" unless valid
    end

    def build_http(certificate, key, ca_certificate, open_timeout, read_timeout)
      raise IsolatedTransactionClientError, "private network timeout is invalid" unless positive_number?(open_timeout) && positive_number?(read_timeout)

      store = OpenSSL::X509::Store.new
      store.add_cert(ca_certificate)
      http = PinnedPersistentHttp.new(@uri.host, @uri.port, nil)
      http.use_ssl = true
      http.cert = certificate
      http.key = key
      http.cert_store = store
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.max_retries = 0
      http
    end

    def verify_peer!(expected_sha256)
      peer = @http.peer_cert
      unless peer.is_a?(OpenSSL::X509::Certificate) && Digest::SHA256.hexdigest(peer.to_der) == expected_sha256
        raise IsolatedTransactionClientError, "private network TLS peer did not match pinned endpoint"
      end
    end

    def rpc(method, params)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Connection"] = "keep-alive"
      body = JSON.generate("method" => method, "params" => params)
      request.body = body
      response = @lock.synchronize { @http.request(request) }
      unless response.is_a?(Net::HTTPSuccess) && response.body.is_a?(String) && response.body.bytesize <= MAX_RESPONSE_BYTES
        raise IsolatedTransactionClientError, "private network RPC response is invalid"
      end
      parsed = JSON.parse(response.body)
      unless parsed.is_a?(Hash) && !parsed.key?("error") && parsed.keys == ["result"]
        raise IsolatedTransactionClientError, "private network RPC returned an error"
      end

      parsed.fetch("result")
    rescue IsolatedTransactionClientError
      raise
    rescue JSON::ParserError, OpenSSL::SSL::SSLError, SocketError, SystemCallError,
           IOError, Timeout::Error => error
      raise IsolatedTransactionClientError, "private network verified channel failed: #{error.class}"
    ensure
      wipe!(body)
    end

    def positive_number?(value)
      value.is_a?(Integer) ? value.positive? : value.is_a?(Float) && value.finite? && value.positive?
    end

    def wipe!(value)
      return unless value.is_a?(String) && !value.frozen?

      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end
  end

  # Final operation gateway. No subclass can replace its verification or
  # forward authorities to a separately selected relay.
  class PinnedPrivateNetworkTransactionAdapter
    def self.inherited(*)
      raise TypeError, "pinned private transaction adapter is final"
    end

    def initialize(connection:)
      unless connection.instance_of?(PrivateNetworkConnection) && connection.frozen?
        raise IsolatedTransactionClientError, "verified private network connection is required"
      end
      @connection = connection
      @endpoint_identity = connection.endpoint_identity
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

    def self.inherited(*)
      raise TypeError, "isolated transaction client is final"
    end

    def initialize(transport:)
      unless transport.instance_of?(PinnedPrivateNetworkTransactionAdapter) && transport.frozen?
        raise IsolatedTransactionClientError, "private network transaction adapter is required"
      end
      required = ALLOWED_METHODS - [:isolated?]
      unless required.all? { |method| transport.respond_to?(method) }
        raise IsolatedTransactionClientError, "isolated transaction transport is invalid"
      end
      @transport = transport
      @identity = transport.endpoint_identity
      freeze
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

    def submit_recipe(recipe:, owner:, signer:, max_fee_drops_per_step: nil, reserve_floor_drops: nil)
      ensure_isolated!
      unless recipe.is_a?(OwnerObjectRecipeRegistry::Recipe)
        raise IsolatedTransactionClientError, "owner object recipe is not allowlisted"
      end
      validate_account!(owner)
      unless signer.respond_to?(:account) && signer.respond_to?(:secret) && signer.account == owner
        raise IsolatedTransactionClientError, "runtime signer does not match owner"
      end
      require_secret!(signer.secret)
      unless max_fee_drops_per_step.is_a?(Integer) && max_fee_drops_per_step.positive? &&
             reserve_floor_drops.is_a?(Integer) && reserve_floor_drops.positive?
        raise IsolatedTransactionClientError, "recipe fee and reserve limits are invalid"
      end
      response = @transport.submit_recipe(
        recipe: recipe, owner: owner, signer: signer,
        max_fee_drops_per_step: max_fee_drops_per_step, reserve_floor_drops: reserve_floor_drops
      )
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
             response["fee_drops"].is_a?(Integer) && response["fee_drops"] >= 0 &&
             valid_account?(response["account"]) &&
             response["account_balance_drops"].is_a?(Integer) && response["account_balance_drops"] >= 0
        raise IsolatedTransactionClientError, "isolated transaction finality is invalid"
      end

      response.slice("hash", "validated", "engine_result", "result", "ledger_index", "ledger_hash", "network_id", "fee_drops", "account", "account_balance_drops").freeze
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
