# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class StateSnapshotTest < Minitest::Test
  # Break caught: accepting the prior build-result-only interface would publish metadata without a runtime state image.
  def test_rejects_metadata_only_snapshot_publication
    snapshot = XrplReserveStudy::StateSnapshot.new
    identity = { "snapshot_id" => "test-#{Process.pid}-#{rand(1_000_000)}", "candidate_image_digest" => "a" * 64,
                 "study_sha256" => "b" * 64, "distribution_sha256" => "c" * 64,
                 "base_reserve_drops" => 100_000, "owner_reserve_drops" => 20_000, "scale" => 1.5,
                 "expected_account_roots" => 3, "expected_owned_objects" => 5, "database_sha256" => "d" * 64 }
    build = { "run_id" => "build", "attempted_transactions" => 8, "validated_transactions" => 8, "source_build_sha256" => "e" * 64 }
    error = assert_raises(XrplReserveStudy::StateSnapshotError) do
      snapshot.publish(identity: identity, build_result: build)
    end
    assert_equal "metadata-only state snapshots are not valid", error.message
  ensure
    FileUtils.rm_rf(File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves"))
  end
end
