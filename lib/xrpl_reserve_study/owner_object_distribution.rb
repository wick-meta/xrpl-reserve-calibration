# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "uri"
require "yaml"

module XrplReserveStudy
  class OwnerObjectDistribution
    CLASSIFIERS = {
      "Check" => "check", "DepositPreauth" => "deposit_preauthorization",
      "Escrow" => "escrow", "NFTokenOffer" => "nftoken_offer", "NFTokenPage" => "nftoken_page",
      "Offer" => "offer", "Oracle" => "oracle", "PayChannel" => "payment_channel",
      "SignerList" => "signer_list", "Ticket" => "ticket", "RippleState" => "trust_line",
      "AMM" => "amm", "Credential" => "credential", "DID" => "did",
      "MPToken" => "mptoken", "MPTIssuance" => "mpt_issuance",
      "PermissionedDomain" => "permissioned_domain", "Delegate" => "delegate",
      "XChainOwnedClaimID" => "xchain_owned_claim_id",
      "XChainOwnedCreateAccountClaimID" => "xchain_owned_create_account_claim_id"
    }.freeze
    IGNORED_TYPES = %w[Amendments DirectoryNode FeeSettings LedgerHashes NegativeUNL Bridge].freeze

    def initialize(manifest_path:, observer_factory: nil)
      @manifest_path = File.expand_path(manifest_path)
      @manifest = YAML.safe_load(File.read(@manifest_path), permitted_classes: [], aliases: false)
      @observer_factory = observer_factory || ->(endpoint) { OwnerObjectObserver.new(endpoint: endpoint) }
      validate_manifest!
    rescue Psych::Exception => e
      raise OwnerObjectDistributionError, "invalid endpoint manifest: #{e.message}"
    end

    def capture(output_dir:, source_commit:)
      validate_commit!(source_commit)
      destination = File.expand_path(output_dir)
      raise OwnerObjectDistributionError, "output directory already exists" if File.exist?(destination)
      staging = "#{destination}.tmp-#{Process.pid}"
      raise OwnerObjectDistributionError, "temporary output directory already exists" if File.exist?(staging)

      observations = @manifest.fetch("endpoints").map do |entry|
        observer = @observer_factory.call(entry.fetch("url"))
        [entry, observer, observer.preflight]
      end
      target_index = observations.map { |(_, _, preflight)| preflight.fetch("latest_validated_ledger") }.min
      enforce_preflight!(observations)
      FileUtils.mkdir_p(File.join(staging, "raw"))
      normalized = observations.map do |entry, observer, preflight|
        endpoint_id = entry.fetch("endpoint_id")
        File.binwrite(File.join(staging, "raw", "#{endpoint_id}-server-info.json"), preflight.fetch("raw_response"))
        observation = observer.capture_exact(ledger_index: target_index)
        File.binwrite(File.join(staging, "raw", "#{endpoint_id}-ledger-data.json"), observation.fetch("raw_response"))
        normalize_observation(entry, preflight, observation, target_index)
      end
      agreement = normalized.map { |row| row.values_at("ledger_index", "ledger_hash", "account_roots", "class_counts") }.uniq
      raise OwnerObjectDistributionError, "declared operators disagreed on the frozen ledger distribution" unless agreement.one?
      evidence_tier = normalized.length == 1 ? "operator_local" : "independently_corroborated"

      bundle = {
        "schema_version" => "owner-object-distribution-bundle-v1",
        "status" => normalized.length == 1 ? "captured" : "agreed",
        "evidence_tier" => evidence_tier, "source_commit" => source_commit,
        "captured_at" => Time.now.utc.iso8601(6),
        "selection_rule" => @manifest.fetch("selection_rule"), "target_ledger_index" => target_index,
        "ledger_hash" => normalized.first.fetch("ledger_hash"),
        "account_roots" => normalized.first.fetch("account_roots"),
        "class_counts" => normalized.first.fetch("class_counts"),
        "observations" => normalized.map { |row| row.reject { |key, _| key == "entries" } },
        "class_allocation_tie_break" => "ascending-class-name"
      }
      File.write(File.join(staging, "owner-object-distribution.json"), JSON.pretty_generate(bundle) + "\n")
      FileUtils.mv(staging, destination)
      self.class.deep_freeze(bundle)
    rescue OwnerObjectDistributionError
      FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      raise
    end

    def load(path)
      record = JSON.parse(File.binread(File.join(File.expand_path(path), "owner-object-distribution.json")))
      validate_bundle!(record)
      LoadedDistribution.new(record)
    rescue Errno::ENOENT, JSON::ParserError => e
      raise OwnerObjectDistributionError, "invalid distribution bundle: #{e.message}"
    end

    class LoadedDistribution
      def initialize(record)
        @record = OwnerObjectDistribution.deep_freeze(record)
        freeze
      end

      def population_targets(scale:)
        multiplier = numeric_scale(scale)
        {
          "account_roots" => ceiling(@record.fetch("account_roots") * multiplier),
          "owned_objects" => ceiling(@record.fetch("class_counts").values.sum * multiplier)
        }.freeze
      end

      def class_allocations(scale:)
        multiplier = numeric_scale(scale)
        total = population_targets(scale: multiplier).fetch("owned_objects")
        raw = @record.fetch("class_counts").sort.to_h { |name, count| [name, count * multiplier] }
        floors = raw.transform_values(&:floor)
        remaining = total - floors.values.sum
        raw.sort_by { |name, value| [-(value - value.floor), name] }.first(remaining).each { |name, _| floors[name] += 1 }
        floors.freeze
      end

      def to_h
        @record
      end

      def fetch(key)
        @record.fetch(key)
      end

      private

      def numeric_scale(value)
        scale = Rational(value.to_s)
        raise OwnerObjectDistributionError, "scale must be positive" unless scale.positive? && scale.finite?
        scale
      rescue ArgumentError, TypeError, ZeroDivisionError
        raise OwnerObjectDistributionError, "scale must be numeric"
      end

      def ceiling(value)
        value.ceil
      end
    end

    class << self
      def deep_freeze(value)
        case value
        when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array then value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end

    private

    def validate_commit!(commit)
      raise OwnerObjectDistributionError, "source_commit must be a 40-character lowercase Git commit" unless commit.match?(/\A[a-f0-9]{40}\z/)
    end

    def enforce_preflight!(observations)
      gate = @manifest.fetch("health_gate")
      indexes = observations.map { |(_, _, preflight)| preflight.fetch("latest_validated_ledger") }
      raise OwnerObjectDistributionError, "latest validated ledger spread exceeds limit" if indexes.max - indexes.min > gate.fetch("max_latest_ledger_spread")
      observations.each do |_, _, preflight|
        raise OwnerObjectDistributionError, "validated ledger age exceeds limit" if preflight.fetch("validated_ledger_age_seconds") > gate.fetch("max_validated_ledger_age_seconds")
        state = preflight["server_state"]
        unless state.nil? || gate.fetch("allowed_server_states").include?(state)
          raise OwnerObjectDistributionError, "server state is #{state.inspect}"
        end
      end
    end

    def normalize_observation(entry, preflight, observation, target_index)
      raise OwnerObjectDistributionError, "endpoint returned a different ledger" unless observation.fetch("ledger_index") == target_index
      class_counts, account_roots = classify(observation.fetch("entries"))
      record = {
        "observation_method" => "ledger_data", "endpoint_id" => entry.fetch("endpoint_id"), "operator_id" => entry.fetch("operator_id"),
        "operator_evidence_url" => entry["operator_evidence_url"], "endpoint" => observation.fetch("endpoint"),
        "ledger_index" => target_index, "ledger_hash" => hash_value(observation.fetch("ledger_hash")),
        "account_roots" => account_roots, "class_counts" => class_counts,
        "server_info_sha256" => preflight.fetch("raw_response_sha256"),
        "ledger_data_sha256" => observation.fetch("raw_response_sha256"),
        "ledger_data_page_sha256" => observation.fetch("page_sha256")
      }
      record.delete("operator_evidence_url") if record["operator_evidence_url"].nil?
      record
    end

    def classify(entries)
      raise OwnerObjectDistributionError, "ledger entries must be an array" unless entries.is_a?(Array)
      counts = Hash.new(0)
      accounts = 0
      entries.each do |entry|
        type = entry.is_a?(Hash) ? entry["LedgerEntryType"] : nil
        raise OwnerObjectDistributionError, "ledger entry type is missing" unless type.is_a?(String)
        if type == "AccountRoot"
          accounts += 1
        elsif (klass = CLASSIFIERS[type])
          counts[klass] += 1
        elsif !IGNORED_TYPES.include?(type)
          raise OwnerObjectDistributionError, "unclassified ledger entry type: #{type}"
        end
      end
      [counts.sort.to_h, accounts]
    end

    def validate_manifest!
      endpoints = @manifest.is_a?(Hash) ? @manifest["endpoints"] : nil
      minimum = @manifest["minimum_required_operators"]
      raise OwnerObjectDistributionError, "endpoint manifest must require at least one operator" unless minimum.is_a?(Integer) && minimum >= 1
      raise OwnerObjectDistributionError, "endpoint manifest does not meet minimum_required_operators" unless endpoints.is_a?(Array) && endpoints.length >= minimum
      required = %w[endpoint_id operator_id url]
      endpoints.each do |entry|
        raise OwnerObjectDistributionError, "endpoint entry must be a mapping" unless entry.is_a?(Hash)
        missing = required - entry.keys
        raise OwnerObjectDistributionError, "endpoint entry missing: #{missing.join(', ')}" unless missing.empty?
      end
      raise OwnerObjectDistributionError, "operator_id values must be unique" unless endpoints.map { |entry| entry.fetch("operator_id") }.uniq.length == endpoints.length
    end

    def validate_bundle!(record)
      required = %w[schema_version status evidence_tier source_commit target_ledger_index ledger_hash account_roots class_counts observations class_allocation_tie_break]
      raise OwnerObjectDistributionError, "distribution bundle keys are invalid" unless record.is_a?(Hash) && (required - record.keys).empty? && record.keys.all? { |key| required.include?(key) || %w[captured_at selection_rule].include?(key) }
      raise OwnerObjectDistributionError, "distribution schema version is invalid" unless record["schema_version"] == "owner-object-distribution-bundle-v1"
      validate_commit!(record["source_commit"])
      raise OwnerObjectDistributionError, "distribution target ledger is invalid" unless record["target_ledger_index"].is_a?(Integer) && record["target_ledger_index"].positive?
      hash_value(record["ledger_hash"])
      raise OwnerObjectDistributionError, "distribution allocation tie break is invalid" unless record["class_allocation_tie_break"] == "ascending-class-name"
      observations = record["observations"]
      raise OwnerObjectDistributionError, "distribution observations are invalid" unless observations.is_a?(Array) && !observations.empty?
      observations.each { |observation| validate_observation!(observation, record) }
      operators = observations.map { |row| row["operator_id"] }.uniq
      expected_tier = operators.length == 1 ? "operator_local" : "independently_corroborated"
      expected_status = operators.length == 1 ? "captured" : "agreed"
      raise OwnerObjectDistributionError, "distribution bundle evidence tier is invalid" unless record["evidence_tier"] == expected_tier && record["status"] == expected_status
      raise OwnerObjectDistributionError, "distribution class counts are invalid" unless record["class_counts"].is_a?(Hash) && record["class_counts"].all? { |name, count| CLASSIFIERS.value?(name) && count.is_a?(Integer) && count >= 0 }
      raise OwnerObjectDistributionError, "distribution account roots are invalid" unless record["account_roots"].is_a?(Integer) && record["account_roots"].positive?
      raise OwnerObjectDistributionError, "distribution must record at least one declared operator" unless operators.length >= 1
    end

    def validate_observation!(observation, bundle)
      raise OwnerObjectDistributionError, "distribution observation is invalid" unless observation.is_a?(Hash)
      case observation["observation_method"]
      when "indexed_aggregate_report"
        required = %w[observation_method operator_id dataset_type ledger_index ledger_hash account_roots class_counts query_sha256 result_sha256 classifier_version]
        optional = %w[operator_evidence_url]
        raise OwnerObjectDistributionError, "indexed report observation keys are invalid" unless exact_keys?(observation, required, optional)
        raise OwnerObjectDistributionError, "indexed report operator id is invalid" unless observation["operator_id"].is_a?(String) && observation["operator_id"].match?(/\A[a-z0-9][a-z0-9._-]{0,63}\z/)
        raise OwnerObjectDistributionError, "indexed report dataset type is invalid" unless OperatorObjectReport::DATASET_TYPES.include?(observation["dataset_type"])
        raise OwnerObjectDistributionError, "indexed report classifier is invalid" unless observation["classifier_version"] == "owner-object-classifier-v1"
        %w[query_sha256 result_sha256].each do |key|
          raise OwnerObjectDistributionError, "indexed report digest is invalid" unless observation[key].is_a?(String) && observation[key].match?(/\A[a-f0-9]{64}\z/)
        end
      when "ledger_data"
        required = %w[observation_method endpoint_id operator_id endpoint ledger_index ledger_hash account_roots class_counts server_info_sha256 ledger_data_sha256 ledger_data_page_sha256]
        optional = %w[operator_evidence_url]
        raise OwnerObjectDistributionError, "ledger_data observation keys are invalid" unless exact_keys?(observation, required, optional)
        raise OwnerObjectDistributionError, "ledger_data endpoint is invalid" unless observation["endpoint"].is_a?(String) && observation["endpoint"].start_with?("https://")
        %w[server_info_sha256 ledger_data_sha256].each do |key|
          raise OwnerObjectDistributionError, "ledger_data digest is invalid" unless observation[key].is_a?(String) && observation[key].match?(/\A[a-f0-9]{64}\z/)
        end
        raise OwnerObjectDistributionError, "ledger_data page digests are invalid" unless observation["ledger_data_page_sha256"].is_a?(Array) && !observation["ledger_data_page_sha256"].empty? && observation["ledger_data_page_sha256"].all? { |hash| hash.is_a?(String) && hash.match?(/\A[a-f0-9]{64}\z/) }
      else
        raise OwnerObjectDistributionError, "distribution observation method is invalid"
      end
      raise OwnerObjectDistributionError, "distribution observation ledger does not match bundle" unless observation["ledger_index"] == bundle["target_ledger_index"] && observation["ledger_hash"] == bundle["ledger_hash"]
      raise OwnerObjectDistributionError, "distribution observation counts do not match bundle" unless observation["account_roots"] == bundle["account_roots"] && observation["class_counts"] == bundle["class_counts"]
      validate_evidence_url!(observation["operator_evidence_url"]) if observation.key?("operator_evidence_url")
    end

    def exact_keys?(record, required, optional)
      (required - record.keys).empty? && (record.keys - required - optional).empty?
    end

    def validate_evidence_url!(value)
      return if value.nil?

      uri = URI.parse(value)
      raise OwnerObjectDistributionError, "distribution evidence URL is invalid" unless uri.is_a?(URI::HTTPS) && uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil? && uri.host && uri.host != "localhost" && !uri.host.end_with?(".local")
    rescue URI::InvalidURIError
      raise OwnerObjectDistributionError, "distribution evidence URL is invalid"
    end

    def hash_value(value)
      text = String(value)
      raise OwnerObjectDistributionError, "ledger hash was malformed" unless text.match?(/\A[A-Fa-f0-9]{64}\z/)
      text.upcase
    end
  end
end
