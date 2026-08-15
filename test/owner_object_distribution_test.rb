# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class OwnerObjectDistributionTest < Minitest::Test
  MANIFEST = File.expand_path("../study/owner-object-endpoints-v1.yml", __dir__)
  COMMIT = "a" * 40
  HASH = "A" * 64

  FakeObserver = Struct.new(:endpoint, :ledger_hash, :entries, keyword_init: true) do
    def preflight
      body = JSON.generate("endpoint" => endpoint, "latest" => 100)
      {
        "endpoint" => endpoint, "latest_validated_ledger" => 100,
        "latest_validated_hash" => ledger_hash, "validated_ledger_age_seconds" => 1,
        "server_state" => "full", "raw_response_sha256" => Digest::SHA256.hexdigest(body),
        "raw_response" => body
      }
    end

    def capture_exact(ledger_index:)
      body = JSON.generate("endpoint" => endpoint, "ledger_index" => ledger_index, "entries" => entries)
      {
        "endpoint" => endpoint, "ledger_index" => ledger_index, "ledger_hash" => ledger_hash,
        "entries" => entries, "raw_response_sha256" => Digest::SHA256.hexdigest(body),
        "raw_response" => body, "page_sha256" => [Digest::SHA256.hexdigest(body)]
      }
    end
  end

  def test_accepts_exact_two_operator_bundle_and_scales_deterministically
    distribution = distribution_with(
      "https://honeycluster.io/" => FakeObserver.new(endpoint: "https://honeycluster.io/", ledger_hash: HASH, entries: entries),
      "https://s2.ripple.com:51234/" => FakeObserver.new(endpoint: "https://s2.ripple.com:51234/", ledger_hash: HASH, entries: entries)
    )

    Dir.mktmpdir do |parent|
      output = File.join(parent, "bundle")
      bundle = distribution.capture(output_dir: output, source_commit: COMMIT)
      loaded = distribution.load(output)

      assert_equal "agreed", bundle.fetch("status")
      assert_equal "independently_corroborated", bundle.fetch("evidence_tier")
      assert_equal 8, loaded.population_targets(scale: 1.0).fetch("account_roots")
      assert_equal 12, loaded.population_targets(scale: 1.5).fetch("owned_objects")
      assert_equal({ "offer" => 5, "trust_line" => 3 }, loaded.class_allocations(scale: 1.0))
      assert_equal 12, loaded.class_allocations(scale: 1.5).values.sum
      assert loaded.frozen?
      assert loaded.fetch("class_counts").frozen?
      assert File.file?(File.join(output, "owner-object-distribution.json"))
      assert_equal 4, Dir[File.join(output, "raw", "*.json")].length
    end
  end

  def test_accepts_a_single_operator_bundle_as_operator_local_evidence
    Dir.mktmpdir do |parent|
      manifest = File.join(parent, "operator-local.yml")
      File.write(manifest, <<~YAML)
        schema_version: owner-object-endpoint-manifest-v1
        minimum_required_operators: 1
        selection_rule: minimum-latest-validated-ledger
        health_gate:
          max_validated_ledger_age_seconds: 120
          max_latest_ledger_spread: 50
          allowed_server_states: [full]
        endpoints:
          - endpoint_id: operator-local-mainnet
            operator_id: operator-local
            url: https://operator.example/
      YAML
      distribution = XrplReserveStudy::OwnerObjectDistribution.new(
        manifest_path: manifest,
        observer_factory: ->(_endpoint) { FakeObserver.new(endpoint: "https://operator.example/", ledger_hash: HASH, entries: entries) }
      )
      output = File.join(parent, "bundle")

      bundle = distribution.capture(output_dir: output, source_commit: COMMIT)
      loaded = distribution.load(output)

      assert_equal "captured", bundle.fetch("status")
      assert_equal "operator_local", bundle.fetch("evidence_tier")
      assert_equal 8, loaded.fetch("account_roots")
    end
  end

  def test_rejects_disagreement_without_publishing_a_bundle
    distribution = distribution_with(
      "https://honeycluster.io/" => FakeObserver.new(endpoint: "https://honeycluster.io/", ledger_hash: HASH, entries: entries),
      "https://s2.ripple.com:51234/" => FakeObserver.new(endpoint: "https://s2.ripple.com:51234/", ledger_hash: "B" * 64, entries: entries)
    )

    Dir.mktmpdir do |parent|
      output = File.join(parent, "rejected")
      assert_raises(XrplReserveStudy::OwnerObjectDistributionError) do
        distribution.capture(output_dir: output, source_commit: COMMIT)
      end
      refute File.exist?(output)
    end
  end

  def test_rejects_unknown_ledger_entry_types
    bad_entries = entries + [{ "LedgerEntryType" => "NotALedgerEntry" }]
    distribution = distribution_with(
      "https://honeycluster.io/" => FakeObserver.new(endpoint: "https://honeycluster.io/", ledger_hash: HASH, entries: bad_entries),
      "https://s2.ripple.com:51234/" => FakeObserver.new(endpoint: "https://s2.ripple.com:51234/", ledger_hash: HASH, entries: bad_entries)
    )

    Dir.mktmpdir do |parent|
      assert_raises(XrplReserveStudy::OwnerObjectDistributionError) do
        distribution.capture(output_dir: File.join(parent, "bad"), source_commit: COMMIT)
      end
    end
  end

  private

  def entries
    Array.new(8) { { "LedgerEntryType" => "AccountRoot" } } +
      Array.new(5) { { "LedgerEntryType" => "Offer" } } +
      Array.new(3) { { "LedgerEntryType" => "RippleState" } }
  end

  def distribution_with(observers)
    XrplReserveStudy::OwnerObjectDistribution.new(
      manifest_path: MANIFEST,
      observer_factory: ->(endpoint) { observers.fetch(endpoint) }
    )
  end
end
