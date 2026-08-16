# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "zlib"
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
    write_minimal_nudb_state(@state)
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
    assert File.file?(File.join(snapshot.fetch("path"), "state", "nudb", "nudb.dat"))
    assert_equal %w[nudb/nudb.dat nudb/nudb.key], snapshot.fetch("files").map { |entry| entry.fetch("name") }
    assert_equal @ledger, snapshot.fetch("ledger")
    assert @publisher.verify!(snapshot)
  end

  # Break caught: a copied state file can change after publication without changing its JSON binding record.
  def test_snapshot_rejects_tampered_real_state
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)
    File.binwrite(File.join(snapshot.fetch("path"), "state", "tampered"), "\xFF".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) { @publisher.verify!(snapshot) }
    assert_equal "snapshot state manifest does not match image", error.message
  end

  # Break caught: runtime directories containing local-identity configuration must never become snapshot artifacts.
  def test_rejects_state_with_local_identity_before_copying
    File.binwrite(File.join(@state, "runtime.conf"), "host=operator-laptop")

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end

    assert_equal "runtime state violates strict artifact policy", error.message
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

  # Break caught: a matching snapshot.json reached through a symlink was treated as the published record.
  def test_rejects_a_symlinked_snapshot_record
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)
    record = File.join(snapshot.fetch("path"), "snapshot.json")
    replacement = File.join(@runtime_root, "replacement-record.json")
    File.rename(record, replacement)
    FileUtils.ln_s(replacement, record)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) { @publisher.verify!(snapshot) }
    assert_equal "snapshot record is not a regular file", error.message
  end

  # Break caught: a root swap after path validation but before state reads made verify! accept a replacement image.
  def test_rejects_snapshot_root_swap_after_descriptor_binding
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)
    replacement = File.join(@runtime_root, "post-bind-replacement")
    @publisher.define_singleton_method(:after_snapshot_bind!) do
      File.rename(snapshot.fetch("path"), replacement)
      FileUtils.ln_s(replacement, snapshot.fetch("path"))
    end

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) { @publisher.verify!(snapshot) }
    assert_equal "snapshot root or ancestor is not the published directory", error.message
  end

  # Break caught: UTF-32 identities were ignored because only UTF-8 and UTF-16 were inspected.
  def test_rejects_machine_identity_in_utf32
    File.binwrite(File.join(@state, "ledger.db"), "machine_id=operator-7".encode("UTF-32LE"))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: lowercase hex encoded local identity was accepted as opaque runtime bytes.
  def test_rejects_lowercase_hex_encoded_machine_identity
    File.binwrite(File.join(@state, "ledger.db"), "machine_id=operator-7".unpack1("H*"))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: a local identity embedded in otherwise binary database bytes bypassed text-only checks.
  def test_rejects_machine_identity_embedded_in_binary_state
    File.binwrite(File.join(@state, "ledger.db"), "\xFF\x00machine_id=operator-7\x00\xFF".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: serialized state could carry identity fields while remaining invalid as a whole text encoding.
  def test_rejects_machine_identity_in_marshaled_state
    File.binwrite(File.join(@state, "ledger.db"), Marshal.dump({ "machine_id" => "operator-7" }))

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: compressed state could hide identity fields from the outer byte scanner.
  def test_rejects_machine_identity_in_gzip_state
    output = StringIO.new("".b, "w")
    Zlib::GzipWriter.wrap(output) { |gzip| gzip.write("machine_id=operator-7") }
    File.binwrite(File.join(@state, "ledger.db"), output.string)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: unknown binary database formats were previously admitted without a parser or allowlist.
  def test_rejects_ambiguous_binary_state
    File.binwrite(File.join(@state, "ledger.db"), "\x01\x02\x03\x04".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: the fake-only policy rejected the NuDB files emitted by the pinned candidate runtime.
  def test_accepts_structurally_valid_rippled_nudb_state
    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)

    names = snapshot.fetch("files").map { |entry| entry.fetch("name") }
    assert_equal %w[nudb/nudb.dat nudb/nudb.key], names
    assert @publisher.verify!(snapshot)
  end

  # Break caught: a filename-only allowlist would admit forged bytes that a candidate NuDB cannot open.
  def test_rejects_malformed_nudb_header
    File.binwrite(File.join(@state, "nudb", "nudb.dat"), "nudb.dat" + "\0" * 84)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: individually plausible NuDB files from different databases cannot form one restartable image.
  def test_rejects_mismatched_nudb_pair
    key = File.binread(File.join(@state, "nudb", "nudb.key"))
    key[10, 8] = [0x1112_1314_1516_1718].pack("Q>")
    File.binwrite(File.join(@state, "nudb", "nudb.key"), key)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: a valid NuDB header must not make embedded machine identity admissible.
  def test_rejects_binary_identity_inside_recognized_nudb_file
    path = File.join(@state, "nudb", "nudb.dat")
    File.binwrite(path, File.binread(path) + "\x00machine_id=operator-7\x00".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: NUL-delimited identity fields in a valid NuDB record bypassed assignment-only scanning.
  def test_rejects_nul_delimited_identity_inside_valid_nudb_record
    add_nudb_record("machine_id\0operator-7".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: an encoded NUL-delimited local identity bypassed raw-byte token matching.
  def test_rejects_encoded_nul_delimited_identity_inside_valid_nudb_record
    add_nudb_record("host\0node-7".encode("UTF-16LE").b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: a unit separator between a sensitive field and value bypassed the NUL-only scrubber.
  def test_rejects_unit_separator_identity_inside_valid_nudb_record
    add_nudb_record("machine_id\x1foperator-7".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: every ASCII control separator, including DEL, is an equivalent identity-field delimiter.
  def test_rejects_all_ascii_control_separated_identities_in_valid_nudb_records
    ((0..31).to_a + [127]).each do |separator|
      write_minimal_nudb_state(@state)
      add_nudb_record("host#{separator.chr}node-7".b)

      assert_raises(XrplReserveStudy::VerifiedStateSnapshotError, "separator 0x#{separator.to_s(16)}") do
        @publisher.publish(identity: identity, seed_result: seed_result)
      end
    end
  end

  # Break caught: control-separated identity fields must be rejected in every supported wide encoding.
  def test_rejects_encoded_control_separated_identities_in_valid_nudb_records
    %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      write_minimal_nudb_state(@state)
      add_nudb_record("endpoint\x1fnode-7".encode(encoding).b)

      assert_raises(XrplReserveStudy::VerifiedStateSnapshotError, encoding) do
        @publisher.publish(identity: identity, seed_result: seed_result)
      end
    end
  end

  # Break caught: printable delimiters were outside the control-separator scrubber.
  def test_rejects_pipe_delimited_identity_inside_valid_nudb_record
    add_nudb_record("machine_id|operator-7".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  # Break caught: delimiter choice, including no delimiter, must not change semantic identity rejection.
  def test_rejects_printable_punctuation_identity_variants_in_valid_nudb_records
    ["|", ".", "/", ",", ";", " ", ""].each do |delimiter|
      write_minimal_nudb_state(@state)
      add_nudb_record("machine_id#{delimiter}operator-7".b)

      assert_raises(XrplReserveStudy::VerifiedStateSnapshotError, delimiter.inspect) do
        @publisher.publish(identity: identity, seed_result: seed_result)
      end
    end
  end

  # Break caught: printable-delimiter semantics must be identical in UTF-8, UTF-16, and UTF-32 payloads.
  def test_rejects_encoded_pipe_delimited_identities_in_valid_nudb_records
    %w[UTF-8 UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      write_minimal_nudb_state(@state)
      add_nudb_record("endpoint|node-7".encode(encoding).b)

      assert_raises(XrplReserveStudy::VerifiedStateSnapshotError, encoding) do
        @publisher.publish(identity: identity, seed_result: seed_result)
      end
    end
  end

  # Break caught: peer discovery endpoints are local cache data, not ledger state, and must not enter clones.
  def test_validates_then_scrubs_peerfinder_sqlite_cache
    File.binwrite(File.join(@state, "peerfinder.sqlite"), minimal_sqlite_database)

    snapshot = @publisher.publish(identity: identity, seed_result: seed_result)

    refute File.exist?(File.join(snapshot.fetch("path"), "state", "peerfinder.sqlite"))
    assert_equal %w[nudb/nudb.dat nudb/nudb.key], snapshot.fetch("files").map { |entry| entry.fetch("name") }
  end

  # Break caught: a known cache filename cannot be used to smuggle arbitrary or identity-bearing bytes.
  def test_rejects_fake_peerfinder_sqlite_cache
    File.binwrite(File.join(@state, "peerfinder.sqlite"), "SQLite format 3\0machine_id=operator-7".b)

    error = assert_raises(XrplReserveStudy::VerifiedStateSnapshotError) do
      @publisher.publish(identity: identity, seed_result: seed_result)
    end
    assert_equal "runtime state violates strict artifact policy", error.message
  end

  private

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

  def minimal_sqlite_database
    bytes = "\0" * 512
    bytes[0, 16] = "SQLite format 3\0"
    bytes[16, 2] = [512].pack("n")
    bytes[18, 6] = [1, 1, 0, 64, 32, 32].pack("C6")
    bytes[24, 4] = [1].pack("N")
    bytes[28, 4] = [1].pack("N")
    bytes[40, 4] = [1].pack("N")
    bytes[44, 4] = [4].pack("N")
    bytes[56, 4] = [1].pack("N")
    bytes[92, 4] = [1].pack("N")
    bytes[100, 8] = [13, 0, 0, 0, 0, 2, 0, 0].pack("C8")
    bytes.b
  end

  def add_nudb_record(payload)
    dat_path = File.join(@state, "nudb", "nudb.dat")
    dat = File.binread(dat_path)
    data_offset = dat.bytesize
    File.binwrite(dat_path, dat + uint48_bytes(payload.bytesize) + ("k" * 32) + payload)

    key_path = File.join(@state, "nudb", "nudb.key")
    key = File.binread(key_path)
    bucket = "\0" * 4096
    bucket[0, 2] = [1].pack("n")
    bucket[8, 18] = uint48_bytes(data_offset) + uint48_bytes(payload.bytesize) + uint48_bytes(1)
    key[4096, 4096] = bucket
    File.binwrite(key_path, key)
  end

  def uint48_bytes(value)
    [value >> 32, value & 0xffff_ffff].pack("nN")
  end

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
