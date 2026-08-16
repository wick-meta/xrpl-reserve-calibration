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

    def start_clone!(path:, run:)
      @started << [path, run]
      true
    end
  end

  class Verifier
    attr_reader :verified

    def initialize
      @verified = []
    end

    def verify!(snapshot)
      @verified << snapshot
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

    assert_equal [[clone.fetch("path"), run_record]], @runtime.started
    wrong_run = run_record.merge("distribution_sha256" => "0" * 64)
    error = assert_raises(XrplReserveStudy::RunCloneManagerError) { @manager.start(clone: clone, run: wrong_run) }
    assert_equal "run does not match clone bindings", error.message
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
