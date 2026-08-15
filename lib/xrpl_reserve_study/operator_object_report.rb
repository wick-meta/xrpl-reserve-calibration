# frozen_string_literal: true

require "ipaddr"
require "json"
require "uri"

module XrplReserveStudy
  # A locally generated aggregate. It intentionally contains provenance digests,
  # not a query, raw result, endpoint, credential, or infrastructure identity.
  class OperatorObjectReport
    MAX_BYTES = 256 * 1024
    DATASET_TYPES = %w[clio rippled operator_database].freeze
    REQUIRED_KEYS = %w[
      schema_version operator_id dataset_type ledger_index ledger_hash query_sha256
      result_sha256 classifier_version account_roots class_counts
    ].freeze
    OPTIONAL_KEYS = %w[operator_evidence_url].freeze

    def self.load(path)
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      raise OwnerObjectDistributionError, "operator report must be a regular file" unless stat.file?
      raise OwnerObjectDistributionError, "operator report exceeds size limit" if stat.size > MAX_BYTES

      record = JSON.parse(File.binread(expanded))
      new(record)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise OwnerObjectDistributionError, "invalid operator report: #{e.message}"
    end

    def initialize(record)
      validate!(record)
      @record = OwnerObjectDistribution.deep_freeze(record)
      freeze
    end

    def fetch(key)
      @record.fetch(key)
    end

    def to_h
      @record
    end

    private

    def validate!(record)
      error!("must be an object") unless record.is_a?(Hash)
      error!("keys are invalid") unless (record.keys - REQUIRED_KEYS - OPTIONAL_KEYS).empty? && (REQUIRED_KEYS - record.keys).empty?
      error!("schema version is invalid") unless record["schema_version"] == "operator-owner-object-report-v1"
      error!("operator id is invalid") unless safe_identifier?(record["operator_id"])
      error!("dataset type is invalid") unless DATASET_TYPES.include?(record["dataset_type"])
      error!("ledger index is invalid") unless record["ledger_index"].is_a?(Integer) && record["ledger_index"].positive?
      error!("ledger hash is invalid") unless record["ledger_hash"].is_a?(String) && record["ledger_hash"].match?(/\A[A-F0-9]{64}\z/)
      %w[query_sha256 result_sha256].each do |key|
        error!("#{key} is invalid") unless record[key].is_a?(String) && record[key].match?(/\A[a-f0-9]{64}\z/)
      end
      error!("classifier version is invalid") unless record["classifier_version"] == "owner-object-classifier-v1"
      error!("account roots are invalid") unless record["account_roots"].is_a?(Integer) && record["account_roots"].positive?
      validate_class_counts!(record["class_counts"])
      validate_evidence_url!(record["operator_evidence_url"]) if record.key?("operator_evidence_url")
      error!("contains sensitive content") if contains_sensitive_content?(record)
    end

    def validate_class_counts!(counts)
      error!("class counts are invalid") unless counts.is_a?(Hash) && counts.all? do |name, count|
        OwnerObjectDistribution::CLASSIFIERS.value?(name) && count.is_a?(Integer) && count >= 0
      end
    end

    def validate_evidence_url!(value)
      error!("operator evidence URL is invalid") unless value.is_a?(String)
      uri = URI.parse(value)
      error!("operator evidence URL is invalid") unless uri.is_a?(URI::HTTPS) && uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil? && public_host?(uri.host)
    rescue URI::InvalidURIError
      error!("operator evidence URL is invalid")
    end

    def public_host?(host)
      return false unless host.is_a?(String) && !host.empty? && host != "localhost" && !host.end_with?(".local")

      address = IPAddr.new(host)
      !(address.private? || address.loopback? || address.link_local?)
    rescue IPAddr::InvalidAddressError
      true
    end

    def safe_identifier?(value)
      value.is_a?(String) && value.match?(/\A[a-z0-9][a-z0-9._-]{0,63}\z/) && !sensitive?(value)
    end

    def contains_sensitive_content?(value)
      case value
      when Hash then value.any? { |key, nested| sensitive?(key) || contains_sensitive_content?(nested) }
      when Array then value.any? { |nested| contains_sensitive_content?(nested) }
      when String then sensitive?(value)
      else false
      end
    end

    def sensitive?(value)
      value.to_s.match?(/(?:seed|secret|private[ _-]?key|api[ _-]?key|password|authorization|bearer|sEd[1-9A-HJ-NP-Za-km-z]+)/i)
    end

    def error!(message)
      raise OwnerObjectDistributionError, "operator report #{message}"
    end
  end
end
