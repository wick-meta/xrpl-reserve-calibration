# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "fileutils"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesWorkloadTest < Minitest::Test
  def test_generates_deterministic_account_and_object_intents_without_keys
    distribution = { "account_roots" => 2, "class_counts" => { "offer" => 2, "trust_line" => 1 } }
    run = XrplReserveStudy::CompleteReservesStudy.new(File.expand_path("../study/complete-reserves-v1.yml", __dir__))
                                                    .plan(distribution: { "account_roots" => 2, "owned_objects" => 3 })
                                                    .fetch("runs").find { |candidate| candidate.fetch("scale") == 1.0 }
    with_runtime_directory do |directory|
      result = XrplReserveStudy::CompleteReservesWorkload.new.generate(run: run, distribution: distribution, output_dir: File.join(directory, "workload"))
      manifest = JSON.parse(File.binread(File.join(directory, "workload", "manifest.json")))
      assert_equal 2, result.fetch("account_intent_count")
      assert_equal 3, result.fetch("object_intent_count")
      assert_equal false, manifest.fetch("private_keys_generated")
      objects = File.readlines(File.join(directory, "workload", "objects.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[controller_ordinal object_type ordinal owner], objects.map { |record| record.keys.sort }.uniq.first
      assert objects.all? { |record| record.fetch("controller_ordinal").between?(1, 2) }
    end
  end

  def test_rejects_unknown_object_class_and_an_altered_locked_run
    distribution = { "account_roots" => 2, "class_counts" => { "not_an_object" => 1 } }
    run = { "run_id" => "not-a-locked-run", "scale" => 1.0 }
    error = assert_raises(XrplReserveStudy::CompleteReservesWorkloadError) do
      XrplReserveStudy::CompleteReservesWorkload.new.generate(run: run, distribution: distribution, output_dir: runtime_path("bad"))
    end
    assert_match(/invalid distribution/, error.message)
  end

  private

  def with_runtime_directory
    directory = File.expand_path("../capacity/runtime/complete-reserves-workload-test-#{Process.pid}-#{rand(1_000_000)}", __dir__)
    yield directory
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  def runtime_path(name)
    File.expand_path("../capacity/runtime/complete-reserves-workload-test-#{Process.pid}-#{name}", __dir__)
  end
end
