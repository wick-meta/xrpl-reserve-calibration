# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class BaselineBundleTest < Minitest::Test
  MANIFEST = File.expand_path("../study/mainnet-endpoints-v1.yml", __dir__)

  FakeObserver = Struct.new(:endpoint, :latest, :hash, :age, :state, keyword_init: true) do
    def preflight
      body = JSON.generate("endpoint" => endpoint, "latest" => latest)
      {
        "endpoint" => endpoint,
        "latest_validated_ledger" => latest,
        "latest_validated_hash" => hash,
        "validated_ledger_age_seconds" => age || 1,
        "server_state" => state,
        "raw_response_sha256" => Digest::SHA256.hexdigest(body),
        "raw_response" => body
      }
    end

    def capture_exact(ledger_index:)
      body = JSON.generate("endpoint" => endpoint, "ledger_index" => ledger_index)
      {
        "schema_version" => "mainnet-baseline-v2",
        "observed_at" => "2026-08-03T00:00:00Z",
        "endpoint" => endpoint,
        "ledger_index" => ledger_index,
        "ledger_hash" => hash,
        "reserve_base_drops" => 1_000_000,
        "reserve_increment_drops" => 200_000,
        "fee_settings_index" => XrplReserveStudy::MainnetObserver::FEE_SETTINGS_INDEX,
        "raw_response_sha256" => Digest::SHA256.hexdigest(body),
        "raw_response" => body
      }
    end
  end

  def test_selects_minimum_latest_ledger_and_requires_agreement
    latest = {
      "https://honeycluster.io/" => 103,
      "https://s2.ripple.com:51234/" => 104
    }
    hash = "A" * 64
    factory = lambda do |endpoint|
      FakeObserver.new(endpoint: endpoint, latest: latest.fetch(endpoint), hash: hash, state: "full")
    end

    Dir.mktmpdir do |parent|
      output = File.join(parent, "bundle")
      bundle = XrplReserveStudy::BaselineBundle.new(
        manifest_path: MANIFEST,
        observer_factory: factory
      ).capture(output_dir: output, source_commit: "a" * 40)

      assert_equal 103, bundle.fetch("target_ledger_index")
      assert_equal "agreed", bundle.fetch("status")
      assert_equal 2, bundle.fetch("observations").length
      assert File.file?(File.join(output, "baseline.json"))
      assert_equal 4, Dir[File.join(output, "raw", "*.json")].length
    end
  end

  def test_rejects_stale_or_disconnected_preflight_without_exact_queries
    factory = lambda do |endpoint|
      latest = endpoint.include?("honeycluster") ? 100 : 200
      state = endpoint.include?("honeycluster") ? "disconnected" : "full"
      FakeObserver.new(endpoint: endpoint, latest: latest, hash: "A" * 64, age: 200, state: state)
    end

    Dir.mktmpdir do |parent|
      output = File.join(parent, "rejected")
      bundle = XrplReserveStudy::BaselineBundle.new(
        manifest_path: MANIFEST,
        observer_factory: factory
      ).capture(output_dir: output, source_commit: "a" * 40)

      assert_equal "preflight_rejected", bundle.fetch("status")
      assert_nil bundle.fetch("target_ledger_index")
      assert_empty bundle.fetch("observations")
      refute_empty bundle.fetch("failures")
      assert_equal 2, Dir[File.join(output, "raw", "*.json")].length
    end
  end

  def test_preserves_partial_capture_when_exact_query_fails
    failing_observer = Class.new(FakeObserver) do
      def capture_exact(ledger_index:)
        raise XrplReserveStudy::ObservationError, "simulated exact query failure"
      end
    end
    factory = lambda do |endpoint|
      klass = endpoint.include?("honeycluster") ? failing_observer : FakeObserver
      klass.new(endpoint: endpoint, latest: 200, hash: "A" * 64, age: 1, state: "full")
    end

    Dir.mktmpdir do |parent|
      output = File.join(parent, "failed")
      bundle = XrplReserveStudy::BaselineBundle.new(
        manifest_path: MANIFEST,
        observer_factory: factory
      ).capture(output_dir: output, source_commit: "a" * 40)

      assert_equal "capture_failed", bundle.fetch("status")
      assert_equal 200, bundle.fetch("target_ledger_index")
      assert_equal 1, bundle.fetch("observations").length
      assert_equal "honeycluster-mainnet", bundle.fetch("failures").first.fetch("endpoint_id")
      assert_equal 3, Dir[File.join(output, "raw", "*.json")].length
    end
  end

  def test_rejects_existing_output_directory
    Dir.mktmpdir do |output|
      bundle = XrplReserveStudy::BaselineBundle.new(manifest_path: MANIFEST)
      assert_raises(XrplReserveStudy::ObservationError) do
        bundle.capture(output_dir: output, source_commit: "a" * 40)
      end
    end
  end
end
