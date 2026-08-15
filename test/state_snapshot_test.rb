# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class StateSnapshotTest < Minitest::Test
  def test_binds_full_identity_and_rejects_clone_reuse
    snapshot = XrplReserveStudy::StateSnapshot.new
    identity = { "snapshot_id" => "test-#{Process.pid}-#{rand(1_000_000)}", "candidate_image_digest" => "a" * 64,
                 "study_sha256" => "b" * 64, "distribution_sha256" => "c" * 64,
                 "base_reserve_drops" => 100_000, "owner_reserve_drops" => 20_000, "scale" => 1.5,
                 "expected_account_roots" => 3, "expected_owned_objects" => 5, "database_sha256" => "d" * 64 }
    build = { "run_id" => "build", "attempted_transactions" => 8, "validated_transactions" => 8, "source_build_sha256" => "e" * 64 }
    record = snapshot.publish(identity: identity, build_result: build)
    clone = snapshot.clone_for(run: { "run_id" => "clone-#{identity.fetch('snapshot_id')}" })
    assert_equal identity.fetch("distribution_sha256"), record.fetch("distribution_sha256")
    assert File.file?(File.join(clone.fetch("path"), "snapshot.json"))
    assert_raises(XrplReserveStudy::StateSnapshotError) { snapshot.clone_for(run: { "run_id" => clone.fetch("run_id") }) }
  ensure
    FileUtils.rm_rf(File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, "complete-reserves"))
  end
end
