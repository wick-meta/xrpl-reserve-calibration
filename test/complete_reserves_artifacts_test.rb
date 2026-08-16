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

  # Break caught: accepting a run-id-only resume marker or a partially changed
  # execution directory without rechecking every published byte.
  def test_publishes_and_reverifies_complete_execution_bundle_for_resume
    artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
    binding = execution_item.slice("profile_id", "profile_sha256", "distribution_sha256", "candidate_sha256")
    metrics = [security_baseline.merge(binding)] + %w[account-burst object-burst mixed churn recovery].map.with_index do |workload_id, index|
      security_observed.merge(binding).merge(
        "workload_id" => workload_id,
        "attempted_transactions" => workload_id == "recovery" ? 100 : 500,
        "validated_transactions" => workload_id == "recovery" ? 100 : 500,
        "artifact_sha256" => format("%064x", index + 10)
      )
    end
    security = metrics.drop(1).map do |observed|
      XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: metrics.first, observed: observed)
    end
    result = execution_result(metrics: metrics, security: security)
    resume = {
      "schema_version" => "complete-reserves-resume-v1", "run_id" => result.fetch("run_id"),
      "schedule_item_sha256" => result.fetch("schedule_item_sha256"),
      "reset_confirmed" => true, "recovery_confirmed" => true
    }

    published = artifacts.publish_execution_bundle(
      result: result, metrics: metrics, security_evaluations: security, resume_record: resume
    )
    record = published.fetch("resume_record")

    assert_match(/\A[0-9a-f]{64}\z/, published.fetch("result_artifact_sha256"))
    assert_equal published.fetch("result_artifact_sha256"), record.fetch("result_artifact_sha256")
    assert_equal result, artifacts.verify_execution_resume(record: record, item: execution_item)
    output = File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "executions", result.fetch("run_id"))
    assert_equal %w[SHA256SUMS bindings.json metrics.json result.json resume.json security.json], Dir.children(output).sort

    File.binwrite(File.join(output, "metrics.json"), "[]\n")
    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) do
      artifacts.verify_execution_resume(record: record, item: execution_item)
    end
  ensure
    FileUtils.rm_rf(output) if output&.start_with?(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT + File::SEPARATOR)
  end


  # Break caught: publishing scheduler/security evidence without verifying its
  # benchmark hash chain or producing checksums for every planning artifact.
  def test_publishes_hash_bound_non_counted_planning_bundle_atomically
    estimate = benchmark_estimate
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

    assert_equal %w[SHA256SUMS benchmark.json bindings.json schedule.json security.json], Dir.children(output).sort
    assert_equal Digest::SHA256.file(File.join(output, "benchmark.json")).hexdigest,
                 published.dig("artifact_sha256", "benchmark.json")
    assert_equal 4, File.readlines(File.join(output, "SHA256SUMS")).length
    bindings = JSON.parse(File.binread(File.join(output, "bindings.json")))
    assert_equal "complete-reserves-full-matrix-v1", bindings.fetch("profile_id")
    assert_equal security.fetch("security_sha256"), bindings.fetch("security_sha256")
    assert_equal "isolated-network-only", bindings.fetch("network_scope")
    assert_equal false, bindings.fetch("execution_authorized")
    assert_equal schedule.fetch("security_config_sha256"), security.fetch("security_config_sha256")
    assert_equal "complete-reserves-full-matrix-v1", security.fetch("profile_id")
    assert_equal false, security.fetch("execution_authorized")
  ensure
    FileUtils.rm_rf(output) if output&.start_with?(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT + File::SEPARATOR)
  end

  # Break caught: accepting a schedule detached from the measured benchmark.
  def test_rejects_changed_planning_hash_chain_before_publication
    estimate = benchmark_estimate
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


  # Break caught: joining a valid calibrated-profile security result to a full
  # matrix benchmark merely because their config/distribution hashes match.
  def test_rejects_calibrated_security_result_for_full_matrix_planning_bundle
    estimate = benchmark_estimate
    schedule = planning_schedule(estimate)
    calibrated_baseline = security_baseline.merge("profile_id" => "complete-reserves-calibrated-v1")
    calibrated_observed = security_observed.merge("profile_id" => "complete-reserves-calibrated-v1")
    security = XrplReserveStudy::SecurityWorkload.new.evaluate(
      baseline: calibrated_baseline,
      observed: calibrated_observed
    )

    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) do
      XrplReserveStudy::CompleteReservesArtifacts.new.publish_planning_bundle(
        benchmark: estimate,
        schedule: schedule,
        security: security
      )
    end
  end

  # Break caught: publishing security evidence that is self-hashed but bound
  # to a different security configuration or authorizes execution.
  def test_rejects_rehashed_changed_security_binding_or_authorization
    estimate = benchmark_estimate
    schedule = planning_schedule(estimate)
    valid = XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: security_baseline, observed: security_observed)
    [
      valid.merge("security_config_sha256" => "f" * 64),
      valid.merge("execution_authorized" => true)
    ].each do |mutation|
      changed = Marshal.load(Marshal.dump(mutation))
      changed["security_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(changed.reject { |key, _| key == "security_sha256" })))
      assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) do
        XrplReserveStudy::CompleteReservesArtifacts.new.publish_planning_bundle(
          benchmark: estimate,
          schedule: schedule,
          security: changed
        )
      end
    end
  end

  # Break caught: treating a valid self-hash as sufficient when the security
  # evidence was produced against a public network scope.
  def test_rejects_rehashed_public_network_security_scope
    estimate = benchmark_estimate
    schedule = planning_schedule(estimate)
    valid = XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: security_baseline, observed: security_observed)
    changed = Marshal.load(Marshal.dump(valid))
    changed["network_scope"] = "public-test-network"
    changed["security_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(changed.reject { |key, _| key == "security_sha256" })))
    published = nil

    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) do
      published = XrplReserveStudy::CompleteReservesArtifacts.new.publish_planning_bundle(
        benchmark: estimate,
        schedule: schedule,
        security: changed
      )
    end
  ensure
    output = published&.fetch("output_dir", nil)
    FileUtils.rm_rf(output) if output&.start_with?(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT + File::SEPARATOR)
  end

  private

  def execution_item
    {
      "run_id" => "cal-a000000002-o000000020-r98",
      "profile_id" => "complete-reserves-calibrated-v1", "profile_sha256" => "e" * 64,
      "schedule_sha256" => "b" * 64, "schedule_item_sha256" => "1" * 64,
      "security_config_sha256" => XrplReserveStudy::SecurityWorkload.new.security_config_sha256,
      "distribution_sha256" => "d" * 64, "candidate_sha256" => "c" * 64,
      "network_scope" => "isolated-network-only", "counted_run" => false,
      "execution_authorized" => false
    }
  end

  def execution_result(metrics:, security:)
    execution_item.merge(
      "schema_version" => "complete-reserves-execution-result-v1", "status" => "passed",
      "snapshot_id" => "calibration-base", "ledger" => {
        "network_id" => "candidate-task6", "ledger_index" => 25, "ledger_hash" => "f" * 64,
        "account_roots" => 2, "class_counts" => { "offer" => 1 }
      },
      "workload_artifact_sha256" => metrics.to_h { |record| [record.fetch("workload_id"), record.fetch("artifact_sha256")] },
      "security_sha256" => security.to_h { |record| [record.fetch("workload_id"), record.fetch("security_sha256")] }, "recovery_seconds" => 2.0,
      "recovery_confirmed" => true, "reset_confirmed" => true
    )
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

  def planning_schedule(estimate)
    XrplReserveStudy::ProfileScheduler.new(
      distribution: DISTRIBUTION,
      distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256,
      profile_path: PROFILE_PATH
    ).schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)
  end

  def security_baseline
    security_observed.merge(
      "workload_id" => "baseline",
      "attempted_transactions" => 100,
      "validated_transactions" => 100,
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
      "profile_id" => "complete-reserves-full-matrix-v1",
      "profile_sha256" => Digest::SHA256.file(PROFILE_PATH).hexdigest,
      "distribution_sha256" => DISTRIBUTION_SHA256,
      "candidate_sha256" => CANDIDATE_SHA256,
      "attempted_transactions" => 500,
      "validated_transactions" => 500,
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


  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
end
