# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module XrplReserveStudy
  class SecurityWorkloadError < StudyError; end

  class SecurityWorkload
    PATH = File.expand_path("../../study/complete-reserves-security-workloads-v1.yml", __dir__)
    SHA256 = /\A[0-9a-f]{64}\z/
    WORKLOADS = [
      { "workload_id" => "baseline", "transaction_ceiling" => 100 },
      { "workload_id" => "account-burst", "transaction_ceiling" => 500 },
      { "workload_id" => "object-burst", "transaction_ceiling" => 500 },
      { "workload_id" => "mixed", "transaction_ceiling" => 500 },
      { "workload_id" => "churn", "transaction_ceiling" => 500 },
      { "workload_id" => "recovery", "transaction_ceiling" => 100 }
    ].freeze
    GATES = {
      "transaction_success" => { "minimum" => 0.99 },
      "transaction_ceiling" => { "declared_per_workload" => true },
      "close_time_ceiling" => { "maximum" => 5.0, "baseline_multiplier_maximum" => 2.0 },
      "memory_ceiling" => { "maximum_resource_ratio" => 0.9, "baseline_multiplier_maximum" => 2.0 },
      "cpu_ceiling" => { "maximum" => 0.9, "baseline_multiplier_maximum" => 4.0 },
      "disk_ceiling" => { "minimum_free_ratio" => 0.1 },
      "io_wait_ceiling" => { "maximum" => 0.25, "baseline_multiplier_maximum" => 5.0 },
      "queue_ceiling" => { "maximum" => 1_000, "baseline_multiplier_maximum" => 100.0 },
      "finality_ceiling" => { "maximum" => 30.0, "baseline_multiplier_maximum" => 4.0 },
      "recovery_ceiling" => { "maximum" => 300.0 },
      "reset_recovery" => { "required" => true },
      "artifact_integrity" => { "sha256_required" => true }
    }.freeze
    EXPECTED = {
      "schema_version" => "complete-reserves-security-workloads-v1",
      "network_scope" => "isolated-network-only",
      "counted_run" => false,
      "execution_authorized" => false,
      "workloads" => WORKLOADS,
      "gates" => GATES
    }.freeze
    METRIC_KEYS = %w[
      workload_id profile_id profile_sha256 distribution_sha256 candidate_sha256
      attempted_transactions validated_transactions transaction_success_ratio
      ledger_close_seconds_p95 peak_memory_bytes memory_limit_bytes
      cpu_utilization_ratio free_disk_bytes disk_total_bytes io_wait_ratio max_queue_depth finality_seconds_p95
      recovery_seconds recovery_confirmed reset_confirmed artifact_sha256
    ].freeze

    attr_reader :contract, :security_config_sha256

    def initialize(path: PATH, source: nil)
      bytes = source || File.binread(path)
      data = YAML.safe_load(bytes, permitted_classes: [], aliases: false)
      reject! unless data == EXPECTED
      @security_config_sha256 = Digest::SHA256.hexdigest(bytes).freeze
      @contract = deep_freeze(deep_copy(data))
    rescue Psych::Exception, SystemCallError
      reject!
    end

    def evaluate(baseline:, observed:)
      validate_metrics!(baseline, expected_workload: "baseline", require_artifact_hash: true)
      validate_metrics!(observed)
      reject! if observed.fetch("workload_id") == "baseline"
      reject! unless observed.fetch("memory_limit_bytes") == baseline.fetch("memory_limit_bytes")
      reject! unless observed.fetch("disk_total_bytes") == baseline.fetch("disk_total_bytes")
      %w[profile_id profile_sha256 distribution_sha256 candidate_sha256].each do |key|
        reject! unless observed.fetch(key) == baseline.fetch(key)
      end
      workload = WORKLOADS.find { |entry| entry.fetch("workload_id") == observed.fetch("workload_id") }
      reject! unless workload

      gate_results = {
        "transaction_success" => observed.fetch("transaction_success_ratio") >= GATES.dig("transaction_success", "minimum"),
        "transaction_ceiling" => observed.fetch("attempted_transactions") <= workload.fetch("transaction_ceiling"),
        "close_time_ceiling" => below_absolute_and_baseline?(observed, baseline, "ledger_close_seconds_p95", "close_time_ceiling"),
        "memory_ceiling" => observed.fetch("peak_memory_bytes").fdiv(observed.fetch("memory_limit_bytes")) <= GATES.dig("memory_ceiling", "maximum_resource_ratio") &&
          below_baseline?(observed, baseline, "peak_memory_bytes", "memory_ceiling"),
        "cpu_ceiling" => below_absolute_and_baseline?(observed, baseline, "cpu_utilization_ratio", "cpu_ceiling"),
        "disk_ceiling" => observed.fetch("free_disk_bytes").fdiv(observed.fetch("disk_total_bytes")) >= GATES.dig("disk_ceiling", "minimum_free_ratio"),
        "io_wait_ceiling" => below_absolute_and_baseline?(observed, baseline, "io_wait_ratio", "io_wait_ceiling"),
        "queue_ceiling" => below_absolute_and_baseline?(observed, baseline, "max_queue_depth", "queue_ceiling"),
        "finality_ceiling" => below_absolute_and_baseline?(observed, baseline, "finality_seconds_p95", "finality_ceiling"),
        "recovery_ceiling" => observed.fetch("recovery_confirmed") == true && observed.fetch("recovery_seconds") <= GATES.dig("recovery_ceiling", "maximum"),
        "reset_recovery" => observed.fetch("reset_confirmed") == true,
        "artifact_integrity" => observed.fetch("artifact_sha256").match?(SHA256)
      }
      result = {
        "schema_version" => "complete-reserves-security-evaluation-v1",
        "workload_id" => observed.fetch("workload_id"),
        "profile_id" => observed.fetch("profile_id"),
        "profile_sha256" => observed.fetch("profile_sha256"),
        "distribution_sha256" => observed.fetch("distribution_sha256"),
        "candidate_sha256" => observed.fetch("candidate_sha256"),
        "security_config_sha256" => @security_config_sha256,
        "attempted_transactions" => observed.fetch("attempted_transactions"),
        "validated_transactions" => observed.fetch("validated_transactions"),
        "transaction_ceiling" => workload.fetch("transaction_ceiling"),
        "baseline_artifact_sha256" => baseline.fetch("artifact_sha256"),
        "observed_artifact_sha256" => observed.fetch("artifact_sha256"),
        "gate_results" => gate_results,
        "passed_gates" => gate_results.select { |_name, passed| passed }.keys,
        "failed_gates" => gate_results.reject { |_name, passed| passed }.keys,
        "passed" => gate_results.values.all?,
        "network_scope" => "isolated-network-only",
        "counted_run" => false,
        "execution_authorized" => false
      }
      result["security_sha256"] = canonical_sha256(result)
      deep_freeze(result)
    rescue KeyError, TypeError, ZeroDivisionError
      reject!
    end

    private

    def validate_metrics!(metrics, expected_workload: nil, require_artifact_hash: false)
      reject! unless metrics.is_a?(Hash) && metrics.keys.all? { |key| key.is_a?(String) } && metrics.keys.sort == METRIC_KEYS.sort
      workload_id = metrics.fetch("workload_id")
      reject! unless WORKLOADS.any? { |entry| entry.fetch("workload_id") == workload_id }
      reject! unless workload_id == expected_workload if expected_workload
      declaration = WORKLOADS.find { |entry| entry.fetch("workload_id") == workload_id }
      reject! unless %w[complete-reserves-calibrated-v1 complete-reserves-full-matrix-v1].include?(metrics.fetch("profile_id"))
      %w[profile_sha256 distribution_sha256 candidate_sha256].each do |key|
        reject! unless metrics.fetch(key).is_a?(String) && metrics.fetch(key).match?(SHA256)
      end
      %w[transaction_success_ratio ledger_close_seconds_p95 cpu_utilization_ratio io_wait_ratio finality_seconds_p95 recovery_seconds].each do |key|
        reject! unless finite_nonnegative_numeric?(metrics.fetch(key))
      end
      %w[peak_memory_bytes free_disk_bytes max_queue_depth].each { |key| reject! unless nonnegative_integer?(metrics.fetch(key)) }
      reject! unless positive_integer?(metrics.fetch("attempted_transactions"))
      reject! unless nonnegative_integer?(metrics.fetch("validated_transactions")) &&
        metrics.fetch("validated_transactions") <= metrics.fetch("attempted_transactions")
      %w[memory_limit_bytes disk_total_bytes].each { |key| reject! unless positive_integer?(metrics.fetch(key)) }
      reject! unless metrics.fetch("peak_memory_bytes") <= metrics.fetch("memory_limit_bytes")
      reject! unless metrics.fetch("free_disk_bytes") <= metrics.fetch("disk_total_bytes")
      reject! unless metrics.fetch("transaction_success_ratio") <= 1.0 && metrics.fetch("cpu_utilization_ratio") <= 1.0 && metrics.fetch("io_wait_ratio") <= 1.0
      expected_ratio = metrics.fetch("validated_transactions").fdiv(metrics.fetch("attempted_transactions"))
      reject! unless (metrics.fetch("transaction_success_ratio") - expected_ratio).abs <= 1e-12
      reject! if expected_workload && metrics.fetch("attempted_transactions") > declaration.fetch("transaction_ceiling")
      reject! unless [true, false].include?(metrics.fetch("recovery_confirmed")) && [true, false].include?(metrics.fetch("reset_confirmed"))
      reject! unless metrics.fetch("artifact_sha256").is_a?(String)
      reject! if require_artifact_hash && !metrics.fetch("artifact_sha256").match?(SHA256)
    end

    def below_absolute_and_baseline?(observed, baseline, metric, gate)
      observed.fetch(metric) <= GATES.dig(gate, "maximum") && below_baseline?(observed, baseline, metric, gate)
    end

    def below_baseline?(observed, baseline, metric, gate)
      observed.fetch(metric) <= baseline.fetch(metric) * GATES.dig(gate, "baseline_multiplier_maximum")
    end

    def finite_nonnegative_numeric?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    rescue NoMethodError
      false
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def nonnegative_integer?(value)
      value.is_a?(Integer) && value >= 0
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def canonical_sha256(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise SecurityWorkloadError, "invalid complete reserves security workload"
    end
  end
end
