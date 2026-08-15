# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "uri"

module XrplReserveStudy
  class ObservationError < StandardError; end

  class MainnetObserver
    FEE_SETTINGS_INDEX = "4BC50C9B0D8515D3EAAE1E74B29A95804346C491EE1A95BF25E4AAB854A6A651"
    MAX_RESPONSE_BYTES = 1_048_576
    ALLOWED_METHODS = %w[server_info ledger_entry].freeze
    RpcResponse = Struct.new(:parsed, :body, :sha256, keyword_init: true)

    attr_reader :endpoint

    def initialize(endpoint:, open_timeout: 5, read_timeout: 15)
      @uri = URI.parse(endpoint)
      raise ObservationError, "endpoint must use HTTPS" unless @uri.is_a?(URI::HTTPS)
      raise ObservationError, "endpoint must not include credentials" if @uri.user || @uri.password
      raise ObservationError, "endpoint must not include a query or fragment" if @uri.query || @uri.fragment

      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @endpoint = redacted_endpoint
    rescue URI::InvalidURIError => e
      raise ObservationError, "invalid endpoint: #{e.message}"
    end

    def preflight
      response = rpc("server_info")
      validated = response.parsed.dig("result", "info", "validated_ledger")
      raise ObservationError, "server_info omitted validated_ledger" unless validated.is_a?(Hash)

      {
        "endpoint" => endpoint,
        "latest_validated_ledger" => integer_value(validated["seq"], "validated ledger index"),
        "latest_validated_hash" => hash_value(validated["hash"], "validated ledger hash"),
        "validated_ledger_age_seconds" => integer_value(validated["age"], "validated ledger age"),
        "server_state" => response.parsed.dig("result", "info", "server_state"),
        "raw_response_sha256" => response.sha256,
        "raw_response" => response.body
      }
    end

    def capture_exact(ledger_index:)
      index = integer_value(ledger_index, "requested ledger index")
      response = rpc(
        "ledger_entry",
        [{ "index" => FEE_SETTINGS_INDEX, "ledger_index" => index }]
      )
      result = response.parsed["result"]
      node = result.is_a?(Hash) ? result["node"] : nil
      raise ObservationError, "ledger_entry omitted FeeSettings node" unless node.is_a?(Hash)

      returned_index = integer_value(result["ledger_index"], "returned ledger index")
      raise ObservationError, "endpoint returned a different ledger" unless returned_index == index

      {
        "schema_version" => "mainnet-baseline-v2",
        "observed_at" => Time.now.utc.iso8601(6),
        "endpoint" => endpoint,
        "ledger_index" => returned_index,
        "ledger_hash" => hash_value(result["ledger_hash"], "ledger hash"),
        "reserve_base_drops" => drops_value(node, "ReserveBaseDrops", "ReserveBase"),
        "reserve_increment_drops" => drops_value(node, "ReserveIncrementDrops", "ReserveIncrement"),
        "fee_settings_index" => FEE_SETTINGS_INDEX,
        "raw_response_sha256" => response.sha256,
        "raw_response" => response.body
      }
    end

    private

    def rpc(method, params = [{}])
      raise ObservationError, "RPC method is not allowed" unless ALLOWED_METHODS.include?(method)

      request = Net::HTTP::Post.new(@uri.request_uri.empty? ? "/" : @uri.request_uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "xrpl-reserve-calibration/0.2"
      request.body = JSON.generate("method" => method, "params" => params)

      response = nil
      response_body = +""
      Net::HTTP.start(
        @uri.host,
        @uri.port,
        use_ssl: true,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) do |http|
        http.request(request) do |received|
          response = received
          received.read_body do |chunk|
            if response_body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
              raise ObservationError, "RPC response exceeded size limit"
            end
            response_body << chunk
          end
        end
      end

      raise ObservationError, "RPC returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response_body)
      raise ObservationError, "RPC response root must be an object" unless parsed.is_a?(Hash)
      if parsed["error"] || parsed.dig("result", "error") || parsed.dig("result", "status") == "error"
        raise ObservationError, "RPC returned an error"
      end

      RpcResponse.new(
        parsed: parsed,
        body: response_body,
        sha256: Digest::SHA256.hexdigest(response_body)
      )
    rescue JSON::ParserError => e
      raise ObservationError, "RPC returned invalid JSON: #{e.message}"
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise ObservationError, "RPC request failed: #{e.class}: #{e.message}"
    end

    def drops_value(node, current_key, legacy_key)
      value = node[current_key] || node[legacy_key]
      parsed = Integer(value)
      raise ObservationError, "FeeSettings field #{current_key} must not be negative" if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      raise ObservationError, "FeeSettings field #{current_key} was not integer drops"
    end

    def integer_value(value, label)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ObservationError, "#{label} was not an integer"
    end

    def hash_value(value, label)
      text = String(value)
      raise ObservationError, "#{label} was malformed" unless text.match?(/\A[A-Fa-f0-9]{64}\z/)

      text.upcase
    end

    def redacted_endpoint
      port = @uri.default_port == @uri.port ? nil : @uri.port
      URI::HTTPS.build(host: @uri.host, port: port, path: @uri.path).to_s
    end
  end
end
