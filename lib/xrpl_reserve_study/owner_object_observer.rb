# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module XrplReserveStudy
  class OwnerObjectDistributionError < ObservationError; end

  # Reads only one explicitly pinned validated ledger. It never exposes a general
  # RPC entry point: ledger_data is the sole state-tree method permitted here.
  class OwnerObjectObserver
    MAX_RESPONSE_BYTES = 4 * 1_048_576
    MAX_PAGES = 100_000
    PAGE_LIMIT = 256
    PROGRESS_EVERY_PAGES = 100
    ALLOWED_METHODS = %w[server_info ledger_data].freeze
    RpcResponse = Struct.new(:parsed, :body, :sha256, keyword_init: true)

    attr_reader :endpoint

    def initialize(endpoint:, open_timeout: 5, read_timeout: 30)
      @uri = URI.parse(endpoint)
      raise OwnerObjectDistributionError, "endpoint must use HTTPS" unless @uri.is_a?(URI::HTTPS)
      raise OwnerObjectDistributionError, "endpoint must not include credentials" if @uri.user || @uri.password
      raise OwnerObjectDistributionError, "endpoint must not include a query or fragment" if @uri.query || @uri.fragment

      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @endpoint = redacted_endpoint
    rescue URI::InvalidURIError => e
      raise OwnerObjectDistributionError, "invalid endpoint: #{e.message}"
    end

    def preflight
      response = rpc("server_info")
      validated = response.parsed.dig("result", "info", "validated_ledger")
      raise OwnerObjectDistributionError, "server_info omitted validated_ledger" unless validated.is_a?(Hash)

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
      marker = nil
      pages = []
      entries = []
      expected_hash = nil
      loop do
        raise OwnerObjectDistributionError, "ledger_data pagination exceeded limit" if pages.length >= MAX_PAGES
        params = { "ledger_index" => index, "limit" => PAGE_LIMIT, "binary" => false }
        params["marker"] = marker if marker
        response = rpc("ledger_data", [params])
        result = response.parsed["result"]
        raise OwnerObjectDistributionError, "ledger_data result must be an object" unless result.is_a?(Hash)
        returned_index = integer_value(result["ledger_index"], "returned ledger index")
        raise OwnerObjectDistributionError, "endpoint returned a different ledger" unless returned_index == index
        ledger_hash = hash_value(result["ledger_hash"], "ledger hash")
        expected_hash ||= ledger_hash
        raise OwnerObjectDistributionError, "ledger hash changed during pagination" unless ledger_hash == expected_hash
        state = result["state"]
        raise OwnerObjectDistributionError, "ledger_data state must be an array" unless state.is_a?(Array)
        entries.concat(state)
        pages << response.sha256
        if (pages.length % PROGRESS_EVERY_PAGES).zero?
          $stderr.puts("owner-object-distribution endpoint=#{endpoint} pages=#{pages.length} entries=#{entries.length} ledger=#{index}")
        end
        marker = result["marker"]
        break unless marker
      end

      canonical = JSON.generate("page_sha256" => pages, "ledger_hash" => expected_hash, "ledger_index" => index)
      {
        "endpoint" => endpoint, "ledger_index" => index, "ledger_hash" => expected_hash,
        "entries" => entries, "page_sha256" => pages,
        "raw_response_sha256" => Digest::SHA256.hexdigest(canonical), "raw_response" => canonical
      }
    end

    private

    def rpc(method, params = [{}])
      raise OwnerObjectDistributionError, "RPC method is not allowed" unless ALLOWED_METHODS.include?(method)
      request = Net::HTTP::Post.new(@uri.request_uri.empty? ? "/" : @uri.request_uri)
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "xrpl-reserve-calibration/0.3"
      request.body = JSON.generate("method" => method, "params" => params)
      response = nil
      body = +""
      Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(request) do |received|
          response = received
          received.read_body do |chunk|
            raise OwnerObjectDistributionError, "RPC response exceeded size limit" if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            body << chunk
          end
        end
      end
      raise OwnerObjectDistributionError, "RPC returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      parsed = JSON.parse(body)
      raise OwnerObjectDistributionError, "RPC response root must be an object" unless parsed.is_a?(Hash)
      if parsed["error"] || parsed.dig("result", "error") || parsed.dig("result", "status") == "error"
        raise OwnerObjectDistributionError, "RPC returned an error"
      end
      RpcResponse.new(parsed: parsed, body: body, sha256: Digest::SHA256.hexdigest(body))
    rescue JSON::ParserError => e
      raise OwnerObjectDistributionError, "RPC returned invalid JSON: #{e.message}"
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise OwnerObjectDistributionError, "RPC request failed: #{e.class}: #{e.message}"
    end

    def integer_value(value, label)
      Integer(value)
    rescue ArgumentError, TypeError
      raise OwnerObjectDistributionError, "#{label} was not an integer"
    end

    def hash_value(value, label)
      text = String(value)
      raise OwnerObjectDistributionError, "#{label} was malformed" unless text.match?(/\A[A-Fa-f0-9]{64}\z/)
      text.upcase
    end

    def redacted_endpoint
      port = @uri.default_port == @uri.port ? nil : @uri.port
      URI::HTTPS.build(host: @uri.host, port: port, path: @uri.path).to_s
    end
  end
end
