# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class CompleteReservesArtifactsTest < Minitest::Test
  include CompleteReservesPlanningFixture
  def test_rejects_sensitive_or_incomplete_result_before_publication
    artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
    result = { "run_id" => "cr-test", "status" => "passed", "counted_run" => false, "distribution_sha256" => "a" * 64,
               "snapshot_id" => "snapshot", "object_counts_by_class" => { "offer" => 1 }, "locked_xrp_drops" => 1,
               "released_xrp_drops" => 1, "owner_count_lifecycle" => [0, 1, 0] }
    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) { artifacts.publish_disposition(result: result.merge("secret" => "no"), summary: {}) }
  end


  # Break caught: publishing scheduler/security evidence without verifying its
  # benchmark hash chain or producing checksums for every planning artifact.
  def test_publishes_hash_bound_non_counted_planning_bundle_atomically
    estimate = benchmark.estimate_full(profile: full_profile, samples: measured_samples)
    schedule = XrplReserveStudy::ProfileScheduler.new(
      distribution: DISTRIBUTION,
      distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256,
      profile_path: PROFILE_PATH
    ).schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)
    security = XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: security_baseline, observed: security_observed)

    published = XrplReserveStudy::CompleteReservesArtifacts.new.publish_planning_bundle(
      benchmark: estimate,
      schedule: schedule,
      security: security
    )
    output = published.fetch("output_dir")

    assert_equal %w[SHA256SUMS benchmark.json schedule.json security.json], Dir.children(output).sort
    assert_equal Digest::SHA256.file(File.join(output, "benchmark.json")).hexdigest,
                 published.dig("artifact_sha256", "benchmark.json")
    assert_equal 3, File.readlines(File.join(output, "SHA256SUMS")).length
  ensure
    FileUtils.rm_rf(output) if output&.start_with?(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT + File::SEPARATOR)
  end

  # Break caught: accepting a schedule detached from the measured benchmark.
  def test_rejects_changed_planning_hash_chain_before_publication
    estimate = benchmark.estimate_full(profile: full_profile, samples: measured_samples)
    schedule = XrplReserveStudy::ProfileScheduler.new(
      distribution: DISTRIBUTION,
      distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256,
      profile_path: PROFILE_PATH
    ).schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)

    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) do
      XrplReserveStudy::CompleteReservesArtifacts.new.publish_planning_bundle(
        benchmark: estimate,
        schedule: schedule.merge("benchmark_sha256" => "f" * 64),
        security: XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: security_baseline, observed: security_observed)
      )
    end
  end

  private

  def available_resources
    {
      "logical_cpus" => 8,
      "memory_bytes" => 64_000_000_000,
      "free_disk_bytes" => 128_000_000_000,
      "io_read_bytes_per_second" => 1_000_000_000,
      "io_write_bytes_per_second" => 1_000_000_000
    }
  end

  def security_baseline
    security_observed.merge(
      "workload_id" => "baseline",
      "ledger_close_seconds_p95" => 2.0,
      "peak_memory_bytes" => 400,
      "cpu_utilization_ratio" => 0.25,
      "io_wait_ratio" => 0.05,
      "max_queue_depth" => 2,
      "finality_seconds_p95" => 3.0
    )
  end

  def security_observed
    {
      "workload_id" => "mixed",
      "profile_id" => "complete-reserves-calibrated-v1",
      "profile_sha256" => Digest::SHA256.file(PROFILE_PATH).hexdigest,
      "distribution_sha256" => DISTRIBUTION_SHA256,
      "candidate_sha256" => CANDIDATE_SHA256,
      "transaction_success_ratio" => 1.0,
      "ledger_close_seconds_p95" => 4.0,
      "peak_memory_bytes" => 800,
      "memory_limit_bytes" => 1_000,
      "cpu_utilization_ratio" => 0.75,
      "free_disk_bytes" => 200,
      "disk_total_bytes" => 1_000,
      "io_wait_ratio" => 0.20,
      "max_queue_depth" => 20,
      "finality_seconds_p95" => 5.0,
      "recovery_seconds" => 10.0,
      "recovery_confirmed" => true,
      "reset_confirmed" => true,
      "artifact_sha256" => "a" * 64
    }
  end
end
