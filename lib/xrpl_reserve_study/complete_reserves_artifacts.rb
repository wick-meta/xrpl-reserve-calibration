# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CompleteReservesArtifactsError < StudyError; end

  class CompleteReservesArtifacts
    PLANNING_NETWORK_SCOPE = "isolated-network-only"
    SENSITIVE = /secret|seed|private[_-]?key|signature|signing|tx_blob|hostname|username|absolute[_-]?path|location|time[_-]?zone/i
    REQUIRED = %w[run_id status counted_run distribution_sha256 snapshot_id object_counts_by_class locked_xrp_drops released_xrp_drops owner_count_lifecycle].freeze
    EXECUTION_WORKLOADS = %w[baseline account-burst object-burst mixed churn recovery].freeze
    EXECUTION_SECURITY_WORKLOADS = EXECUTION_WORKLOADS.drop(1).freeze
    EXECUTION_HASH_BINDINGS = %w[
      profile_sha256 schedule_sha256 schedule_item_sha256 security_config_sha256
      distribution_sha256 candidate_sha256
    ].freeze
    EXECUTION_FILES = %w[bindings.json metrics.json result.json resume.json security.json].freeze

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

    def publish_execution_bundle(result:, metrics:, security_evaluations:, resume_record:)
      validate_execution!(result, metrics, security_evaluations, resume_record)
      bindings = execution_bindings(result)
      payload = {
        "bindings.json" => JSON.pretty_generate(bindings) + "\n",
        "metrics.json" => JSON.pretty_generate(metrics) + "\n",
        "result.json" => JSON.pretty_generate(result) + "\n",
        "security.json" => JSON.pretty_generate(security_evaluations) + "\n"
      }
      artifact_sha256 = execution_payload_sha256(payload)
      completed_resume = resume_record.merge("result_artifact_sha256" => artifact_sha256).freeze
      payload["resume.json"] = JSON.pretty_generate(completed_resume) + "\n"
      sums = payload.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      payload["SHA256SUMS"] = sums.keys.sort.map { |name| "#{sums.fetch(name)}  #{name}\n" }.join
      output = execution_output(result.fetch("run_id"))
      @publisher.publish(output) { |staging| payload.each { |name, bytes| staging.write(name, bytes) } }
      {
        "result_artifact_sha256" => artifact_sha256,
        "resume_record" => completed_resume
      }.freeze
    rescue KeyError, TypeError, JSON::GeneratorError
      raise CompleteReservesArtifactsError, "invalid complete reserves execution bundle"
    end

    def verify_execution_resume(record:, item:)
      validate_resume_record!(record)
      validate_resume_item!(record, item)
      output = execution_output(record.fetch("run_id"))
      records = EXECUTION_FILES.to_h { |name| [name, read_execution_file!(output, name)] }
      verify_execution_sums!(output, records)
      payload = records.reject { |name, _| name == "resume.json" }
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact" unless
        execution_payload_sha256(payload) == record.fetch("result_artifact_sha256")
      stored_resume = JSON.parse(records.fetch("resume.json"))
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact" unless stored_resume == record
      result = JSON.parse(records.fetch("result.json"))
      metrics = JSON.parse(records.fetch("metrics.json"))
      security = JSON.parse(records.fetch("security.json"))
      validate_execution!(result, metrics, security, record.reject { |key, _| key == "result_artifact_sha256" })
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact" unless execution_bindings(result) == JSON.parse(records.fetch("bindings.json"))
      result.freeze
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact"
    end

    private

    def validate_execution!(result, metrics, security_evaluations, resume_record)
      valid = result.is_a?(Hash) && result["schema_version"] == "complete-reserves-execution-result-v1" &&
        result["status"] == "passed" && result["profile_id"] == "complete-reserves-calibrated-v1" &&
        result["network_scope"] == PLANNING_NETWORK_SCOPE && result["counted_run"] == false && result["execution_authorized"] == false &&
        result["run_id"].is_a?(String) && result["run_id"].match?(/\Acal-a[0-9]{9}-o[0-9]{9}-r[0-9]{2}\z/) &&
        result["snapshot_id"].is_a?(String) && result["snapshot_id"].match?(/\A[a-z0-9-]+\z/) &&
        EXECUTION_HASH_BINDINGS.all? { |key| sha?(result[key]) } &&
        result["recovery_confirmed"] == true && result["reset_confirmed"] == true && finite_nonnegative?(result["recovery_seconds"]) &&
        valid_execution_ledger?(result["ledger"]) && valid_workload_hashes?(result["workload_artifact_sha256"], EXECUTION_WORKLOADS) &&
        valid_workload_hashes?(result["security_sha256"], EXECUTION_SECURITY_WORKLOADS) &&
        metrics.is_a?(Array) && metrics.map { |entry| entry["workload_id"] } == EXECUTION_WORKLOADS &&
        security_evaluations.is_a?(Array) && security_evaluations.map { |entry| entry["workload_id"] } == EXECUTION_SECURITY_WORKLOADS &&
        metrics.all? { |entry| execution_metric_bound?(entry, result) } &&
        security_evaluations.all? { |entry| execution_security_bound?(entry, result) } &&
        result.fetch("workload_artifact_sha256") == metrics.to_h { |entry| [entry.fetch("workload_id"), entry.fetch("artifact_sha256")] } &&
        result.fetch("security_sha256") == security_evaluations.to_h { |entry| [entry.fetch("workload_id"), entry.fetch("security_sha256")] }
      raise CompleteReservesArtifactsError, "invalid complete reserves execution bundle" unless valid
      validate_resume_record!(resume_record, artifact_hash_required: false)
      raise CompleteReservesArtifactsError, "invalid complete reserves execution bundle" unless
        resume_record["run_id"] == result["run_id"] && resume_record["schedule_item_sha256"] == result["schedule_item_sha256"] &&
        resume_record["reset_confirmed"] == true && resume_record["recovery_confirmed"] == true
      reject_sensitive!(result)
      reject_sensitive!(metrics)
      reject_sensitive!(security_evaluations)
      reject_sensitive!(resume_record)
    rescue KeyError, TypeError
      raise CompleteReservesArtifactsError, "invalid complete reserves execution bundle"
    end

    def validate_resume_record!(record, artifact_hash_required: true)
      expected = %w[schema_version run_id schedule_item_sha256 reset_confirmed recovery_confirmed]
      expected << "result_artifact_sha256" if artifact_hash_required
      valid = record.is_a?(Hash) && record.keys.sort == expected.sort &&
        record["schema_version"] == "complete-reserves-resume-v1" &&
        record["run_id"].is_a?(String) && record["run_id"].match?(/\Acal-a[0-9]{9}-o[0-9]{9}-r[0-9]{2}\z/) &&
        sha?(record["schedule_item_sha256"]) && record["reset_confirmed"] == true && record["recovery_confirmed"] == true &&
        (!artifact_hash_required || sha?(record["result_artifact_sha256"]))
      raise CompleteReservesArtifactsError, "invalid complete reserves resume record" unless valid
    end

    def validate_resume_item!(record, item)
      valid = item.is_a?(Hash) && item["run_id"] == record["run_id"] &&
        item["schedule_item_sha256"] == record["schedule_item_sha256"] &&
        item["profile_id"] == "complete-reserves-calibrated-v1" && item["network_scope"] == PLANNING_NETWORK_SCOPE &&
        item["counted_run"] == false && item["execution_authorized"] == false
      raise CompleteReservesArtifactsError, "invalid complete reserves resume record" unless valid
    end

    def execution_metric_bound?(entry, result)
      entry.is_a?(Hash) && EXECUTION_WORKLOADS.include?(entry["workload_id"]) && sha?(entry["artifact_sha256"]) &&
        %w[profile_id profile_sha256 distribution_sha256 candidate_sha256].all? { |key| entry[key] == result[key] }
    end

    def execution_security_bound?(entry, result)
      entry.is_a?(Hash) && EXECUTION_SECURITY_WORKLOADS.include?(entry["workload_id"]) && entry["passed"] == true &&
        entry["failed_gates"] == [] && sha?(entry["security_sha256"]) &&
        entry["security_config_sha256"] == result["security_config_sha256"] &&
        %w[profile_id profile_sha256 distribution_sha256 candidate_sha256].all? { |key| entry[key] == result[key] }
    end

    def valid_execution_ledger?(ledger)
      ledger.is_a?(Hash) && ledger.keys.sort == %w[account_roots class_counts ledger_hash ledger_index network_id].sort &&
        ledger["network_id"].is_a?(String) && ledger["network_id"].match?(/\Acandidate-[a-z0-9-]+\z/) &&
        ledger["ledger_index"].is_a?(Integer) && ledger["ledger_index"].positive? && sha?(ledger["ledger_hash"]) &&
        ledger["account_roots"].is_a?(Integer) && ledger["account_roots"].positive? &&
        ledger["class_counts"].is_a?(Hash) && ledger["class_counts"].any? &&
        ledger["class_counts"].all? { |key, count| key.is_a?(String) && count.is_a?(Integer) && count.positive? }
    end

    def valid_workload_hashes?(value, names)
      value.is_a?(Hash) && value.keys == names && value.values.all? { |hash| sha?(hash) }
    end

    def execution_bindings(result)
      {
        "schema_version" => "complete-reserves-execution-bindings-v1", "run_id" => result.fetch("run_id"),
        "profile_id" => result.fetch("profile_id"), "snapshot_id" => result.fetch("snapshot_id"),
        "network_scope" => result.fetch("network_scope"), "counted_run" => false, "execution_authorized" => false
      }.merge(EXECUTION_HASH_BINDINGS.to_h { |key| [key, result.fetch(key)] })
    end

    def execution_payload_sha256(records)
      sums = records.sort.to_h { |name, bytes| [name, Digest::SHA256.hexdigest(bytes)] }
      Digest::SHA256.hexdigest(JSON.generate(sums))
    end

    def execution_output(run_id)
      raise CompleteReservesArtifactsError, "invalid complete reserves execution bundle" unless run_id.is_a?(String) && run_id.match?(/\Acal-a[0-9]{9}-o[0-9]{9}-r[0-9]{2}\z/)
      File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "executions", run_id)
    end

    def read_execution_file!(output, name)
      path = File.join(output, name)
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact" unless File.file?(path) && !File.symlink?(path)
      File.binread(path)
    end

    def verify_execution_sums!(output, records)
      bytes = read_execution_file!(output, "SHA256SUMS")
      expected = records.keys.sort.map { |name| "#{Digest::SHA256.hexdigest(records.fetch(name))}  #{name}\n" }.join
      raise CompleteReservesArtifactsError, "invalid complete reserves resume artifact" unless bytes == expected
    end

    def sha?(value); value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/); end
    def finite_nonnegative?(value); (value.is_a?(Integer) && value >= 0) || (value.is_a?(Float) && value.finite? && value >= 0); end

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
