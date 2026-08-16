# frozen_string_literal: true

require "digest"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class ProvisioningBenchmarkTest < Minitest::Test
  include CompleteReservesPlanningFixture

  # Break caught: folding the fixed 70-hour run windows into a made-up total
  # duration when full-scale provisioning has not been measured.
  def test_estimate_keeps_timed_floor_separate_from_unbounded_provisioning
    result = benchmark_estimate

    assert_equal 252_000, result.fetch("timed_floor_seconds")
    assert_equal "fixed-profile-minimum", result.fetch("timed_floor_status")
    assert_equal false, result.fetch("provisioning_bounded")
    assert_nil result.fetch("provisioning_seconds")
    assert_nil result.fetch("completion_seconds")
    assert_equal "measured-calibrated-extrapolation", result.fetch("estimate_status")
    assert_equal [10_000, 25_000, 50_000, 1_000_000], result.fetch("measured_account_root_targets")
    assert_equal false, result.fetch("counted_run")
    assert_equal false, result.fetch("execution_authorized")
    assert_equal "isolated-network-only", result.fetch("network_scope")
    assert_equal 4, result.fetch("measured_samples").length
    assert_equal 25_000, result.fetch("measured_samples").first.fetch("attempted_transactions")
    assert_equal 50_000_000, result.fetch("measured_samples").first.fetch("state_disk_bytes")
    assert result.frozen?
  end

  # Break caught: accepting an attractive throughput estimate without all
  # three required calibration sizes.
  def test_requires_exact_10k_25k_and_50k_calibration_samples
    error = assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(
        profile: full_profile,
        samples: measured_samples.reject { |sample| sample.fetch("account_root_target") == 25_000 },
        one_million_checkpoint: measured_one_million_checkpoint
      )
    end

    assert_equal "invalid provisioning benchmark", error.message
  end

  # Break caught: synthesizing a one-million disposition when the operator did
  # not explicitly provide measured evidence or a not-measured reason.
  def test_requires_explicit_one_million_disposition
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(profile: full_profile, samples: measured_samples.first(3))
    end
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(
        profile: full_profile,
        samples: measured_samples.first(3),
        one_million_checkpoint: unmeasured_one_million_checkpoint.reject { |key| key == "reason" }
      )
    end

    result = benchmark.estimate_full(
      profile: full_profile,
      samples: measured_samples.first(3),
      one_million_checkpoint: unmeasured_one_million_checkpoint
    )
    checkpoint = result.fetch("planning_checkpoints").last

    assert_equal 1_000_000, checkpoint.fetch("account_root_target")
    assert_equal "not_measured", checkpoint.fetch("measurement_status")
    assert_equal "not-yet-executed", checkpoint.fetch("reason")
    refute checkpoint.key?("artifact_sha256")
    assert_equal [10_000, 25_000, 50_000], result.fetch("measured_account_root_targets")
  end

  # Break caught: declaring the checkpoint measured without its exact 1m
  # sample artifact or declaring it unmeasured while supplying that sample.
  def test_one_million_disposition_must_match_measured_samples
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(
        profile: full_profile,
        samples: measured_samples,
        one_million_checkpoint: measured_one_million_checkpoint.merge("artifact_sha256" => "f" * 64)
      )
    end
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(
        profile: full_profile,
        samples: measured_samples,
        one_million_checkpoint: unmeasured_one_million_checkpoint
      )
    end
  end

  # Break caught: an extrapolator whose projected work decreases as the
  # declared population grows.
  def test_non_binding_projections_are_monotonic_in_population_work
    projections = benchmark_estimate.fetch("projections")
    ordered = projections.sort_by { |projection| projection.fetch("population_work_units") }

    minimums = ordered.map { |projection| projection.dig("provisioning_seconds_range", "minimum") }
    maximums = ordered.map { |projection| projection.dig("provisioning_seconds_range", "maximum") }
    assert_equal minimums.sort, minimums
    assert_equal maximums.sort, maximums
    assert projections.all? { |projection| projection.fetch("estimate_kind") == "non-binding-extrapolation" }
  end

  # Break caught: pooling measurements from a different profile,
  # distribution, candidate, public network, or counted execution.
  def test_rejects_sample_with_changed_exact_binding_or_execution_scope
    mutations = {
      "profile_sha256" => "a" * 64,
      "distribution_sha256" => "a" * 64,
      "candidate_sha256" => "a" * 64,
      "network_scope" => "public-test-network",
      "counted_run" => true,
      "measurement_source" => "estimated"
    }

    mutations.each do |key, value|
      samples = measured_samples.map(&:dup)
      samples.first[key] = value
      assert_raises(XrplReserveStudy::ProvisioningBenchmarkError, key) do
        benchmark.estimate_full(profile: full_profile, samples: samples, one_million_checkpoint: measured_one_million_checkpoint)
      end
    end
  end

  # Break caught: using incomplete resource, reset/recovery, or integrity data
  # as measured input.
  def test_rejects_missing_metrics_false_recovery_or_invalid_hashes
    samples = measured_samples.map(&:dup)
    samples.first.delete("io_write_bytes")
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(profile: full_profile, samples: samples, one_million_checkpoint: measured_one_million_checkpoint)
    end

    samples = measured_samples.map(&:dup)
    samples.first["reset_confirmed"] = false
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(profile: full_profile, samples: samples, one_million_checkpoint: measured_one_million_checkpoint)
    end

    samples = measured_samples.map(&:dup)
    samples.first["artifact_sha256"] = "not-a-sha"
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(profile: full_profile, samples: samples, one_million_checkpoint: measured_one_million_checkpoint)
    end


    samples = measured_samples.map(&:dup)
    samples[1]["artifact_sha256"] = samples[0].fetch("artifact_sha256")
    assert_raises(XrplReserveStudy::ProvisioningBenchmarkError) do
      benchmark.estimate_full(profile: full_profile, samples: samples, one_million_checkpoint: measured_one_million_checkpoint)
    end
  end

end
