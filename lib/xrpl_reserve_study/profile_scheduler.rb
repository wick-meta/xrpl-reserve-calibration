# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class ProfileSchedulerError < StudyError; end

  class ProfileScheduler
    SHA256 = /\A[0-9a-f]{64}\z/
    RESOURCE_KEYS = %w[logical_cpus memory_bytes free_disk_bytes io_read_bytes_per_second io_write_bytes_per_second].freeze
    RESUME_KEYS = %w[run_id schedule_item_sha256 result_artifact_sha256 reset_confirmed recovery_confirmed].freeze

    def initialize(distribution:, distribution_sha256:, candidate_sha256:, profile_path: CompleteReservesProfile::PATH)
      @distribution = Marshal.load(Marshal.dump(distribution)).freeze
      @distribution_sha256 = distribution_sha256.dup.freeze
      @candidate_sha256 = candidate_sha256.dup.freeze
      @profile_path = profile_path
      @profile_sha256 = Digest::SHA256.file(profile_path).hexdigest
      @expected_profile = CompleteReservesProfile.new(profile_path).full_matrix_cells(distribution: distribution)
      reject! unless valid_sha?(@distribution_sha256) && valid_sha?(@candidate_sha256)
    rescue SystemCallError, CompleteReservesProfileError
      reject!
    end

    def schedule(profile:, benchmark:, available_resources:, resume_records: [])
      reject! unless profile == @expected_profile
      validate_benchmark!(benchmark)
      validate_resources!(available_resources, benchmark.fetch("resource_requirements"))
      records = validate_resume_records!(resume_records)
      base_items = profile.each_with_index.map { |cell, index| build_item(cell, index + 1, benchmark) }
      items = base_items.map { |item| apply_resume(item, records) }
      reject! unless records.empty?
      result = {
        "schema_version" => "complete-reserves-profile-schedule-v1",
        "profile_id" => "complete-reserves-full-matrix-v1",
        "profile_sha256" => @profile_sha256,
        "distribution_sha256" => @distribution_sha256,
        "candidate_sha256" => @candidate_sha256,
        "benchmark_sha256" => benchmark.fetch("benchmark_sha256"),
        "timed_floor_seconds" => ProvisioningBenchmark::TIMED_FLOOR_SECONDS,
        "provisioning_time_status" => "unbounded",
        "completion_seconds" => nil,
        "planning_checkpoints" => benchmark.fetch("planning_checkpoints"),
        "resource_requirements" => benchmark.fetch("resource_requirements"),
        "pending_count" => items.count { |item| item.fetch("status") == "pending" },
        "resumed_count" => items.count { |item| item.fetch("status") == "resumed-complete" },
        "network_scope" => "isolated-network-only",
        "counted_run" => false,
        "execution_authorized" => false,
        "items" => items
      }
      result["schedule_sha256"] = canonical_sha256(result)
      deep_freeze(result)
    rescue KeyError, TypeError
      reject!
    end

    private

    def validate_benchmark!(benchmark)
      reject! unless benchmark.is_a?(Hash)
      reject! unless benchmark.fetch("schema_version") == "complete-reserves-provisioning-estimate-v1"
      reject! unless benchmark.fetch("profile_id") == "complete-reserves-full-matrix-v1"
      reject! unless benchmark.fetch("profile_sha256") == @profile_sha256
      reject! unless benchmark.fetch("distribution_sha256") == @distribution_sha256
      reject! unless benchmark.fetch("candidate_sha256") == @candidate_sha256
      reject! unless benchmark.fetch("timed_floor_seconds") == ProvisioningBenchmark::TIMED_FLOOR_SECONDS
      reject! unless benchmark.fetch("provisioning_bounded") == false && benchmark.fetch("provisioning_seconds").nil? && benchmark.fetch("completion_seconds").nil?
      reject! unless benchmark.fetch("counted_run") == false && benchmark.fetch("execution_authorized") == false
      expected = canonical_sha256(benchmark.reject { |key, _| key == "benchmark_sha256" })
      reject! unless benchmark.fetch("benchmark_sha256") == expected
      regenerated = ProvisioningBenchmark.new(
        distribution: @distribution,
        distribution_sha256: @distribution_sha256,
        candidate_sha256: @candidate_sha256,
        profile_path: @profile_path
      ).estimate_full(profile: @expected_profile, samples: benchmark.fetch("measured_samples"))
      reject! unless benchmark == regenerated
    rescue ProvisioningBenchmarkError
      reject!
    end

    def validate_resources!(available, required)
      reject! unless available.is_a?(Hash) && available.keys.sort == RESOURCE_KEYS.sort
      reject! unless required.is_a?(Hash)
      comparisons = {
        "logical_cpus" => required.fetch("logical_cpus"),
        "memory_bytes" => required.fetch("memory_bytes"),
        "free_disk_bytes" => required.fetch("disk_bytes"),
        "io_read_bytes_per_second" => required.fetch("io_read_bytes_per_second"),
        "io_write_bytes_per_second" => required.fetch("io_write_bytes_per_second")
      }
      comparisons.each do |name, minimum|
        value = available.fetch(name)
        reject! unless value.is_a?(Integer) && value.positive? && value >= minimum
      end
    end

    def validate_resume_records!(records)
      reject! unless records.is_a?(Array)
      mapped = {}
      records.each do |record|
        reject! unless record.is_a?(Hash) && record.keys.sort == RESUME_KEYS.sort
        reject! unless record.fetch("run_id").is_a?(String) && !record.fetch("run_id").empty?
        reject! unless valid_sha?(record.fetch("schedule_item_sha256")) && valid_sha?(record.fetch("result_artifact_sha256"))
        reject! unless record.fetch("reset_confirmed") == true && record.fetch("recovery_confirmed") == true
        reject! if mapped.key?(record.fetch("run_id"))
        mapped[record.fetch("run_id")] = record
      end
      mapped
    end

    def build_item(cell, ordinal, benchmark)
      projection = benchmark.fetch("projections").find { |entry| entry.fetch("run_id") == cell.fetch("run_id") }
      reject! unless projection
      item = cell.merge(
        "schedule_ordinal" => ordinal,
        "profile_id" => "complete-reserves-full-matrix-v1",
        "profile_sha256" => @profile_sha256,
        "distribution_sha256" => @distribution_sha256,
        "candidate_sha256" => @candidate_sha256,
        "benchmark_sha256" => benchmark.fetch("benchmark_sha256"),
        "execution_mode" => "exclusive",
        "destructive_resource" => "isolated-ledger-state",
        "reset_required" => true,
        "recovery_required" => true,
        "result_artifact_sha256_required" => true,
        "provisioning_estimate" => projection.fetch("provisioning_seconds_range"),
        "estimate_kind" => "non-binding-extrapolation",
        "network_scope" => "isolated-network-only",
        "counted_run" => false,
        "execution_authorized" => false,
        "status" => "pending"
      )
      item["schedule_item_sha256"] = canonical_sha256(item)
      deep_freeze(item)
    end

    def apply_resume(item, records)
      record = records.delete(item.fetch("run_id"))
      return item unless record
      reject! unless record.fetch("schedule_item_sha256") == item.fetch("schedule_item_sha256")
      deep_freeze(item.merge("status" => "resumed-complete", "result_artifact_sha256" => record.fetch("result_artifact_sha256")))
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

    def valid_sha?(value)
      value.is_a?(String) && value.match?(SHA256)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise ProfileSchedulerError, "invalid complete reserves schedule"
    end
  end
end
