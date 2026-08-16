# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class SecurityWorkloadTest < Minitest::Test
  WORKLOAD_PATH = File.expand_path("../study/complete-reserves-security-workloads-v1.yml", __dir__)

  # Break caught: omitting an abuse-resistance or recovery workload from the
  # predeclared security plane.
  def test_declares_all_frozen_security_workloads_and_named_gates
    contract = workload.contract

    assert_equal %w[baseline account-burst object-burst mixed churn recovery], contract.fetch("workloads").map { |entry| entry.fetch("workload_id") }
    assert_equal %w[transaction_success transaction_ceiling close_time_ceiling memory_ceiling cpu_ceiling disk_ceiling io_wait_ceiling queue_ceiling finality_ceiling recovery_ceiling reset_recovery artifact_integrity], contract.fetch("gates").keys
    assert_equal "isolated-network-only", contract.fetch("network_scope")
    assert_equal false, contract.fetch("counted_run")
    assert_equal false, contract.fetch("execution_authorized")
    assert_match(/\A[0-9a-f]{64}\z/, workload.security_config_sha256)
    assert contract.frozen?
  end

  # Break caught: a burst exceeding its declared transaction ceiling passing
  # because only its success ratio was evaluated.
  def test_names_declared_per_workload_transaction_ceiling_failure
    result = workload.evaluate(
      baseline: baseline,
      observed: observed.merge("attempted_transactions" => 501, "validated_transactions" => 501)
    )

    assert_includes result.fetch("failed_gates"), "transaction_ceiling"
    assert_equal 500, result.fetch("transaction_ceiling")
  end

  # Break caught: an overloaded run passing despite exceeding the frozen
  # memory resource ceiling.
  def test_security_gate_names_memory_failure_without_policy_recommendation
    overloaded = observed.merge("peak_memory_bytes" => 901)
    result = workload.evaluate(baseline: baseline, observed: overloaded)

    assert_includes result.fetch("failed_gates"), "memory_ceiling"
    refute result.fetch("passed")
    refute result.key?("reserve_policy_recommendation")
  end

  # Break caught: passing a workload with stalled recovery, absent reset, or
  # no hash-bound artifact.
  def test_names_recovery_reset_and_artifact_failures
    result = workload.evaluate(
      baseline: baseline,
      observed: observed.merge(
        "recovery_seconds" => 301.0,
        "recovery_confirmed" => false,
        "reset_confirmed" => false,
        "artifact_sha256" => "invalid"
      )
    )

    assert_includes result.fetch("failed_gates"), "recovery_ceiling"
    assert_includes result.fetch("failed_gates"), "reset_recovery"
    assert_includes result.fetch("failed_gates"), "artifact_integrity"
  end

  # Break caught: accepting partial or sensitive measurement records that
  # make security gate results irreproducible.
  def test_rejects_missing_metrics_and_sensitive_fields
    assert_raises(XrplReserveStudy::SecurityWorkloadError) do
      workload.evaluate(baseline: baseline, observed: observed.reject { |key| key == "max_queue_depth" })
    end
    assert_raises(XrplReserveStudy::SecurityWorkloadError) do
      workload.evaluate(baseline: baseline, observed: observed.merge("secret" => "no"))
    end
    assert_raises(XrplReserveStudy::SecurityWorkloadError) do
      workload.evaluate(baseline: baseline, observed: observed.merge("candidate_sha256" => "b" * 64))
    end
    assert_raises(XrplReserveStudy::SecurityWorkloadError) do
      workload.evaluate(baseline: baseline.merge("artifact_sha256" => "invalid"), observed: observed)
    end
  end

  # Break caught: an evaluator that fails healthy measurements or returns
  # mutable evidence.
  def test_passes_all_named_gates_for_healthy_hash_bound_measurements
    result = workload.evaluate(baseline: baseline, observed: observed)

    assert result.fetch("passed")
    assert_empty result.fetch("failed_gates")
    assert_equal workload.contract.fetch("gates").keys, result.fetch("passed_gates")
    assert_equal "e" * 64, result.fetch("profile_sha256")
    assert_equal "d" * 64, result.fetch("distribution_sha256")
    assert_equal "c" * 64, result.fetch("candidate_sha256")
    assert_equal workload.security_config_sha256, result.fetch("security_config_sha256")
    assert_equal false, result.fetch("execution_authorized")
    assert result.frozen?
  end

  private

  def workload
    XrplReserveStudy::SecurityWorkload.new(path: WORKLOAD_PATH)
  end

  def baseline
    observed.merge(
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

  def observed
    {
      "workload_id" => "mixed",
      "profile_id" => "complete-reserves-calibrated-v1",
      "profile_sha256" => "e" * 64,
      "distribution_sha256" => "d" * 64,
      "candidate_sha256" => "c" * 64,
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
end
