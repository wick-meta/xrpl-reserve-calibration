# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class CompleteReservesCliTest < Minitest::Test
  include CompleteReservesPlanningFixture

  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "reserve-study")

  # Break caught: describing the full matrix as executable or bounded before
  # its authorization and measured provisioning duration exist.
  def test_preflight_reports_the_disabled_full_profile_and_fixed_timed_floor
    stdout, stderr, status = run_cli("complete-reserves-preflight", "--profile", "full-v1")

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal false, result.fetch("execution_authorized")
    assert_equal false, result.fetch("counted_run")
    assert_equal false, result.fetch("executor_available")
    assert_equal 120, result.fetch("cell_count")
    assert_equal 252_000, result.fetch("timed_floor_seconds")
    assert_equal "unbounded", result.fetch("provisioning_time_status")
  end

  # Break caught: accepting planning data from command-line endpoints or file
  # overrides instead of one bounded, explicit JSON stdin document.
  def test_benchmark_and_plan_accept_only_hash_bound_json_stdin
    benchmark_payload = {
      "distribution" => DISTRIBUTION,
      "distribution_sha256" => DISTRIBUTION_SHA256,
      "candidate_sha256" => CANDIDATE_SHA256,
      "samples" => measured_samples,
      "one_million_checkpoint" => measured_one_million_checkpoint
    }
    stdout, stderr, status = run_cli(
      "complete-reserves-benchmark", "--profile", "full-v1", "--json-stdin",
      stdin_data: JSON.generate(benchmark_payload)
    )
    assert status.success?, stderr
    estimate = JSON.parse(stdout)
    assert_equal 252_000, estimate.fetch("timed_floor_seconds")
    assert_nil estimate.fetch("completion_seconds")

    plan_payload = benchmark_payload.slice("distribution", "distribution_sha256", "candidate_sha256").merge(
      "benchmark" => estimate, "available_resources" => available_resources, "resume_records" => []
    )
    stdout, stderr, status = run_cli(
      "complete-reserves-plan", "--profile", "full-v1", "--json-stdin",
      stdin_data: JSON.generate(plan_payload)
    )
    assert status.success?, stderr
    plan = JSON.parse(stdout)
    assert_equal 120, plan.fetch("items").length
    assert_equal false, plan.fetch("execution_authorized")
    assert_equal "unbounded", plan.fetch("provisioning_time_status")

    stdout, stderr, status = run_cli(
      "complete-reserves-plan", "--profile", "full-v1", "--endpoint", "https://example.invalid"
    )
    refute status.success?
    assert_empty stdout
    assert_match(/--endpoint is not supported/, stderr)
  end

  # Break caught: silently treating a calibrated plan as full-matrix evidence
  # or changing the exact 3/120 profile cell counts.
  def test_profile_command_keeps_calibrated_and_full_cells_incompatible
    input = JSON.generate("distribution" => DISTRIBUTION)
    calibrated = JSON.parse(run_cli_success("complete-reserves-profile", "--profile", "calibrated-v1", "--json-stdin", stdin_data: input))
    full = JSON.parse(run_cli_success("complete-reserves-profile", "--profile", "full-v1", "--json-stdin", stdin_data: input))

    assert_equal 3, calibrated.fetch("cells").length
    assert calibrated.fetch("cells").all? { |cell| cell.fetch("profile_id") == "complete-reserves-calibrated-v1" }
    assert_equal 120, full.fetch("cells").length
    assert full.fetch("cells").all? { |cell| cell.fetch("profile_id") == "complete-reserves-full-matrix-v1" }
    assert_equal false, full.fetch("execution_authorized")
  end

  # Break caught: routing the old matrix command into authority input even
  # though the repository authorization record remains false.
  def test_matrix_still_fails_before_reading_stdin_authority
    stdout, stderr, status = run_cli("complete-reserves-matrix", stdin_data: "must-not-be-read\n")

    refute status.success?
    assert_empty stdout
    assert_match(/execution remains disabled/, stderr)
  end

  private

  def available_resources
    {
      "logical_cpus" => 8, "memory_bytes" => 64_000_000_000,
      "free_disk_bytes" => 128_000_000_000,
      "io_read_bytes_per_second" => 1_000_000_000,
      "io_write_bytes_per_second" => 1_000_000_000
    }
  end

  def run_cli(command, *arguments, stdin_data: "")
    Open3.capture3(CLI, command, *arguments, stdin_data: stdin_data, chdir: ROOT)
  end

  def run_cli_success(command, *arguments, stdin_data: "")
    stdout, stderr, status = run_cli(command, *arguments, stdin_data: stdin_data)
    assert status.success?, stderr
    stdout
  end
end
