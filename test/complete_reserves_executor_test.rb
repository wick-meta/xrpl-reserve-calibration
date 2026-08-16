# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"
require_relative "complete_reserves_planning_fixture"

class CompleteReservesExecutorTest < Minitest::Test
  include CompleteReservesPlanningFixture
  PROFILE_PATH = File.expand_path("../study/complete-reserves-profiles-v1.yml", __dir__)
  PROFILE_SHA256 = Digest::SHA256.file(PROFILE_PATH).hexdigest
  DISTRIBUTION_SHA256 = "d" * 64
  CANDIDATE_SHA256 = "c" * 64

  class FakeCloneManager
    attr_reader :events

    def initialize(events)
      @events = events
    end

    def prepare(snapshot:, run:)
      @events << ["clone", snapshot.fetch("snapshot_id"), run.fetch("run_id")]
      { "path" => "opaque-test-capability", "snapshot" => snapshot }
    end

    def start(clone:, run:)
      raise "wrong clone" unless clone.fetch("snapshot").fetch("snapshot_id") == "calibration-base"

      @events << ["start", run.fetch("run_id")]
      true
    end
  end

  class FakeRuntime
    attr_reader :events, :recipe_kinds
    attr_accessor :identity

    def initialize(events, item, ledger)
      @events = events
      @item = item
      @ledger = ledger
      @recipe_kinds = Hash.new { |hash, key| hash[key] = [] }
      @identity = {
        "schema_version" => "complete-reserves-private-identity-v1",
        "network_scope" => "isolated-network-only",
        "network_id" => "candidate-task6",
        "transport" => "https-mtls-loopback",
        "candidate_sha256" => CANDIDATE_SHA256,
        "peer_certificate_sha256" => "a" * 64,
        "client_certificate_sha256" => "9" * 64
      }
    end

    def private_network_identity
      @identity
    end

    def warmup(seconds:, item:)
      raise "wrong warmup" unless seconds == 300 && item == @item

      @events << ["warmup", seconds]
      true
    end

    def run_security_workload(workload_id:, item:, recipes:, transaction_ceiling:, measurement_seconds:, authority:)
      raise "wrong item" unless item == @item
      raise "missing authority" unless authority.is_a?(String) && !authority.empty?
      raise "invalid ceiling" unless transaction_ceiling.positive?
      raise "wrong window" unless measurement_seconds == 1_800

      @events << ["workload", workload_id]
      @recipe_kinds[workload_id].concat(recipes.map(&:kind))
      metrics(workload_id, transaction_ceiling)
    end

    def recover!(item:, ledger:)
      raise "wrong recovery binding" unless item == @item && ledger == @ledger

      @events << ["recovery", item.fetch("run_id")]
      { "confirmed" => true, "seconds" => 2.0, "ledger" => @ledger }
    end

    def reset!(item:, ledger:)
      raise "wrong reset binding" unless item == @item && ledger == @ledger

      @events << ["reset", item.fetch("run_id")]
      { "confirmed" => true, "ledger" => @ledger }
    end

    private

    def metrics(workload_id, ceiling)
      attempted = workload_id == "baseline" || workload_id == "recovery" ? 100 : ceiling
      {
        "workload_id" => workload_id,
        "profile_id" => @item.fetch("profile_id"),
        "profile_sha256" => @item.fetch("profile_sha256"),
        "distribution_sha256" => @item.fetch("distribution_sha256"),
        "candidate_sha256" => @item.fetch("candidate_sha256"),
        "attempted_transactions" => attempted,
        "validated_transactions" => attempted,
        "transaction_success_ratio" => 1.0,
        "ledger_close_seconds_p95" => workload_id == "baseline" ? 2.0 : 3.0,
        "peak_memory_bytes" => workload_id == "baseline" ? 400 : 700,
        "memory_limit_bytes" => 1_000,
        "cpu_utilization_ratio" => workload_id == "baseline" ? 0.2 : 0.6,
        "free_disk_bytes" => 500,
        "disk_total_bytes" => 1_000,
        "io_wait_ratio" => workload_id == "baseline" ? 0.04 : 0.12,
        "max_queue_depth" => workload_id == "baseline" ? 2 : 20,
        "finality_seconds_p95" => workload_id == "baseline" ? 2.0 : 4.0,
        "recovery_seconds" => 2.0,
        "recovery_confirmed" => true,
        "reset_confirmed" => true,
        "artifact_sha256" => Digest::SHA256.hexdigest("task6-#{workload_id}")
      }
    end
  end

  class FakeArtifacts
    attr_reader :published

    def initialize(events)
      @events = events
    end

    def publish_execution_bundle(result:, metrics:, security_evaluations:, resume_record:)
      @events << ["publish", result.fetch("run_id")]
      @published = { result: result, metrics: metrics, security: security_evaluations, resume: resume_record }
      { "result_artifact_sha256" => "8" * 64, "resume_record" => resume_record.merge("result_artifact_sha256" => "8" * 64) }
    end

    def verify_execution_resume(record:, item:)
      return nil unless record.fetch("schedule_item_sha256") == item.fetch("schedule_item_sha256")

      record.fetch("result")
    end
  end

  class SuccessfulAuthorization
    def authorize!; true; end
  end

  def setup
    @security = XrplReserveStudy::SecurityWorkload.new
    @planning_artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
    @estimate = benchmark_estimate
    @schedule = planning_schedule(@estimate)
    @planning_security = planning_security
    @planning_output = File.join(
      XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "planning", @schedule.fetch("schedule_sha256")
    )
    FileUtils.rm_rf(@planning_output)
    @planning_bindings_sha256 = @planning_artifacts.planning_bindings_sha256(
      benchmark: @estimate, schedule: @schedule, security: @planning_security
    )
    @item = calibrated_item
    @published_planning = @planning_artifacts.publish_planning_bundle(
      benchmark: @estimate, schedule: @schedule, security: @planning_security, calibration_items: [@item]
    )
    @ledger = {
      "network_id" => "candidate-task6", "ledger_index" => 25, "ledger_hash" => "f" * 64,
      "account_roots" => 10_000, "class_counts" => calibrated_class_counts
    }
    @snapshot = {
      "schema_version" => "verified-state-snapshot-v1", "snapshot_id" => "calibration-base",
      "candidate_image_digest" => CANDIDATE_SHA256, "study_sha256" => "7" * 64,
      "distribution_sha256" => DISTRIBUTION_SHA256, "config_sha256" => "6" * 64,
      "source_sha256" => "5" * 64, "ledger" => @ledger, "files" => [],
      "path" => "opaque-test-path", "directory_binding" => []
    }
    @events = []
    @runtime = FakeRuntime.new(@events, @item, @ledger)
    @artifacts = FakeArtifacts.new(@events)
  end

  def teardown
    FileUtils.rm_rf(@planning_output) if @planning_output
  end

  # Break caught: reordering a destructive lifecycle, skipping a security
  # workload, or omitting an owner-object recipe while still publishing success.
  def test_runs_the_bounded_calibrated_lifecycle_and_every_recipe_before_publication
    authority = +"runtime-only-authority"
    result = executor.run(item: @item, secret_reader: -> { authority })

    assert_equal ["clone", "start", "warmup", *Array.new(6, "workload"), "recovery", "reset", "publish"],
                 @events.map(&:first)
    assert_equal %w[baseline account-burst object-burst mixed churn recovery],
                 @events.select { |event| event.first == "workload" }.map(&:last)
    expected = XrplReserveStudy::OwnerObjectRecipeRegistry.new.all.map(&:kind).sort
    %w[object-burst mixed churn].each { |workload| assert_equal expected, @runtime.recipe_kinds.fetch(workload).sort }
    assert_equal false, result.fetch("counted_run")
    assert_equal true, result.fetch("reset_confirmed")
    assert_equal true, result.fetch("recovery_confirmed")
    assert_match(/\A[0-9a-f]{64}\z/, result.fetch("result_artifact_sha256"))
    assert_empty authority
  end

  # Break caught: reading protected authority before rejecting the full profile
  # or a runtime identity that could route work to a public XRPL network.
  def test_rejects_full_profile_and_non_private_identity_before_authority_read
    cases = [
      -> { @item.merge("profile_id" => "complete-reserves-full-matrix-v1") },
      -> { @runtime.identity = @runtime.identity.merge("network_scope" => "public-test-network"); @item },
      -> { @runtime.identity = nil; @item }
    ]
    cases.each do |build_item|
      read = false
      assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
        executor.run(item: build_item.call, secret_reader: -> { read = true; +"must-not-be-read" })
      end
      refute read
    ensure
      @runtime.identity = FakeRuntime.new([], @item, @ledger).identity
    end
  end

  # Break caught: resuming from a run-id-only marker or reading authority for
  # a result whose exact schedule and artifact bindings were already verified.
  def test_resume_requires_exact_hash_bound_record_and_skips_execution
    result = { "run_id" => @item.fetch("run_id"), "counted_run" => false, "status" => "passed" }
    record = {
      "schema_version" => "complete-reserves-resume-v1", "run_id" => @item.fetch("run_id"),
      "schedule_item_sha256" => @item.fetch("schedule_item_sha256"),
      "result_artifact_sha256" => "8" * 64, "reset_confirmed" => true,
      "recovery_confirmed" => true, "result" => result
    }
    read = false

    assert_equal result, executor.run(item: @item, secret_reader: -> { read = true; +"no" }, resume_record: record)
    refute read
    assert_empty @events

    assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
      executor.run(item: @item, secret_reader: -> { +"no" }, resume_record: record.merge("schedule_item_sha256" => "0" * 64))
    end
  end

  # Break caught: publishing partial evidence after a recovery/reset failure.
  def test_failure_resets_if_possible_and_publishes_nothing
    @runtime.define_singleton_method(:recover!) { |**| raise "injected recovery failure" }

    assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
      executor.run(item: @item, secret_reader: -> { +"runtime-only-authority" })
    end

    assert_includes @events.map(&:first), "reset"
    refute_includes @events.map(&:first), "publish"
    assert_nil @artifacts.published
  end

  # Break caught: accepting a snapshot from the right candidate/distribution
  # but the wrong reserve config, source, ledger, or population.
  def test_rejects_snapshot_with_changed_exact_binding_or_population_before_authority_read
    mutations = [
      @snapshot.merge("config_sha256" => "0" * 64),
      @snapshot.merge("ledger" => @ledger.merge("account_roots" => 3)),
      @snapshot.merge("ledger" => @ledger.merge("class_counts" => @ledger.fetch("class_counts").merge("offer" => 2)))
    ]
    mutations.each do |snapshot|
      read = false
      guarded = XrplReserveStudy::CompleteReservesExecutor.new(
        snapshot_provider: ->(_item) { snapshot }, clone_manager: FakeCloneManager.new(@events),
        runtime: @runtime, artifacts: @artifacts, planning_artifacts: @planning_artifacts,
        security: @security, recipe_registry: XrplReserveStudy::OwnerObjectRecipeRegistry.new
      )
      assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
        guarded.run(item: @item, secret_reader: -> { read = true; +"must-not-read" })
      end
      refute read
    end
  end

  # Break caught: a caller could invent a calibrated item, self-hash it, and
  # reach snapshot selection without any published planning-bundle anchor.
  def test_rejects_arbitrary_self_hashed_calibrated_item_before_snapshot_or_secret
    mutations = [
      { "run_id" => "cal-a000011000-o000016500-r01", "account_root_target" => 11_000, "owned_object_target" => 16_500 },
      { "run_id" => "cal-a000010000-o000015000-r02", "repetition" => 2 },
      { "base_reserve_drops" => 500_000 }
    ]
    mutations.each do |changes|
      forged = Marshal.load(Marshal.dump(@item)).merge(changes)
      forged["schedule_item_sha256"] = canonical_sha256(forged.reject { |key, _| key == "schedule_item_sha256" })
      selected = read = false
      guarded = XrplReserveStudy::CompleteReservesExecutor.new(
        snapshot_provider: ->(_item) { selected = true; @snapshot }, clone_manager: FakeCloneManager.new(@events),
        runtime: @runtime, artifacts: @artifacts, planning_artifacts: @planning_artifacts,
        security: @security, recipe_registry: XrplReserveStudy::OwnerObjectRecipeRegistry.new
      )

      assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
        guarded.run(item: forged, secret_reader: -> { read = true; +"must-not-read" })
      end
      refute selected
      refute read
    end
  end

  # Break caught: a successful injected authorizer could start counted work
  # while the result and artifact layer still hard-coded disabled flags.
  def test_rejects_counted_mode_and_authorization_injection_before_secret
    counted = Marshal.load(Marshal.dump(@item))
    counted["counted_run"] = true
    counted["execution_authorized"] = true
    counted["schedule_item_sha256"] = canonical_sha256(counted.reject { |key, _| key == "schedule_item_sha256" })
    read = false

    assert_raises(XrplReserveStudy::CompleteReservesExecutorError) do
      executor.run(item: counted, secret_reader: -> { read = true; +"must-not-read" })
    end
    refute read
    assert_raises(ArgumentError) do
      XrplReserveStudy::CompleteReservesExecutor.new(
        snapshot_provider: ->(_item) { @snapshot }, clone_manager: FakeCloneManager.new(@events),
        runtime: @runtime, artifacts: @artifacts, planning_artifacts: @planning_artifacts,
        authorization: SuccessfulAuthorization.new, security: @security, recipe_registry: XrplReserveStudy::OwnerObjectRecipeRegistry.new
      )
    end
  end

  private

  def executor
    XrplReserveStudy::CompleteReservesExecutor.new(
      snapshot_provider: ->(_item) { @snapshot }, clone_manager: FakeCloneManager.new(@events),
      runtime: @runtime, artifacts: @artifacts, planning_artifacts: @planning_artifacts,
      security: @security, recipe_registry: XrplReserveStudy::OwnerObjectRecipeRegistry.new
    )
  end

  def calibrated_item
    data = {
      "schema_version" => "complete-reserves-calibration-item-v1",
      "run_id" => "cal-a000010000-o000015000-r01", "repetition" => 1,
      "workload_class" => "complete-reserves-security-suite-v1",
      "profile_id" => "complete-reserves-calibrated-v1", "profile_sha256" => PROFILE_SHA256,
      "schedule_sha256" => @schedule.fetch("schedule_sha256"), "security_config_sha256" => @security&.security_config_sha256 || XrplReserveStudy::SecurityWorkload.new.security_config_sha256,
      "benchmark_sha256" => @estimate.fetch("benchmark_sha256"),
      "planning_security_sha256" => @planning_security.fetch("security_sha256"),
      "planning_bindings_sha256" => @planning_bindings_sha256,
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
    data["schedule_item_sha256"] = canonical_sha256(data)
    data.freeze
  end

  def calibrated_class_counts
    kinds = XrplReserveStudy::OwnerObjectRecipeRegistry.new.all.map(&:kind)
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
    baseline = planning_metric("baseline", attempted: 100, artifact: "1" * 64)
    observed = planning_metric("mixed", attempted: 500, artifact: "2" * 64)
    XrplReserveStudy::SecurityWorkload.new.evaluate(baseline: baseline, observed: observed)
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
end
