# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class VerifiedStateSnapshotTest < Minitest::Test
  class CheckoutRuntime
    attr_reader :events

    attr_writer :ledger

    def initialize(state_path:, ledger:)
      @state_path = state_path
      @ledger = ledger
      @events = []
    end

    def state_path
      @state_path
    end

    def stop_checkout!
      @events << :stop
    end

    def start_readonly!
      @events << :start_readonly
    end

    def ledger_identity
      @ledger
    end
  end

  def setup
    @runtime_root = Dir.mktmpdir("verified-state-runtime-")
    @state = File.join(@runtime_root, "checkout-state")
    FileUtils.mkdir_p(@state)
    File.binwrite(File.join(@state, "ledger.db"), "ledger-state")
    @ledger = {
      "network_id" => "candidate-private", "ledger_index" => 9,
      "ledger_hash" => "a" * 64, "account_roots" => 2,
      "class_counts" => { "offer" => 1 }
    }
    @runtime = CheckoutRuntime.new(state_path: @state, ledger: @ledger)
    @publisher = XrplReserveStudy::VerifiedStateSnapshot.new(runtime: @runtime, runtime_root: @runtime_root)
  end

  def teardown
    FileUtils.rm_rf(@runtime_root)
  end

  # Break caught: accepting metadata-only snapshots would allow an unverified runtime image to be reused.
  def test_publishes_a_real_state_image_with_a_deterministic_manifest_and_restart_verification
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)

    assert_equal %i[stop start_readonly], @runtime.events
    assert File.file?(File.join(snapshot.fetch("path"), "state", "ledger.db"))
    assert_equal ["ledger.db"], snapshot.fetch("files").map { |entry| entry.fetch("name") }
    assert_equal @ledger, snapshot.fetch("ledger")
    assert @publisher.verify!(snapshot)
  end

  # Break caught: a copied state file can change after publication without changing its JSON binding record.
  def test_snapshot_rejects_tampered_real_state
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)
    File.binwrite(File.join(snapshot.fetch("path"), "state", "tampered"), "x")

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) { @publisher.verify!(snapshot) }
    assert_equal "snapshot state manifest does not match image", error.message
  end

  # Break caught: runtime directories containing local-identity configuration must never become snapshot artifacts.
  def test_rejects_state_with_local_identity_before_copying
    File.binwrite(File.join(@state, "runtime.conf"), "host=operator-laptop")

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end

    assert_equal "runtime state contains prohibited local identity", error.message
    refute Dir.exist?(File.join(@runtime_root, "complete-reserves", "snapshots", identity.fetch("snapshot_id")))
    assert_equal %i[stop start_readonly], @runtime.events
  end

  # Break caught: a post-publish ledger mismatch used to leave a cloneable image behind.
  def test_restart_mismatch_restores_runtime_and_removes_the_published_image
    @runtime.ledger = @ledger.merge("ledger_index" => 10)
    snapshot_id = identity.fetch("snapshot_id")

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity.merge("snapshot_id" => snapshot_id), seed_result: seed_result)
    end

    assert_equal "restart ledger identity does not match seed state", error.message
    assert_equal %i[stop start_readonly], @runtime.events
    refute File.exist?(File.join(@runtime_root, "complete-reserves", "snapshots", snapshot_id))
  end

  # Break caught: checking File.directory? before lstat follows a child-directory symlink.
  def test_rejects_a_symlinked_child_directory
    outside = Dir.mktmpdir("verified-state-outside-")
    FileUtils.ln_s(outside, File.join(@state, "linked"))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end

    assert_equal "runtime state contains symlink or device", error.message
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # Break caught: verify! followed a snapshot-root symlink to a replacement image with matching bytes.
  def test_rejects_snapshot_root_symlink_substitution
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)
    replacement = File.join(@runtime_root, "replacement-image")
    File.rename(snapshot.fetch("path"), replacement)
    FileUtils.ln_s(replacement, snapshot.fetch("path"))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) { @publisher.verify!(snapshot) }
    assert_equal "snapshot root or ancestor is not the published directory", error.message
  end

  # Break caught: machine identity in a UTF-16 runtime file bypassed the old UTF-8 denylist.
  def test_rejects_machine_identity_in_alternate_encoding
    File.binwrite(File.join(@state, "runtime.dat"), "machine_id=operator-7".encode("UTF-16LE"))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: arbitrary metadata fields could carry an operator or machine identity into snapshot admission.
  def test_rejects_unapproved_seed_metadata_keys
    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result.merge("machine_id" => "operator-7"))
    end
    assert_equal "invalid complete reserves seed result", error.message
  end

  private

  def identity
    {
      "snapshot_id" => "snapshot-#{Process.pid}-#{rand(1_000_000)}",
      "candidate_image_digest" => "b" * 64, "study_sha256" => "c" * 64,
      "distribution_sha256" => "d" * 64, "config_sha256" => "e" * 64,
      "source_sha256" => "f" * 64
    }
  end

  def seed_result
    {
      "schema_version" => "complete-reserves-seed-state-v2", "counted_run" => false,
      "classified_ledger_evidence" => @ledger
    }
  end
end
