# frozen_string_literal: true

require "digest"

module CompleteReservesPlanningFixture
  PROFILE_PATH = File.expand_path("../study/complete-reserves-profiles-v1.yml", __dir__)
  DISTRIBUTION = { "account_roots" => 8_000_000, "owned_objects" => 12_000_000 }.freeze
  DISTRIBUTION_SHA256 = "d" * 64
  CANDIDATE_SHA256 = "c" * 64

  private

  def benchmark
    XrplReserveStudy::ProvisioningBenchmark.new(
      distribution: DISTRIBUTION,
      distribution_sha256: DISTRIBUTION_SHA256,
      candidate_sha256: CANDIDATE_SHA256,
      profile_path: PROFILE_PATH
    )
  end

  def full_profile
    XrplReserveStudy::CompleteReservesProfile.new(PROFILE_PATH).full_matrix_cells(distribution: DISTRIBUTION)
  end

  def measured_samples
    [10_000, 25_000, 50_000, 1_000_000].map.with_index do |accounts, index|
      objects = accounts * 3 / 2
      work = accounts + objects
      {
        "schema_version" => "complete-reserves-provisioning-sample-v1",
        "profile_id" => "complete-reserves-calibrated-v1",
        "profile_sha256" => Digest::SHA256.file(PROFILE_PATH).hexdigest,
        "distribution_sha256" => DISTRIBUTION_SHA256,
        "candidate_sha256" => CANDIDATE_SHA256,
        "account_root_target" => accounts,
        "owned_object_target" => objects,
        "measurement_source" => "observed",
        "network_scope" => "isolated-network-only",
        "counted_run" => false,
        "build_wall_seconds" => work / 100.0,
        "snapshot_wall_seconds" => work / 1_000.0,
        "clone_wall_seconds" => work / 2_000.0,
        "reset_wall_seconds" => 4.0 + index,
        "recovery_wall_seconds" => 5.0 + index,
        "allocated_logical_cpus" => 4,
        "cpu_seconds" => work / 200.0,
        "peak_memory_bytes" => work * 1_000,
        "state_disk_bytes" => work * 2_000,
        "io_read_bytes" => work * 20,
        "io_write_bytes" => work * 40,
        "attempted_transactions" => work,
        "validated_transactions" => work,
        "burned_fees_drops" => work * 10,
        "locked_xrp_drops" => work * 200_000,
        "released_xrp_drops" => objects * 100_000,
        "ledger_growth_bytes" => work * 500,
        "database_growth_bytes" => work * 800,
        "ledger_close_seconds_p95" => 4.0,
        "max_queue_depth" => 10,
        "finality_seconds_p95" => 5.0,
        "reset_confirmed" => true,
        "recovery_confirmed" => true,
        "snapshot_sha256" => format("%064x", accounts),
        "artifact_sha256" => format("%064x", accounts + 1)
      }
    end
  end
end
