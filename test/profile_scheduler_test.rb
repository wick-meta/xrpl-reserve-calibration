# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class ProfileSchedulerTest < Minitest::Test
  include CompleteReservesPlanningFixture

  # Break caught: reordering, dropping, or parallelizing destructive full
  # matrix cells and thereby comparing non-equivalent state.
  def test_full_schedule_preserves_all_frozen_cells_in_exclusive_order
    result = schedule
    items = result.fetch("items")

    assert_equal 120, items.length
    assert_equal XrplReserveStudy::CompleteReservesStudy::RUN_ORDER_SHA256,
                 Digest::SHA256.hexdigest(items.map { |item| item.fetch("run_id") }.join("\n"))
    assert_equal({ "base" => 48, "owner" => 48, "combined" => 24 }, items.group_by { |item| item.fetch("program") }.transform_values(&:length))
    assert_equal [1.0, 1.25, 1.5, 2.0], items.select { |item| item.fetch("program") != "combined" }.map { |item| item.fetch("scale") }.uniq.sort
    assert_equal [1.5, 2.0], items.select { |item| item.fetch("program") == "combined" }.map { |item| item.fetch("scale") }.uniq.sort
    assert items.all? { |item| item.fetch("execution_mode") == "exclusive" }
    assert items.all? { |item| item.fetch("destructive_resource") == "isolated-ledger-state" }
    assert items.all? { |item| item.fetch("reset_required") && item.fetch("recovery_required") }
    assert_equal false, result.fetch("execution_authorized")
    assert_equal false, result.fetch("counted_run")
  end

  # Break caught: allowing an operator to start a schedule below resource
  # levels actually observed by the calibration.
  def test_rejects_insufficient_cpu_ram_disk_or_io_capacity
    %w[logical_cpus memory_bytes free_disk_bytes io_read_bytes_per_second io_write_bytes_per_second].each do |name|
      resources = available_resources.dup
      resources[name] = 0
      assert_raises(XrplReserveStudy::ProfileSchedulerError, name) do
        scheduler.schedule(profile: full_profile, benchmark: estimate, available_resources: resources)
      end
    end
  end

  # Break caught: trusting a self-consistent hash on a benchmark whose
  # measured resource requirement was lowered after calibration.
  def test_rejects_rehashed_but_semantically_forged_benchmark
    forged = Marshal.load(Marshal.dump(estimate))
    forged.fetch("resource_requirements")["memory_bytes"] = 1
    forged["benchmark_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(forged.reject { |key, _| key == "benchmark_sha256" })))

    assert_raises(XrplReserveStudy::ProfileSchedulerError) do
      scheduler.schedule(profile: full_profile, benchmark: forged, available_resources: available_resources)
    end
  end

  # Break caught: trusting a run-id-only resume marker or resuming work whose
  # reset/recovery and artifact bindings were not proven.
  def test_resume_requires_exact_item_and_result_hashes_plus_reset_and_recovery
    first = schedule
    item = first.fetch("items").first
    record = {
      "run_id" => item.fetch("run_id"),
      "schedule_item_sha256" => item.fetch("schedule_item_sha256"),
      "result_artifact_sha256" => "e" * 64,
      "reset_confirmed" => true,
      "recovery_confirmed" => true
    }
    resumed = scheduler.schedule(
      profile: full_profile,
      benchmark: estimate,
      available_resources: available_resources,
      resume_records: [record]
    )

    assert_equal 1, resumed.fetch("resumed_count")
    assert_equal 119, resumed.fetch("pending_count")
    assert_equal "resumed-complete", resumed.fetch("items").first.fetch("status")
    assert_equal "e" * 64, resumed.fetch("items").first.fetch("result_artifact_sha256")

    record["schedule_item_sha256"] = "f" * 64
    assert_raises(XrplReserveStudy::ProfileSchedulerError) do
      scheduler.schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources, resume_records: [record])
    end

    unknown = record.merge("run_id" => "not-a-frozen-run", "schedule_item_sha256" => item.fetch("schedule_item_sha256"))
    assert_raises(XrplReserveStudy::ProfileSchedulerError) do
      scheduler.schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources, resume_records: [unknown])
    end
  end

  # Break caught: silently losing the operator planning checkpoints or
  # presenting a projected one-million population as measured.
  def test_schedule_carries_calibration_and_one_million_checkpoint_status
    result = schedule

    assert_equal [10_000, 25_000, 50_000, 1_000_000], result.fetch("planning_checkpoints").map { |entry| entry.fetch("account_root_target") }
    assert result.fetch("planning_checkpoints").all? { |entry| entry.fetch("measurement_status") == "measured" }
    assert_equal "unbounded", result.fetch("provisioning_time_status")
    assert_nil result.fetch("completion_seconds")
  end


  # Break caught: accepting a self-hashed benchmark/schedule after its required
  # explicit 1m disposition was removed.
  def test_rejects_benchmark_without_explicit_one_million_disposition
    forged = Marshal.load(Marshal.dump(estimate))
    forged.delete("one_million_checkpoint")
    forged["planning_checkpoints"].pop
    forged["benchmark_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(forged.reject { |key, _| key == "benchmark_sha256" })))

    assert_raises(XrplReserveStudy::ProfileSchedulerError) do
      scheduler.schedule(profile: full_profile, benchmark: forged, available_resources: available_resources)
    end
  end

  # Break caught: later caller mutation changing the scheduler's bound
  # distribution or hashes after construction.
  def test_constructor_copies_identity_bindings
    distribution = DISTRIBUTION.dup
    distribution_sha256 = DISTRIBUTION_SHA256.dup
    candidate_sha256 = CANDIDATE_SHA256.dup
    instance = XrplReserveStudy::ProfileScheduler.new(
      distribution: distribution,
      distribution_sha256: distribution_sha256,
      candidate_sha256: candidate_sha256,
      profile_path: PROFILE_PATH
    )
    distribution["account_roots"] = 1
    distribution_sha256.replace("a" * 64)
    candidate_sha256.replace("b" * 64)

    result = instance.schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)
    assert_equal DISTRIBUTION_SHA256, result.fetch("distribution_sha256")
    assert_equal CANDIDATE_SHA256, result.fetch("candidate_sha256")
  end

  private

  def scheduler
    XrplReserveStudy::ProfileScheduler.new(
      distribution: DISTRIBUTION,
      distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256,
      profile_path: PROFILE_PATH
    )
  end

  def schedule
    scheduler.schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)
  end

  def full_profile
    XrplReserveStudy::CompleteReservesProfile.new(PROFILE_PATH).full_matrix_cells(distribution: DISTRIBUTION)
  end

  def estimate
    benchmark_estimate
  end

  def available_resources
    {
      "logical_cpus" => 8,
      "memory_bytes" => 64_000_000_000,
      "free_disk_bytes" => 128_000_000_000,
      "io_read_bytes_per_second" => 1_000_000_000,
      "io_write_bytes_per_second" => 1_000_000_000
    }
  end


  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
end
