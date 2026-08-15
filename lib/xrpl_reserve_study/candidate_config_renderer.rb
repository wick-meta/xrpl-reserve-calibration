# frozen_string_literal: true

require "digest"
module XrplReserveStudy
  class CandidateConfigError < StudyError; end

  class CandidateConfigRenderer
    ACCOUNT_RESERVE_ASSIGNMENT = /^([ \t]*account_reserve[ \t]*=[ \t]*)(\d+)([ \t]*(?:\r?\n|\z))/.freeze
    COMMITTED_STUDY_PATH = LockedCapacityInputs::COMMITTED_STUDY_PATH
    CANONICAL_CONFIG_PATH = LockedCapacityInputs::CANONICAL_CONFIG_PATH
    INPUT_LOCK_PATH = LockedCapacityInputs::INPUT_LOCK_PATH
    RUNTIME_ROOT = RuntimePublisher::RUNTIME_ROOT
    INPUT_PATHS = LockedCapacityInputs::INPUT_PATHS

    def initialize(inputs: nil)
      inputs ||= LockedCapacityInputs.new(error_class: CandidateConfigError)
      @input_sha256 = inputs.input_sha256
      @study = inputs.study
      @canonical_config = inputs.verified_inputs.fetch("capacity/config/rippled.cfg")
      @publisher = RuntimePublisher.new(
        error_class: CandidateConfigError,
        failure_label: "candidate configuration"
      )
    end

    def render(run_id:, output_dir:)
      expected = expected(run_id: run_id)
      rendered_config = expected.fetch("config_bytes")
      rendered_sha256 = @publisher.publish(output_dir) do |staging|
        staging.write("rippled.cfg", rendered_config)
        staging.sha256("rippled.cfg")
      end
      make_config_mount_traversable!(output_dir)

      {
        "run_id" => expected.fetch("run_id"),
        "base_reserve_xrp" => expected.fetch("base_reserve_xrp"),
        "base_reserve_drops" => expected.fetch("base_reserve_drops"),
        "account_count" => expected.fetch("account_count"),
        "repetition" => expected.fetch("repetition"),
        "relative_config_path" => "rippled.cfg",
        "sha256" => rendered_sha256,
        "input_sha256" => @input_sha256
      }
    end

    def expected(run_id:)
      run = planned_run(run_id)
      reserve_drops = (run.fetch("base_reserve_xrp") * 1_000_000).round
      bytes = render_config(@canonical_config, reserve_drops)
      {
        "config_bytes" => bytes,
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "run_id" => run.fetch("run_id"),
        "base_reserve_xrp" => run.fetch("base_reserve_xrp"),
        "base_reserve_drops" => reserve_drops,
        "account_count" => run.fetch("account_count"),
        "repetition" => run.fetch("repetition")
      }
    end

    private

    def make_config_mount_traversable!(output_dir)
      # The candidate container runs as UID 997. RuntimePublisher keeps its
      # directories at 0700 by default; the rendered configuration is public
      # candidate input, so expose only the two directories needed to traverse
      # the read-only bind mount. Workload, manifest, and execution directories
      # retain their private 0700 mode.
      File.chmod(0o755, File.dirname(output_dir), output_dir)
    rescue SystemCallError => error
      raise CandidateConfigError, "could not expose candidate configuration: #{error.message}"
    end

    def planned_run(run_id)
      run = @study.plan.fetch("runs").find { |candidate| candidate.fetch("run_id") == run_id }
      raise CandidateConfigError, "unknown planned run ID: #{run_id}" unless run

      run
    end

    def render_config(canonical, reserve_drops)
      assignments = canonical.scan(ACCOUNT_RESERVE_ASSIGNMENT)
      unless assignments.length == 1
        raise CandidateConfigError,
              "canonical configuration must contain exactly one account_reserve assignment (found #{assignments.length})"
      end

      canonical.sub(ACCOUNT_RESERVE_ASSIGNMENT) do
        "#{Regexp.last_match(1)}#{reserve_drops}#{Regexp.last_match(3)}"
      end
    end

  end
end
