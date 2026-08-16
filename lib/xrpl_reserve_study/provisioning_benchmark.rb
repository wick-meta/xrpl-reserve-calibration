# frozen_string_literal: true

require "digest"
require "json"
require_relative "capacity_metrics"

module XrplReserveStudy
  class ProvisioningBenchmarkError < StudyError; end

  class ProvisioningBenchmark
    REQUIRED_TARGETS = [10_000, 25_000, 50_000].freeze
    OPTIONAL_TARGETS = [1_000_000].freeze
    ONE_MILLION_NOT_MEASURED_REASONS = %w[
      not-yet-executed operator-resource-limit calibration-failed
    ].freeze
    TIMED_FLOOR_SECONDS = 252_000
    SHA256 = /\A[0-9a-f]{64}\z/
    SAMPLE_KEYS = (%w[
      schema_version profile_id profile_sha256 distribution_sha256 candidate_sha256
      account_root_target owned_object_target measurement_source network_scope counted_run
    ] + CapacityMetrics::PROVISIONING_METRIC_NAMES + %w[snapshot_sha256 artifact_sha256]).freeze

    def initialize(distribution:, distribution_sha256:, candidate_sha256:, profile_path: CompleteReservesProfile::PATH)
      @distribution = validate_distribution!(distribution)
      @distribution_sha256 = sha256!(distribution_sha256)
      @candidate_sha256 = sha256!(candidate_sha256)
      @profile_path = profile_path
      @profile_sha256 = Digest::SHA256.file(profile_path).hexdigest
      @profiles = CompleteReservesProfile.new(profile_path)
      @expected_full = @profiles.full_matrix_cells(distribution: @distribution)
    rescue SystemCallError
      reject!
    end

    def estimate_full(profile:, samples:, one_million_checkpoint: nil)
      reject! unless profile == @expected_full
      ordered_samples = validate_samples!(samples)
      one_million = validate_one_million_checkpoint!(one_million_checkpoint, ordered_samples)
      rates = ordered_samples.map { |sample| provisioning_seconds(sample).fdiv(population_work(sample)) }
      projections = profile.map do |cell|
        work = cell.fetch("account_root_target") + cell.fetch("owned_object_target")
        deep_freeze(
          "run_id" => cell.fetch("run_id"),
          "program" => cell.fetch("program"),
          "scale" => cell.fetch("scale"),
          "repetition" => cell.fetch("repetition"),
          "account_root_target" => cell.fetch("account_root_target"),
          "owned_object_target" => cell.fetch("owned_object_target"),
          "population_work_units" => work,
          "estimate_kind" => "non-binding-extrapolation",
          "provisioning_seconds_range" => {
            "minimum" => (rates.min * work).ceil,
            "maximum" => (rates.max * work).ceil
          }
        )
      end
      checkpoints = REQUIRED_TARGETS.map do |target|
        sample = ordered_samples.find { |entry| entry.fetch("account_root_target") == target }
        {
          "account_root_target" => target,
          "owned_object_target" => (@distribution.fetch("owned_objects") * target.fdiv(@distribution.fetch("account_roots"))).ceil,
          "measurement_status" => "measured",
          "artifact_sha256" => sample.fetch("artifact_sha256")
        }
      end
      checkpoints << one_million
      result = {
        "schema_version" => "complete-reserves-provisioning-estimate-v1",
        "profile_id" => "complete-reserves-full-matrix-v1",
        "profile_sha256" => @profile_sha256,
        "distribution_sha256" => @distribution_sha256,
        "candidate_sha256" => @candidate_sha256,
        "calibration_samples_sha256" => canonical_sha256(ordered_samples),
        "measured_account_root_targets" => ordered_samples.map { |sample| sample.fetch("account_root_target") },
        "one_million_checkpoint" => one_million,
        "planning_checkpoints" => checkpoints,
        "timed_floor_seconds" => TIMED_FLOOR_SECONDS,
        "timed_floor_status" => "fixed-profile-minimum",
        "provisioning_bounded" => false,
        "provisioning_seconds" => nil,
        "completion_seconds" => nil,
        "estimate_status" => "measured-calibrated-extrapolation",
        "measured_samples" => deep_copy(ordered_samples),
        "resource_requirements" => resource_requirements(ordered_samples),
        "projections" => projections,
        "network_scope" => "isolated-network-only",
        "counted_run" => false,
        "execution_authorized" => false
      }
      result["benchmark_sha256"] = canonical_sha256(result)
      deep_freeze(deep_copy(result))
    rescue KeyError, TypeError
      reject!
    end

    private

    def validate_distribution!(distribution)
      valid = distribution.is_a?(Hash) && distribution.keys.sort == %w[account_roots owned_objects] &&
        distribution.values.all? { |value| value.is_a?(Integer) && value.positive? }
      reject! unless valid
      distribution.dup.freeze
    end

    def validate_samples!(samples)
      reject! unless samples.is_a?(Array) && !samples.empty?
      ordered = samples.sort_by { |sample| sample.is_a?(Hash) ? sample["account_root_target"].to_i : -1 }
      targets = ordered.map { |sample| sample.is_a?(Hash) ? sample["account_root_target"] : nil }
      reject! unless targets.uniq == targets && (targets - REQUIRED_TARGETS - OPTIONAL_TARGETS).empty?
      reject! unless (REQUIRED_TARGETS - targets).empty?
      ordered.each { |sample| validate_sample!(sample) }
      %w[snapshot_sha256 artifact_sha256].each do |key|
        hashes = ordered.map { |sample| sample.fetch(key) }
        reject! unless hashes.uniq.length == hashes.length
      end
      ordered.freeze
    end

    def validate_sample!(sample)
      reject! unless sample.is_a?(Hash) && sample.keys.all? { |key| key.is_a?(String) } && sample.keys.sort == SAMPLE_KEYS.sort
      reject! unless sample.fetch("schema_version") == "complete-reserves-provisioning-sample-v1"
      reject! unless sample.fetch("profile_id") == "complete-reserves-calibrated-v1"
      reject! unless sample.fetch("profile_sha256") == @profile_sha256
      reject! unless sample.fetch("distribution_sha256") == @distribution_sha256
      reject! unless sample.fetch("candidate_sha256") == @candidate_sha256
      reject! unless sample.fetch("measurement_source") == "observed"
      reject! unless sample.fetch("network_scope") == "isolated-network-only"
      reject! unless sample.fetch("counted_run") == false
      reject! unless positive_integer?(sample.fetch("account_root_target")) && positive_integer?(sample.fetch("owned_object_target"))
      expected_objects = (@distribution.fetch("owned_objects") * sample.fetch("account_root_target").fdiv(@distribution.fetch("account_roots"))).ceil
      reject! unless sample.fetch("owned_object_target") == expected_objects

      %w[build_wall_seconds snapshot_wall_seconds clone_wall_seconds reset_wall_seconds recovery_wall_seconds cpu_seconds ledger_close_seconds_p95 finality_seconds_p95].each do |key|
        reject! unless finite_positive_numeric?(sample.fetch(key))
      end
      %w[allocated_logical_cpus peak_memory_bytes state_disk_bytes io_read_bytes io_write_bytes attempted_transactions burned_fees_drops locked_xrp_drops ledger_growth_bytes database_growth_bytes].each do |key|
        reject! unless positive_integer?(sample.fetch(key))
      end
      %w[validated_transactions released_xrp_drops max_queue_depth].each do |key|
        reject! unless nonnegative_integer?(sample.fetch(key))
      end
      reject! unless sample.fetch("validated_transactions") <= sample.fetch("attempted_transactions")
      reject! unless sample.fetch("released_xrp_drops") <= sample.fetch("locked_xrp_drops")
      reject! unless sample.fetch("reset_confirmed") == true && sample.fetch("recovery_confirmed") == true
      sha256!(sample.fetch("snapshot_sha256"))
      sha256!(sample.fetch("artifact_sha256"))
    end

    def validate_one_million_checkpoint!(checkpoint, samples)
      reject! unless checkpoint.is_a?(Hash) && checkpoint.keys.all? { |key| key.is_a?(String) }
      reject! unless checkpoint.fetch("account_root_target") == 1_000_000
      expected_objects = (@distribution.fetch("owned_objects") * 1_000_000.fdiv(@distribution.fetch("account_roots"))).ceil
      reject! unless checkpoint.fetch("owned_object_target") == expected_objects
      measured = samples.find { |sample| sample.fetch("account_root_target") == 1_000_000 }
      case checkpoint.fetch("measurement_status")
      when "measured"
        reject! unless checkpoint.keys.sort == %w[account_root_target artifact_sha256 measurement_status owned_object_target].sort
        reject! unless measured && checkpoint.fetch("artifact_sha256") == measured.fetch("artifact_sha256")
      when "not_measured"
        reject! unless checkpoint.keys.sort == %w[account_root_target measurement_status owned_object_target reason].sort
        reject! if measured
        reject! unless ONE_MILLION_NOT_MEASURED_REASONS.include?(checkpoint.fetch("reason"))
      else
        reject!
      end
      deep_freeze(deep_copy(checkpoint))
    rescue KeyError, TypeError
      reject!
    end

    def resource_requirements(samples)
      {
        "derivation" => "observed-calibration-maxima-no-headroom",
        "logical_cpus" => samples.map { |sample| sample.fetch("allocated_logical_cpus") }.max,
        "memory_bytes" => samples.map { |sample| sample.fetch("peak_memory_bytes") }.max,
        "disk_bytes" => samples.map { |sample| sample.fetch("state_disk_bytes") }.max,
        "io_read_bytes_per_second" => samples.map { |sample| sample.fetch("io_read_bytes").fdiv(sample.fetch("build_wall_seconds")) }.max.ceil,
        "io_write_bytes_per_second" => samples.map { |sample| sample.fetch("io_write_bytes").fdiv(sample.fetch("build_wall_seconds")) }.max.ceil,
        "ledger_close_seconds_p95_observed" => samples.map { |sample| sample.fetch("ledger_close_seconds_p95") }.max
      }
    end

    def provisioning_seconds(sample)
      %w[build_wall_seconds snapshot_wall_seconds clone_wall_seconds reset_wall_seconds recovery_wall_seconds].sum { |key| sample.fetch(key) }
    end

    def population_work(sample)
      sample.fetch("account_root_target") + sample.fetch("owned_object_target")
    end

    def canonical_sha256(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def sha256!(value)
      reject! unless value.is_a?(String) && value.match?(SHA256)
      value.dup.freeze
    end

    def finite_positive_numeric?(value)
      value.is_a?(Numeric) && value.finite? && value.positive?
    rescue NoMethodError
      false
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def nonnegative_integer?(value)
      value.is_a?(Integer) && value >= 0
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise ProvisioningBenchmarkError, "invalid provisioning benchmark"
    end
  end
end
