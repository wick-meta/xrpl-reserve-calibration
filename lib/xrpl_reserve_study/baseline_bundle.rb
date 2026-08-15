# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "yaml"

module XrplReserveStudy
  class BaselineBundle
    def initialize(manifest_path:, observer_factory: nil)
      @manifest_path = File.expand_path(manifest_path)
      @manifest = YAML.safe_load(File.read(@manifest_path), permitted_classes: [], aliases: false)
      @observer_factory = observer_factory || ->(endpoint) { MainnetObserver.new(endpoint: endpoint) }
      validate_manifest!
    rescue Psych::Exception => e
      raise ObservationError, "invalid endpoint manifest: #{e.message}"
    end

    def capture(output_dir:, source_commit:)
      unless source_commit.match?(/\A[a-f0-9]{40}\z/)
        raise ObservationError, "source_commit must be a 40-character lowercase Git commit"
      end
      destination = File.expand_path(output_dir)
      raise ObservationError, "output directory already exists" if File.exist?(destination)
      staging = "#{destination}.tmp-#{Process.pid}"
      raise ObservationError, "temporary output directory already exists" if File.exist?(staging)

      observations = @manifest.fetch("endpoints").map do |entry|
        observer = @observer_factory.call(entry.fetch("url"))
        [entry, observer, observer.preflight]
      end
      target_index = observations.map { |(_, _, preflight)| preflight.fetch("latest_validated_ledger") }.min

      FileUtils.mkdir_p(File.join(staging, "raw"))
      preflight_rows = observations.map do |entry, _, preflight|
        endpoint_id = entry.fetch("endpoint_id")
        File.binwrite(File.join(staging, "raw", "#{endpoint_id}-server-info.json"), preflight.fetch("raw_response"))
        {
          "endpoint_id" => endpoint_id,
          "operator_id" => entry.fetch("operator_id"),
          "latest_validated_ledger" => preflight.fetch("latest_validated_ledger"),
          "validated_ledger_age_seconds" => preflight.fetch("validated_ledger_age_seconds"),
          "server_state" => preflight["server_state"],
          "server_info_sha256" => preflight.fetch("raw_response_sha256")
        }
      end
      failures = preflight_failures(preflight_rows)
      unless failures.empty?
        bundle = bundle_record(
          status: "preflight_rejected",
          target_index: nil,
          preflight: preflight_rows,
          failures: failures,
          observations: [],
          source_commit: source_commit
        )
        publish_staging(staging, destination, bundle)
        return bundle
      end

      normalized = []
      capture_failures = []
      observations.each do |entry, observer, preflight|
        endpoint_id = entry.fetch("endpoint_id")
        begin
          observation = observer.capture_exact(ledger_index: target_index)
          File.binwrite(File.join(staging, "raw", "#{endpoint_id}-fee-settings.json"), observation.fetch("raw_response"))
          normalized << {
          "endpoint_id" => endpoint_id,
          "operator_id" => entry.fetch("operator_id"),
          "operator_evidence_url" => entry.fetch("operator_evidence_url"),
          "endpoint" => observation.fetch("endpoint"),
          "ledger_index" => observation.fetch("ledger_index"),
          "ledger_hash" => observation.fetch("ledger_hash"),
          "reserve_base_drops" => observation.fetch("reserve_base_drops"),
          "reserve_increment_drops" => observation.fetch("reserve_increment_drops"),
          "fee_settings_index" => observation.fetch("fee_settings_index"),
          "server_info_sha256" => preflight.fetch("raw_response_sha256"),
          "fee_settings_sha256" => observation.fetch("raw_response_sha256")
          }
        rescue ObservationError => e
          capture_failures << { "endpoint_id" => endpoint_id, "reasons" => [e.message] }
        end
      end
      unless capture_failures.empty?
        bundle = bundle_record(
          status: "capture_failed",
          target_index: target_index,
          preflight: preflight_rows,
          failures: capture_failures,
          observations: normalized,
          source_commit: source_commit
        )
        publish_staging(staging, destination, bundle)
        return bundle
      end

      agreement_keys = normalized.map do |row|
        row.values_at("ledger_index", "ledger_hash", "reserve_base_drops", "reserve_increment_drops")
      end.uniq
      bundle = bundle_record(
        status: agreement_keys.one? ? "agreed" : "disagreement",
        target_index: target_index,
        preflight: preflight_rows,
        failures: [],
        observations: normalized,
        source_commit: source_commit
      )
      publish_staging(staging, destination, bundle)
      bundle
    rescue ObservationError
      FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      raise
    end

    private

    def preflight_failures(rows)
      rules = @manifest.fetch("health_gate")
      failures = rows.each_with_object([]) do |row, result|
        reasons = []
        if row.fetch("validated_ledger_age_seconds") > rules.fetch("max_validated_ledger_age_seconds")
          reasons << "validated ledger age exceeds limit"
        end
        state = row["server_state"]
        if state && !rules.fetch("allowed_server_states").include?(state)
          reasons << "server state is #{state}"
        end
        result << { "endpoint_id" => row.fetch("endpoint_id"), "reasons" => reasons } unless reasons.empty?
      end
      indexes = rows.map { |row| row.fetch("latest_validated_ledger") }
      if indexes.max - indexes.min > rules.fetch("max_latest_ledger_spread")
        failures << {
          "endpoint_id" => "endpoint-set",
          "reasons" => ["latest validated ledger spread exceeds limit"]
        }
      end
      failures
    end

    def bundle_record(status:, target_index:, preflight:, failures:, observations:, source_commit:)
      {
        "schema_version" => "mainnet-baseline-bundle-v1",
        "source_commit" => source_commit,
        "captured_at" => Time.now.utc.iso8601(6),
        "selection_rule" => "minimum-latest-validated-ledger",
        "target_ledger_index" => target_index,
        "status" => status,
        "preflight" => preflight,
        "failures" => failures,
        "observations" => observations
      }
    end

    def publish_staging(staging, destination, bundle)
      File.write(File.join(staging, "baseline.json"), JSON.pretty_generate(bundle) + "\n")
      FileUtils.mv(staging, destination)
    end

    def validate_manifest!
      endpoints = @manifest.is_a?(Hash) ? @manifest["endpoints"] : nil
      minimum = @manifest["minimum_required_operators"]
      unless minimum.is_a?(Integer) && minimum >= 2
        raise ObservationError, "endpoint manifest must require at least two operators"
      end
      unless endpoints.is_a?(Array) && endpoints.length >= minimum
        raise ObservationError, "endpoint manifest does not meet minimum_required_operators"
      end

      required = %w[endpoint_id operator_id operator_evidence_url url]
      health_gate = @manifest["health_gate"]
      unless health_gate.is_a?(Hash) && health_gate["max_validated_ledger_age_seconds"].is_a?(Integer) &&
          health_gate["max_latest_ledger_spread"].is_a?(Integer) && health_gate["allowed_server_states"].is_a?(Array)
        raise ObservationError, "endpoint manifest must define a health_gate"
      end
      endpoints.each do |entry|
        raise ObservationError, "endpoint entry must be a mapping" unless entry.is_a?(Hash)
        missing = required - entry.keys
        raise ObservationError, "endpoint entry missing: #{missing.join(', ')}" unless missing.empty?
        unless entry.fetch("endpoint_id").match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
          raise ObservationError, "endpoint_id must contain lowercase letters, digits, and hyphens"
        end
      end
      raise ObservationError, "endpoint_id values must be unique" unless endpoints.map { |e| e["endpoint_id"] }.uniq.length == endpoints.length
      raise ObservationError, "operator_id values must be unique" unless endpoints.map { |e| e["operator_id"] }.uniq.length == endpoints.length
    end
  end
end
