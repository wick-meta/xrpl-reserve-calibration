# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CompleteReservesArtifactsError < StudyError; end

  class CompleteReservesArtifacts
    PLANNING_NETWORK_SCOPE = "isolated-network-only"
    SENSITIVE = /secret|seed|private[_-]?key|signature|signing|tx_blob|hostname|username|absolute[_-]?path|location|time[_-]?zone/i
    REQUIRED = %w[run_id status counted_run distribution_sha256 snapshot_id object_counts_by_class locked_xrp_drops released_xrp_drops owner_count_lifecycle].freeze

    def initialize
      @publisher = RuntimePublisher.new(error_class: CompleteReservesArtifactsError, failure_label: "complete reserves disposition")
    end

    def publish_disposition(result:, summary:)
      validate!(result, summary)
      bytes = { "result.json" => JSON.pretty_generate(result) + "\n", "summary.json" => JSON.pretty_generate(summary) + "\n" }
      bytes["SHA256SUMS"] = bytes.keys.sort.map { |name| "#{Digest::SHA256.hexdigest(bytes.fetch(name))}  #{name}\n" }.join
      output = File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "results", result.fetch("run_id"))
      @publisher.publish(output) { |staging| bytes.each { |name, content| staging.write(name, content) } }
      { "run_id" => result.fetch("run_id"), "output_dir" => output }.freeze
    end

    def publish_planning_bundle(benchmark:, schedule:, security:)
      validate_planning!(benchmark, schedule, security)
      bindings = {
        "schema_version" => "complete-reserves-planning-bindings-v1",
        "profile_id" => benchmark.fetch("profile_id"),
        "profile_sha256" => benchmark.fetch("profile_sha256"),
        "distribution_sha256" => benchmark.fetch("distribution_sha256"),
        "candidate_sha256" => benchmark.fetch("candidate_sha256"),
        "security_config_sha256" => security.fetch("security_config_sha256"),
        "benchmark_sha256" => benchmark.fetch("benchmark_sha256"),
        "schedule_sha256" => schedule.fetch("schedule_sha256"),
        "security_sha256" => security.fetch("security_sha256"),
        "network_scope" => PLANNING_NETWORK_SCOPE,
        "counted_run" => false,
        "execution_authorized" => false
      }
      records = {
        "benchmark.json" => JSON.pretty_generate(benchmark) + "\n",
        "bindings.json" => JSON.pretty_generate(bindings) + "\n",
        "schedule.json" => JSON.pretty_generate(schedule) + "\n",
        "security.json" => JSON.pretty_generate(security) + "\n"
      }
      sums = records.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      records["SHA256SUMS"] = sums.keys.sort.map { |name| "#{sums.fetch(name)}  #{name}\n" }.join
      output = File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "planning", schedule.fetch("schedule_sha256"))
      @publisher.publish(output) { |staging| records.each { |name, bytes| staging.write(name, bytes) } }
      {
        "schedule_sha256" => schedule.fetch("schedule_sha256"),
        "security_sha256" => security.fetch("security_sha256"),
        "output_dir" => output,
        "artifact_sha256" => sums.freeze
      }.freeze
    rescue KeyError, TypeError, SecurityWorkloadError
      raise CompleteReservesArtifactsError, "invalid complete reserves planning bundle"
    end

    private

    def validate!(result, summary)
      raise CompleteReservesArtifactsError, "incomplete complete reserves disposition" unless result.is_a?(Hash) && REQUIRED.all? { |key| result.key?(key) } && %w[passed failed aborted].include?(result["status"]) && result["counted_run"] == false
      reject_sensitive!(result)
      reject_sensitive!(summary)
    end

    def validate_planning!(benchmark, schedule, security)
      valid = benchmark.is_a?(Hash) && schedule.is_a?(Hash) && security.is_a?(Hash) &&
        benchmark["schema_version"] == "complete-reserves-provisioning-estimate-v1" &&
        schedule["schema_version"] == "complete-reserves-profile-schedule-v1" &&
        security["schema_version"] == "complete-reserves-security-evaluation-v1" &&
        [benchmark, schedule, security].all? { |record| record["network_scope"] == PLANNING_NETWORK_SCOPE } &&
        [benchmark, schedule, security].all? { |record| record["counted_run"] == false } &&
        [benchmark, schedule, security].all? { |record| record["execution_authorized"] == false } &&
        schedule["benchmark_sha256"] == benchmark["benchmark_sha256"] &&
        [schedule, security].all? { |record| record["profile_id"] == benchmark["profile_id"] } &&
        schedule["profile_sha256"] == benchmark["profile_sha256"] &&
        security["profile_sha256"] == benchmark["profile_sha256"] &&
        schedule["security_config_sha256"] == security["security_config_sha256"] &&
        security["security_config_sha256"] == SecurityWorkload.new.security_config_sha256 &&
        [schedule, security].all? { |record| record["distribution_sha256"] == benchmark["distribution_sha256"] } &&
        [schedule, security].all? { |record| record["candidate_sha256"] == benchmark["candidate_sha256"] } &&
        valid_record_hash?(benchmark, "benchmark_sha256") && valid_record_hash?(schedule, "schedule_sha256") &&
        valid_record_hash?(security, "security_sha256")
      raise CompleteReservesArtifactsError, "invalid complete reserves planning bundle" unless valid
      reject_sensitive!(benchmark)
      reject_sensitive!(schedule)
      reject_sensitive!(security)
    end

    def valid_record_hash?(record, field)
      claimed = record[field]
      return false unless claimed.is_a?(String) && claimed.match?(/\A[0-9a-f]{64}\z/)

      canonical = canonical(record.reject { |key, _| key == field })
      Digest::SHA256.hexdigest(JSON.generate(canonical)) == claimed
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def reject_sensitive!(value)
      case value
      when Hash then value.each { |key, nested| raise CompleteReservesArtifactsError, "sensitive complete reserves content" if key.to_s.match?(SENSITIVE); reject_sensitive!(nested) }
      when Array then value.each { |nested| reject_sensitive!(nested) }
      when String then raise CompleteReservesArtifactsError, "sensitive complete reserves content" if value.match?(SENSITIVE)
      end
    end
  end
end
