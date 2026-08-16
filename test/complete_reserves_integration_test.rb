# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesIntegrationTest < Minitest::Test
  PROFILE_PATH = File.expand_path("../study/complete-reserves-profiles-v1.yml", __dir__)
  PROFILE_SHA256 = Digest::SHA256.file(PROFILE_PATH).hexdigest
  DISTRIBUTION_SHA256 = "d" * 64
  CANDIDATE_SHA256 = "c" * 64
  RUN_ID = "cal-a000000002-o000000020-r97"

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
    @ledger = {
      "network_id" => "candidate-task6", "ledger_index" => 25, "ledger_hash" => "f" * 64,
      "account_roots" => 2, "class_counts" => @recipes.all.to_h { |recipe| [recipe.kind, 1] }
    }
    @item = execution_item
    @runtime = FakeIsolatedRuntime.new(state_path: @state_path, ledger: @ledger, item: @item)
    @verifier = XrplReserveStudy::VerifiedStateSnapshot.new(runtime: @runtime, runtime_root: @runtime_root)
    @snapshot = @verifier.publish(identity: snapshot_identity, seed_result: seed_result)
    @runtime.events.clear
    @artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
  end

  def teardown
    FileUtils.rm_rf(@runtime_root)
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
      runtime: @runtime, artifacts: @artifacts, security: XrplReserveStudy::SecurityWorkload.new,
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
      "repetition" => 97, "profile_id" => "complete-reserves-calibrated-v1",
      "profile_sha256" => PROFILE_SHA256, "schedule_sha256" => "b" * 64,
      "security_config_sha256" => XrplReserveStudy::SecurityWorkload.new.security_config_sha256,
      "distribution_sha256" => DISTRIBUTION_SHA256, "candidate_sha256" => CANDIDATE_SHA256,
      "snapshot_id" => "calibration-base", "study_sha256" => "7" * 64,
      "config_sha256" => "6" * 64, "source_sha256" => "5" * 64,
      "ledger_index" => 25, "ledger_hash" => "f" * 64,
      "network_scope" => "isolated-network-only", "account_root_target" => 2,
      "owned_object_target" => 20, "base_reserve_drops" => 1_000_000,
      "owner_reserve_drops" => 200_000, "fee_headroom_drops_per_step" => 20,
      "warmup_seconds" => 300, "measurement_seconds" => 1_800,
      "execution_limits" => { "max_batch_size" => 10, "max_retries" => 0, "deadline_seconds" => 7_200 },
      "status" => "pending", "counted_run" => false, "execution_authorized" => false
    }
    value["schedule_item_sha256"] = Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    value.freeze
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
