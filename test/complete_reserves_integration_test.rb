# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class CompleteReservesIntegrationTest < Minitest::Test
  include CompleteReservesPlanningFixture
  PROFILE_PATH = File.expand_path("../study/complete-reserves-profiles-v1.yml", __dir__)
  PROFILE_SHA256 = Digest::SHA256.file(PROFILE_PATH).hexdigest
  DISTRIBUTION_SHA256 = "d" * 64
  CANDIDATE_SHA256 = "c" * 64
  RUN_ID = "cal-a000010000-o000015000-r03"

  class FakeIsolatedRuntime
    attr_reader :events, :recipe_kinds

    def initialize(state_path:, ledger:, item:)
      @state_path = state_path
      @ledger = ledger
      @item = item
      @events = []
      @recipe_kinds = Hash.new { |hash, key| hash[key] = [] }
    end

    def state_path; @state_path; end
    def ledger_identity; @ledger; end
    def stop_checkout!; @events << "snapshot-stop"; end
    def start_readonly!; @events << "snapshot-restart"; end

    def private_network_identity
      {
        "schema_version" => "complete-reserves-private-identity-v1",
        "network_scope" => "isolated-network-only", "network_id" => "candidate-task6",
        "transport" => "https-mtls-loopback", "candidate_sha256" => CANDIDATE_SHA256,
        "peer_certificate_sha256" => "a" * 64, "client_certificate_sha256" => "9" * 64
      }
    end

    def start_clone!(image:, run:)
      raise "clone capability missing" unless image.descriptor.positive? && image.state_descriptor.positive?
      raise "wrong clone binding" unless run.fetch("ledger") == @ledger

      @events << "clone-start"
      true
    end

    def warmup(seconds:, item:)
      raise "wrong warmup" unless seconds == 300 && item == @item
      @events << "warmup"
      true
    end

    def run_security_workload(workload_id:, item:, recipes:, transaction_ceiling:, measurement_seconds:, authority:)
      raise "wrong execution item" unless item == @item
      raise "invalid runtime authority" unless authority.is_a?(String) && !authority.empty?
      raise "missing ceiling" unless transaction_ceiling.positive? && measurement_seconds == 1_800

      @events << "workload-#{workload_id}"
      @recipe_kinds[workload_id].concat(recipes.map(&:kind))
      metrics(workload_id, transaction_ceiling)
    end

    def recover!(item:, ledger:)
      raise "wrong recovery" unless item == @item && ledger == @ledger
      @events << "recovery"
      { "confirmed" => true, "seconds" => 2.0, "ledger" => @ledger }
    end

    def reset!(item:, ledger:)
      raise "wrong reset" unless item == @item && ledger == @ledger
      @events << "reset"
      { "confirmed" => true, "ledger" => @ledger }
    end

    private

    def metrics(workload_id, ceiling)
      attempted = %w[baseline recovery].include?(workload_id) ? 100 : ceiling
      {
        "workload_id" => workload_id, "profile_id" => @item.fetch("profile_id"),
        "profile_sha256" => @item.fetch("profile_sha256"),
        "distribution_sha256" => @item.fetch("distribution_sha256"),
        "candidate_sha256" => @item.fetch("candidate_sha256"),
        "attempted_transactions" => attempted, "validated_transactions" => attempted,
        "transaction_success_ratio" => 1.0,
        "ledger_close_seconds_p95" => workload_id == "baseline" ? 2.0 : 3.0,
        "peak_memory_bytes" => workload_id == "baseline" ? 400 : 700,
        "memory_limit_bytes" => 1_000,
        "cpu_utilization_ratio" => workload_id == "baseline" ? 0.2 : 0.6,
        "free_disk_bytes" => 500, "disk_total_bytes" => 1_000,
        "io_wait_ratio" => workload_id == "baseline" ? 0.04 : 0.12,
        "max_queue_depth" => workload_id == "baseline" ? 2 : 20,
        "finality_seconds_p95" => workload_id == "baseline" ? 2.0 : 4.0,
        "recovery_seconds" => 2.0, "recovery_confirmed" => true,
        "reset_confirmed" => true,
        "artifact_sha256" => Digest::SHA256.hexdigest("integration-#{workload_id}")
      }
    end
  end

  def setup
    @runtime_root = Dir.mktmpdir("complete-reserves-e2e-")
    @state_path = File.join(@runtime_root, "checkout-state")
    FileUtils.mkdir_p(@state_path)
    write_minimal_nudb_state(@state_path)
    @recipes = XrplReserveStudy::OwnerObjectRecipeRegistry.new
    @artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
    @estimate = benchmark_estimate
    @schedule = planning_schedule(@estimate)
    @planning_security = planning_security
    @planning_output = File.join(
      XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "planning", @schedule.fetch("schedule_sha256")
    )
    FileUtils.rm_rf(@planning_output)
    @planning_bindings_sha256 = @artifacts.planning_bindings_sha256(
      benchmark: @estimate, schedule: @schedule, security: @planning_security
    )
    @item = execution_item
    @published_planning = @artifacts.publish_planning_bundle(
      benchmark: @estimate, schedule: @schedule, security: @planning_security, calibration_items: [@item]
    )
    @ledger = {
      "network_id" => "candidate-task6", "ledger_index" => 25, "ledger_hash" => "f" * 64,
      "account_roots" => 10_000, "class_counts" => calibrated_class_counts
    }
    @runtime = FakeIsolatedRuntime.new(state_path: @state_path, ledger: @ledger, item: @item)
    @verifier = XrplReserveStudy::VerifiedStateSnapshot.new(runtime: @runtime, runtime_root: @runtime_root)
    @snapshot = @verifier.publish(identity: snapshot_identity, seed_result: seed_result)
    @runtime.events.clear
  end

  def teardown
    FileUtils.rm_rf(@runtime_root)
    FileUtils.rm_rf(@planning_output) if @planning_output
    FileUtils.rm_rf(File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "executions", RUN_ID))
  end

  # Break caught: unit-only fakes could hide an incompatibility between the
  # real verified image, one-time descriptor-bound clone, executor, security
  # evaluator, and atomic artifact/resume formats.
  def test_verified_snapshot_to_clone_to_all_family_execution_to_hash_bound_resume
    clone_manager = XrplReserveStudy::RunCloneManager.new(
      verifier: @verifier, runtime: @runtime, runtime_root: @runtime_root
    )
    executor = XrplReserveStudy::CompleteReservesExecutor.new(
      snapshot_provider: ->(_item) { @snapshot }, clone_manager: clone_manager,
      runtime: @runtime, artifacts: @artifacts, planning_artifacts: @artifacts,
      security: XrplReserveStudy::SecurityWorkload.new,
      recipe_registry: @recipes
    )
    authority = +"runtime-only-authority"

    result = executor.run(item: @item, secret_reader: -> { authority })

    assert_equal [
      "clone-start", "warmup", "workload-baseline", "workload-account-burst",
      "workload-object-burst", "workload-mixed", "workload-churn",
      "workload-recovery", "recovery", "reset"
    ], @runtime.events
    expected = @recipes.all.map(&:kind).sort
    %w[object-burst mixed churn].each { |name| assert_equal expected, @runtime.recipe_kinds.fetch(name).sort }
    assert_empty authority
    assert_equal 20, @ledger.fetch("class_counts").length
    assert_equal 15_000, @ledger.fetch("class_counts").values.sum
    assert_match(/\A[0-9a-f]{64}\z/, result.fetch("result_artifact_sha256"))
    resumed = executor.run(
      item: @item, secret_reader: -> { raise "resume read authority" },
      resume_record: result.fetch("resume_record")
    )
    assert_equal result.fetch("run_id"), resumed.fetch("run_id")
    assert_equal false, resumed.fetch("counted_run")
  end

  private

  def execution_item
    value = {
      "schema_version" => "complete-reserves-calibration-item-v1", "run_id" => RUN_ID,
      "repetition" => 3, "profile_id" => "complete-reserves-calibrated-v1",
      "workload_class" => "complete-reserves-security-suite-v1",
      "profile_sha256" => PROFILE_SHA256, "schedule_sha256" => @schedule.fetch("schedule_sha256"),
      "benchmark_sha256" => @estimate.fetch("benchmark_sha256"),
      "planning_security_sha256" => @planning_security.fetch("security_sha256"),
      "planning_bindings_sha256" => @planning_bindings_sha256,
      "security_config_sha256" => XrplReserveStudy::SecurityWorkload.new.security_config_sha256,
      "distribution_sha256" => DISTRIBUTION_SHA256, "candidate_sha256" => CANDIDATE_SHA256,
      "snapshot_id" => "calibration-base", "study_sha256" => "7" * 64,
      "config_sha256" => "6" * 64, "source_sha256" => "5" * 64,
      "ledger_index" => 25, "ledger_hash" => "f" * 64,
      "network_scope" => "isolated-network-only", "account_root_target" => 10_000,
      "owned_object_target" => 15_000, "base_reserve_drops" => 1_000_000,
      "owner_reserve_drops" => 200_000, "fee_headroom_drops_per_step" => 20,
      "warmup_seconds" => 300, "measurement_seconds" => 1_800,
      "execution_limits" => { "max_batch_size" => 10, "max_retries" => 0, "deadline_seconds" => 7_200 },
      "status" => "pending", "counted_run" => false, "execution_authorized" => false
    }
    value["schedule_item_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    value.freeze
  end

  def calibrated_class_counts
    kinds = @recipes.all.map(&:kind)
    quotient, remainder = 15_000.divmod(kinds.length)
    kinds.each_with_index.to_h { |kind, index| [kind, quotient + (index < remainder ? 1 : 0)] }
  end

  def planning_schedule(estimate)
    XrplReserveStudy::ProfileScheduler.new(
      distribution: DISTRIBUTION, distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256, profile_path: PROFILE_PATH
    ).schedule(profile: full_profile, benchmark: estimate, available_resources: available_resources)
  end

  def available_resources
    {
      "logical_cpus" => 8, "memory_bytes" => 64_000_000_000,
      "free_disk_bytes" => 128_000_000_000,
      "io_read_bytes_per_second" => 1_000_000_000,
      "io_write_bytes_per_second" => 1_000_000_000
    }
  end

  def planning_security
    security = XrplReserveStudy::SecurityWorkload.new
    security.evaluate(
      baseline: planning_metric("baseline", attempted: 100, artifact: "1" * 64),
      observed: planning_metric("mixed", attempted: 500, artifact: "2" * 64)
    )
  end

  def planning_metric(workload_id, attempted:, artifact:)
    {
      "workload_id" => workload_id, "profile_id" => "complete-reserves-full-matrix-v1",
      "profile_sha256" => PROFILE_SHA256, "distribution_sha256" => DISTRIBUTION_SHA256,
      "candidate_sha256" => CANDIDATE_SHA256, "attempted_transactions" => attempted,
      "validated_transactions" => attempted, "transaction_success_ratio" => 1.0,
      "ledger_close_seconds_p95" => workload_id == "baseline" ? 2.0 : 3.0,
      "peak_memory_bytes" => workload_id == "baseline" ? 400 : 700, "memory_limit_bytes" => 1_000,
      "cpu_utilization_ratio" => workload_id == "baseline" ? 0.2 : 0.6,
      "free_disk_bytes" => 500, "disk_total_bytes" => 1_000,
      "io_wait_ratio" => workload_id == "baseline" ? 0.04 : 0.12,
      "max_queue_depth" => workload_id == "baseline" ? 2 : 20,
      "finality_seconds_p95" => workload_id == "baseline" ? 2.0 : 4.0,
      "recovery_seconds" => 2.0, "recovery_confirmed" => true, "reset_confirmed" => true,
      "artifact_sha256" => artifact
    }
  end

  def snapshot_identity
    {
      "snapshot_id" => "calibration-base", "candidate_image_digest" => CANDIDATE_SHA256,
      "study_sha256" => "7" * 64, "distribution_sha256" => DISTRIBUTION_SHA256,
      "config_sha256" => "6" * 64, "source_sha256" => "5" * 64
    }
  end

  def seed_result
    {
      "schema_version" => "complete-reserves-seed-state-v2", "profile_id" => "complete-reserves-calibrated-v1",
      "cell_id" => RUN_ID, "counted_run" => false, "elapsed_seconds" => 1.0,
      "attempted_transactions" => 22, "validated_transactions" => 22,
      "burned_fee_drops" => 220, "locked_xrp_drops" => 6_000_000,
      "released_xrp_drops" => 0,
      "finality" => { "validated" => 22, "last_ledger_index" => 25, "last_ledger_hash" => "f" * 64 },
      "classified_ledger_evidence" => @ledger,
      "resource_snapshots" => [{ "phase" => "before", "metrics" => { "rss_bytes" => 1 } }]
    }
  end

  def write_minimal_nudb_state(root)
    directory = File.join(root, "nudb")
    FileUtils.mkdir_p(directory)
    uid = 0x0102_0304_0506_0708
    common = [2].pack("n") + [uid, 1].pack("Q>Q>") + [32].pack("n")
    dat_header = "nudb.dat".b + common + ("\0" * 64)
    key_header = "nudb.key".b + common +
      [0x1112_1314_1516_1718, 0x2122_2324_2526_2728].pack("Q>Q>") +
      [4096, 32_768].pack("n2") + ("\0" * 56)
    File.binwrite(File.join(directory, "nudb.dat"), dat_header)
    File.binwrite(File.join(directory, "nudb.key"), key_header.ljust(8192, "\0"))
  end

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array then value.map { |entry| canonical(entry) }
    else value
    end
  end
end
