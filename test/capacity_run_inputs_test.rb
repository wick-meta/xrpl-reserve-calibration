# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "timeout"
require_relative "../lib/xrpl_reserve_study"

class CapacityRunInputsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNTIME_ROOT = File.join(ROOT, "capacity", "runtime")
  RUN_ID = "r0500000-a000010000-n01"
  PILOT_ACCOUNTS = 3

  def test_loads_an_exact_multi_account_pilot_without_retaining_account_lines
    with_bundle do |config_dir, workload_dir|
      loaded = XrplReserveStudy::CapacityRunInputs.new.load(
        run_id: RUN_ID,
        config_dir: config_dir,
        workload_dir: workload_dir,
        expected_pilot_accounts: PILOT_ACCOUNTS
      )

      assert_equal %w[accounts_sha256 config_sha256 generated_account_count generation_scope run workload_sha256],
                   loaded.keys.sort
      assert_equal RUN_ID, loaded.dig("run", "run_id")
      assert_equal "pilot", loaded.fetch("generation_scope")
      assert_equal PILOT_ACCOUNTS, loaded.fetch("generated_account_count")
      assert_equal Digest::SHA256.file(File.join(workload_dir, "accounts.jsonl")).hexdigest,
                   loaded.fetch("accounts_sha256")
      refute_includes JSON.generate(loaded), "destination_account"
      assert_deeply_frozen loaded
    end
  end

  def test_rejects_count_scope_record_and_descriptor_bound_mutations
    with_bundle do |config_dir, workload_dir|
      assert_input_error do
        load_inputs(config_dir, workload_dir, expected_pilot_accounts: 2)
      end
    end

    with_bundle do |config_dir, workload_dir|
      mutate_manifest(workload_dir) { |manifest| manifest["generation_scope"] = "full-plan" }
      assert_input_error { load_inputs(config_dir, workload_dir) }
    end

    with_bundle do |config_dir, workload_dir|
      records = File.readlines(File.join(workload_dir, "accounts.jsonl"), chomp: true)
      record = JSON.parse(records.fetch(1))
      record["ordinal"] = 9
      records[1] = JSON.generate(record)
      File.binwrite(File.join(workload_dir, "accounts.jsonl"), "#{records.join("\n")}\n")
      repair_manifest_and_sums(workload_dir)
      assert_input_error { load_inputs(config_dir, workload_dir) }
    end

    with_bundle do |config_dir, workload_dir|
      File.binwrite(File.join(workload_dir, "extra"), "x")
      assert_input_error { load_inputs(config_dir, workload_dir) }
    end
  end

  def test_rejects_checksum_canonical_address_network_and_forbidden_key_mutations
    with_bundle do |config_dir, workload_dir|
      File.binwrite(File.join(workload_dir, "accounts.jsonl"), "{}\n")
      assert_input_error { load_inputs(config_dir, workload_dir) }
    end

    {
      "noncanonical" => ->(record) { " #{JSON.generate(record)}" },
      "destination" => ->(record) { record.merge("destination_account" => "rMalformed").then { |r| JSON.generate(r) } },
      "network" => ->(record) { record.merge("network_id" => 1).then { |r| JSON.generate(r) } },
      "forbidden" => ->(record) { record.merge("secret" => "no").then { |r| JSON.generate(r) } }
    }.each_value do |mutation|
      with_bundle do |config_dir, workload_dir|
        path = File.join(workload_dir, "accounts.jsonl")
        lines = File.readlines(path, chomp: true)
        lines[1] = mutation.call(JSON.parse(lines.fetch(1)))
        File.binwrite(path, "#{lines.join("\n")}\n")
        repair_manifest_and_sums(workload_dir)
        assert_input_error { load_inputs(config_dir, workload_dir) }
      end
    end
  end

  def test_accepts_the_planned_count_only_when_the_bundle_is_still_a_pilot
    planned_count = 10_000
    with_bundle(pilot_accounts: planned_count) do |config_dir, workload_dir|
      loaded = load_inputs(config_dir, workload_dir, expected_pilot_accounts: planned_count)
      assert_equal planned_count, loaded.fetch("generated_account_count")
    end

    with_bundle(pilot_accounts: nil, scope: "full-plan") do |config_dir, workload_dir|
      assert_input_error do
        load_inputs(config_dir, workload_dir, expected_pilot_accounts: planned_count)
      end
    end
  end

  def test_fifo_input_entry_fails_within_a_finite_bound
    with_bundle do |config_dir, workload_dir|
      path = File.join(workload_dir, "accounts.jsonl")
      File.unlink(path)
      assert system("mkfifo", path)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_input_error { Timeout.timeout(1) { load_inputs(config_dir, workload_dir) } }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end
  end

  private

  def load_inputs(config_dir, workload_dir, expected_pilot_accounts: PILOT_ACCOUNTS)
    XrplReserveStudy::CapacityRunInputs.new.load(
      run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir,
      expected_pilot_accounts: expected_pilot_accounts
    )
  end

  def with_bundle(pilot_accounts: PILOT_ACCOUNTS, scope: "pilot")
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("run-inputs-", RUNTIME_ROOT) do |root|
      config_dir = File.join(root, "config")
      workload_dir = File.join(root, "workload")
      XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: RUN_ID, output_dir: config_dir)
      XrplReserveStudy::WorkloadGenerator.new.generate(
        run_id: RUN_ID, scope: scope, pilot_accounts: pilot_accounts, output_dir: workload_dir
      )
      yield config_dir, workload_dir
    end
  end

  def mutate_manifest(directory)
    path = File.join(directory, "manifest.json")
    manifest = JSON.parse(File.binread(path))
    yield manifest
    File.binwrite(path, "#{JSON.pretty_generate(manifest)}\n")
    rewrite_sums(directory)
  end

  def repair_manifest_and_sums(directory)
    accounts = File.join(directory, "accounts.jsonl")
    mutate_manifest(directory) do |manifest|
      manifest["accounts_sha256"] = Digest::SHA256.file(accounts).hexdigest
    end
  end

  def rewrite_sums(directory)
    bytes = %w[accounts.jsonl manifest.json].map do |name|
      "#{Digest::SHA256.file(File.join(directory, name)).hexdigest}  #{name}\n"
    end.join
    File.binwrite(File.join(directory, "SHA256SUMS"), bytes)
  end

  def assert_input_error(&block)
    error = assert_raises(XrplReserveStudy::CapacityRunInputError, &block)
    refute_empty error.message
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash then value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array then value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
