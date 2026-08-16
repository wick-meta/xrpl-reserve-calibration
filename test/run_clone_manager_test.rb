# frozen_string_literal: true

require "fileutils"
require "digest"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class RunCloneManagerTest < Minitest::Test
  class Runtime
    attr_reader :started

    def initialize
      @started = []
    end

    def start_clone!(image:, run:)
      @started << [image.identity, image.state_identity, run]
      true
    end
  end

  class Verifier
    attr_reader :verified

    attr_accessor :after_verify

    def initialize
      @verified = []
    end

    def verify!(snapshot)
      @verified << snapshot
      @after_verify&.call(@verified.length)
      true
    end
  end

  def setup
    @runtime_root = Dir.mktmpdir("run-clone-runtime-")
    @source = File.join(@runtime_root, "snapshots", "seed-1")
    FileUtils.mkdir_p(File.join(@source, "state"))
    File.binwrite(File.join(@source, "state", "ledger.db"), "seed-state")
    @snapshot = {
      "snapshot_id" => "seed-1", "path" => @source, "candidate_image_digest" => "a" * 64,
      "study_sha256" => "b" * 64, "distribution_sha256" => "c" * 64,
      "config_sha256" => "d" * 64, "source_sha256" => "e" * 64,
      "ledger" => { "network_id" => "candidate-private", "ledger_index" => 9, "ledger_hash" => "f" * 64,
                    "account_roots" => 2, "class_counts" => { "offer" => 1 } },
      "files" => [{ "name" => "ledger.db", "bytes" => 10, "sha256" => Digest::SHA256.hexdigest("seed-state") }]
    }
    @verifier = Verifier.new
    @runtime = Runtime.new
    @manager = XrplReserveStudy::RunCloneManager.new(verifier: @verifier, runtime: @runtime, runtime_root: @runtime_root)
  end

  def teardown
    FileUtils.rm_rf(@runtime_root)
  end

  # Break caught: reusing a clone would carry state mutated by an earlier repetition into the next run.
  def test_consumes_exactly_one_clone_per_snapshot_run_and_repetition
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)

    assert File.file?(File.join(clone.fetch("path"), "state", "ledger.db"))
    assert_equal [@snapshot], @verifier.verified
    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.prepare(snapshot: @snapshot, run: run_record) }
    assert_equal "clone destination already exists", error.message
  end

  # Break caught: a clone can be started against a differently bound image, configuration, source, distribution, or ledger.
  def test_rechecks_all_bindings_before_start
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    @manager.start(clone: clone, run: run_record)

    assert_equal 1, @runtime.started.length
    assert_equal run_record, @runtime.started.first.last
    wrong_run = run_record.merge("distribution_sha256" => "0" * 64)
    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.start(clone: clone, run: wrong_run) }
    assert_equal "run does not match clone bindings", error.message
  end

  # Break caught: two starts of the same clone would execute a non-isolated repetition twice.
  def test_start_consumes_the_clone_before_runtime_start
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    @manager.start(clone: clone, run: run_record)

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.start(clone: clone, run: run_record) }
    assert_equal "clone has already been consumed", error.message
    assert_equal 1, @runtime.started.length
  end

  # Break caught: prefix-only containment accepts a forged path with a traversal segment.
  def test_rejects_a_forged_clone_path_with_a_traversal_segment
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    forged = clone.merge("path" => File.join(@runtime_root, "complete-reserves", "clones", "..", "clones", File.basename(clone.fetch("path"))))

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.start(clone: forged, run: run_record) }
    assert_equal "invalid run clone", error.message
    assert_empty @runtime.started
  end

  # Break caught: a symlinked child directory was followed while calculating a clone manifest.
  def test_rejects_a_symlinked_child_directory_in_snapshot_state
    outside = Dir.mktmpdir("run-clone-outside-")
    FileUtils.ln_s(outside, File.join(@source, "state", "linked"))

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) do
      @manager.prepare(snapshot: @snapshot, run: run_record)
    end
    assert_equal "clone state contains symlink or device", error.message
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # Break caught: a caller could substitute a differently verified snapshot after clone preparation.
  def test_rebinds_the_verified_snapshot_before_start
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    forged = clone.merge("snapshot" => @snapshot.merge("config_sha256" => "0" * 64))

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.start(clone: forged, run: run_record) }
    assert_equal "clone does not match verified snapshot", error.message
    assert_empty @runtime.started
  end

  # Break caught: a clone-root symlink could redirect supposedly ignored state outside the checkout runtime.
  def test_rejects_a_symlinked_clone_root
    outside = Dir.mktmpdir("run-clone-root-outside-")
    root = File.join(@runtime_root, "complete-reserves")
    FileUtils.mkdir_p(root)
    FileUtils.ln_s(outside, File.join(root, "clones"))

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) do
      @manager.prepare(snapshot: @snapshot, run: run_record)
    end
    assert_equal "clone root must not contain symlinks", error.message
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # Break caught: a verified clone path was re-resolved after a callback could replace it with a symlink.
  def test_rejects_clone_swap_after_verification_without_consuming_or_starting_replacement
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    replacement = File.join(@runtime_root, "replacement-clone")
    @verifier.after_verify = lambda do |count|
      next unless count == 2

      File.rename(clone.fetch("path"), replacement)
      FileUtils.ln_s(replacement, clone.fetch("path"))
    end

    error = assert_raises(XrplReserveStudy::RunCloneManagerError) do
      @manager.start(clone: clone, run: run_record)
    end

    assert_equal "clone root or directory changed before start", error.message
    refute File.exist?(File.join(replacement, ".consumed"))
    assert_empty @runtime.started
  end

  # Break caught: two concurrent starters could both pass path verification before either consumed the clone.
  def test_concurrent_starters_launch_exactly_one_descriptor_bound_image
    clone = @manager.prepare(snapshot: @snapshot, run: run_record)
    ready = Queue.new
    release = Queue.new

    results = 2.times.map do
      Thread.new do
        ready << true
        release.pop
        begin
          @manager.start(clone: clone, run: run_record)
          :started
        rescue XrplReserveStudy::RunCloneManagerError => error
          error.message
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    outcomes = results.map(&:value)

    assert_equal 1, outcomes.count(:started)
    assert_equal 1, outcomes.count("clone has already been consumed")
    assert_equal 1, @runtime.started.length
  end

  private

  def run_record
    {
      "run_id" => "r0500000-a000010000-n01", "repetition" => 1,
      "candidate_image_digest" => "a" * 64, "study_sha256" => "b" * 64,
      "distribution_sha256" => "c" * 64, "config_sha256" => "d" * 64,
      "source_sha256" => "e" * 64,
      "ledger" => @snapshot.fetch("ledger")
    }
  end
end
