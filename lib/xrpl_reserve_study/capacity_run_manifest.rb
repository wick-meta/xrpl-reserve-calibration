# frozen_string_literal: true

require "digest"
require "json"
require "time"

module XrplReserveStudy
  class CapacityRunManifestError < StudyError; end

  class CapacityRunManifest
    CONTROLLED_ERROR = "capacity run manifest failed"
    REPOSITORY_ROOT = File.expand_path("../..", __dir__)
    PROTOCOL_PATHS = {
      "document_sha256" => "docs/metrics-protocol-v1.md",
      "sample_schema_sha256" => "schemas/capacity-metric-sample-v1.schema.json",
      "summary_schema_sha256" => "schemas/capacity-metrics-summary-v1.schema.json"
    }.freeze
    PILOT_PROTOCOL_PATHS = {
      "protocol_sha256" => "capacity/pilot-protocol-v1.yml",
      "execution_schema_sha256" => "schemas/capacity-pilot-execution-v1.schema.json",
      "result_schema_sha256" => "schemas/capacity-pilot-result-v1.schema.json"
    }.freeze
    INPUT_SOURCE_PATHS = [
      "capacity/candidate-inputs.lock.json",
      "capacity/config/rippled.cfg",
      "study/reserve-calibration-v1.yml",
      "study/protocol-alignment-v1.yml",
      "capacity/pilot-protocol-v1.yml"
    ].freeze
    SOURCE_PATHS = (
      PROTOCOL_PATHS.values + PILOT_PROTOCOL_PATHS.values + INPUT_SOURCE_PATHS +
      ["schemas/capacity-run-manifest-v1.schema.json"]
    ).uniq.freeze
    SOURCE_PATTERN = /\A[0-9a-f]{40}\z/
    ENVIRONMENT_KEYS = CapacityEnvironmentProbe::ENVIRONMENT_KEYS

    class SourceControl
      def initialize(command_runner: CapacityEnvironmentProbe::CommandRunner.new)
        @command_runner = command_runner
      end

      def clean_head
        prefix = ["git", "-C", REPOSITORY_ROOT]
        first_status = @command_runner.call(prefix + ["status", "--porcelain=v1", "--untracked-files=no"])
        first_head = @command_runner.call(prefix + ["rev-parse", "--verify", "HEAD"]).strip
        second_status = @command_runner.call(prefix + ["status", "--porcelain=v1", "--untracked-files=no"])
        second_head = @command_runner.call(prefix + ["rev-parse", "--verify", "HEAD"]).strip
        unless first_status.empty? && second_status.empty? && first_head == second_head && first_head.match?(SOURCE_PATTERN)
          raise CapacityRunManifestError, "run manifest source verification failed"
        end
        first_head
      rescue CapacityRunManifestError
        raise
      rescue StandardError
        raise CapacityRunManifestError, "run manifest source verification failed"
      end

      def tracked_blob(commit:, path:)
        unless commit.is_a?(String) && commit.match?(SOURCE_PATTERN) && SOURCE_PATHS.include?(path)
          raise CapacityRunManifestError, "run manifest source verification failed"
        end
        @command_runner.call(["git", "-C", REPOSITORY_ROOT, "show", "#{commit}:#{path}"])
      rescue CapacityRunManifestError
        raise
      rescue StandardError
        raise CapacityRunManifestError, "run manifest source verification failed"
      end
    end

    def initialize(environment_probe: CapacityEnvironmentProbe.new, source_control: SourceControl.new,
                   clock: -> { Time.now.utc })
      @environment_probe = environment_probe
      @source_control = source_control
      @clock = clock
      @publisher = RuntimePublisher.new(error_class: CapacityRunManifestError, failure_label: "capacity run manifest")
    end

    def publish(run_id:, pilot_accounts:, config_dir:, workload_dir:, output_dir:)
      source_commit = @source_control.clean_head
      reject!("invalid source commit") unless source_commit.is_a?(String) && source_commit.match?(SOURCE_PATTERN)
      source_blobs = SOURCE_PATHS.to_h do |path|
        bytes = @source_control.tracked_blob(commit: source_commit, path: path)
        reject!("invalid source blob") unless bytes.is_a?(String)
        [path, bytes.dup.freeze]
      end.freeze
      locked_sources = INPUT_SOURCE_PATHS.to_h { |path| [path, source_blobs.fetch(path)] }
      locked = LockedCapacityInputs.new(error_class: CapacityRunManifestError, sources: locked_sources)
      study = locked.study
      CapacityMetrics::Reducer.new(study_data: study.data)
      inputs = CapacityRunInputs.new(locked_inputs: locked).load(
        run_id: run_id, config_dir: config_dir, workload_dir: workload_dir,
        expected_pilot_accounts: pilot_accounts
      )
      environment = @environment_probe.capture
      validate_environment!(environment)
      created_at = @clock.call
      reject!("manifest clock must return UTC time") unless created_at.is_a?(Time) && created_at.utc?
      manifest = build_manifest(inputs, source_commit, source_blobs, locked, study, environment, created_at)
      deep_freeze(manifest)
      @publisher.publish(output_dir) do |staging|
        staging.write("run-manifest.json", "#{JSON.pretty_generate(manifest)}\n")
        sha256 = staging.sha256("run-manifest.json")
        staging.write("SHA256SUMS", "#{sha256}  run-manifest.json\n")
        confirmed_commit = @source_control.clean_head
        reject!("source tree changed during manifest construction") unless confirmed_commit == source_commit
      end
      manifest
    rescue StandardError
      raise CapacityRunManifestError, CONTROLLED_ERROR
    end

    private

    def build_manifest(inputs, source_commit, source_blobs, locked, study, environment, created_at)
      run = inputs.fetch("run")
      protocol_reference = study.data.fetch("protocol_reference")
      {
        "schema_version" => "capacity-run-manifest-v1",
        "manifest_scope" => "non-counted-pilot",
        "counted_run" => false,
        "pilot_complete" => false,
        "study_id" => study.data.fetch("study_id"),
        "study_sha256" => locked.input_sha256.fetch("study/reserve-calibration-v1.yml"),
        "source_commit" => source_commit,
        "run_id" => run.fetch("run_id"),
        "run_order_index" => run_order_index(study, run.fetch("run_id")),
        "base_reserve_xrp" => run.fetch("base_reserve_xrp"),
        "base_reserve_drops" => (run.fetch("base_reserve_xrp") * 1_000_000).round,
        "planned_account_count" => run.fetch("account_count"),
        "generated_account_count" => inputs.fetch("generated_account_count"),
        "repetition" => run.fetch("repetition"),
        "network_id" => WorkloadGenerator::NETWORK_ID,
        "workload_name" => study.data.fetch("workload").fetch("name"),
        "warmup_seconds" => study.data.fetch("workload").fetch("warmup_seconds"),
        "measurement_seconds" => study.data.fetch("workload").fetch("measurement_seconds"),
        "inputs" => {
          "config_sha256" => inputs.fetch("config_sha256"),
          "accounts_sha256" => inputs.fetch("accounts_sha256"),
          "workload_manifest_sha256" => inputs.fetch("workload_sha256").fetch("manifest.json")
        },
        "candidate_runtime" => {
          "build_version" => "3.3.0",
          "image_digest" => CapacityEnvironmentProbe::IMAGE_DIGEST,
          "network_id" => WorkloadGenerator::NETWORK_ID,
          "memory_limit_bytes" => CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES,
          "allocated_logical_cpus" => CapacityMetrics::Reducer::ALLOCATED_LOGICAL_CPUS
        },
        "preregistered_protocol_reference" => {
          "implementation_release" => protocol_reference.fetch("implementation_release"),
          "implementation_commit" => protocol_reference.fetch("implementation_commit")
        },
        "protocol_alignment" => protocol_alignment(locked, source_blobs),
        "pilot_protocol" => pilot_protocol(locked, source_blobs),
        "metric_protocol" => { "version" => "capacity-metrics-protocol-v1" }.merge(protocol_hashes(source_blobs)),
        "metric_names" => deep_copy(study.data.fetch("metrics")),
        "acceptance_thresholds" => deep_copy(study.data.fetch("acceptance_thresholds")),
        "abort_rules" => deep_copy(study.data.fetch("abort_rules")),
        "environment" => deep_copy(environment),
        "created_at" => created_at.iso8601(6)
      }
    end

    def run_order_index(study, run_id)
      index = study.plan.fetch("runs").index { |run| run.fetch("run_id") == run_id }
      reject!("unknown planned run") unless index
      index + 1
    end

    def protocol_hashes(source_blobs)
      PROTOCOL_PATHS.to_h do |name, path|
        [name, Digest::SHA256.hexdigest(source_blobs.fetch(path))]
      end
    end

    def protocol_alignment(locked, source_blobs)
      alignment = locked.protocol_alignment.data
      resolution = alignment.fetch("resolution")
      {
        "status" => alignment.fetch("status"),
        "method" => resolution.fetch("method"),
        "alignment_sha256" => Digest::SHA256.hexdigest(
          source_blobs.fetch("study/protocol-alignment-v1.yml")
        ),
        "implementation_equivalence_claimed" => resolution.fetch("implementation_equivalence_claimed"),
        "cross_version_pooling_allowed" => resolution.fetch("cross_version_pooling_allowed"),
        "cross_version_generalization_allowed" => resolution.fetch("cross_version_generalization_allowed"),
        "counted_execution_authorized" => resolution.fetch("counted_execution_authorized"),
        "remaining_gates" => deep_copy(alignment.fetch("remaining_gates"))
      }
    end

    def pilot_protocol(locked, source_blobs)
      deep_copy(locked.pilot_protocol.data).merge(
        PILOT_PROTOCOL_PATHS.to_h do |name, path|
          [name, Digest::SHA256.hexdigest(source_blobs.fetch(path))]
        end
      )
    end

    def validate_environment!(environment)
      reject!("invalid capacity environment") unless
        environment.is_a?(Hash) && environment.keys.sort == ENVIRONMENT_KEYS.sort
      reject!("invalid capacity environment") unless
        environment.fetch("candidate_image_digest") == CapacityEnvironmentProbe::IMAGE_DIGEST
      reject!("invalid capacity environment") unless
        %w[amd64 arm64].include?(environment.fetch("host_architecture")) &&
        %w[amd64 arm64].include?(environment.fetch("candidate_image_architecture")) &&
        %w[linux docker-desktop].include?(environment.fetch("host_operating_system"))
      reject!("invalid capacity environment") unless
        environment.fetch("docker_server_version").is_a?(String) &&
        environment.fetch("docker_server_version").match?(/\A[0-9A-Za-z.+-]{1,64}\z/) &&
        positive_integer?(environment.fetch("host_logical_cpus")) &&
        positive_integer?(environment.fetch("host_memory_bytes"))
      eligible = environment.fetch("host_architecture") == environment.fetch("candidate_image_architecture")
      reject!("invalid capacity environment") unless environment.fetch("native_architecture_eligible") == eligible
    rescue KeyError, TypeError
      reject!("invalid capacity environment")
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive? && value <= (2**63) - 1
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!(message)
      raise CapacityRunManifestError, message
    end
  end
end
