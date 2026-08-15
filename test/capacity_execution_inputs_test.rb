# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CapacityExecutionInputsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNTIME_ROOT = File.join(ROOT, "capacity", "runtime")
  RUN_ID = "r0500000-a000010000-n01"

  def test_loads_one_exact_preregistered_pilot_and_deeply_freezes_it
    with_bundle do |config_dir, workload_dir|
      loaded = loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir)

      assert_equal RUN_ID, loaded.dig("run", "run_id")
      assert_equal 0.5, loaded.dig("run", "base_reserve_xrp")
      assert_equal Digest::SHA256.file(File.join(config_dir, "rippled.cfg")).hexdigest,
                   loaded.fetch("config_sha256")
      assert_equal %w[accounts.jsonl manifest.json], loaded.fetch("workload_sha256").keys.sort
      assert_equal 1, loaded.dig("intent", "ordinal")
      assert_deeply_frozen loaded
      assert_raises(FrozenError) { loaded.fetch("intent")["ordinal"] = 2 }
    end
  end

  def test_one_account_execution_and_generalized_run_validation_are_equivalent
    with_bundle do |config_dir, workload_dir|
      execution = loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir)
      generalized = XrplReserveStudy::CapacityRunInputs.new.load(
        run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir, expected_pilot_accounts: 1
      )

      assert_equal execution.fetch("run"), generalized.fetch("run")
      assert_equal execution.fetch("config_sha256"), generalized.fetch("config_sha256")
      assert_equal execution.fetch("workload_sha256"), generalized.fetch("workload_sha256")
      assert_equal 1, generalized.fetch("generated_account_count")
      refute generalized.key?("intent")
    end
  end

  def test_rejects_unknown_run_and_paths_outside_runtime
    with_bundle do |config_dir, workload_dir|
      assert_input_error { loader.load(run_id: "not-planned", config_dir: config_dir, workload_dir: workload_dir) }
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: File.join(ROOT, "capacity", "config"), workload_dir: workload_dir) }
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: File.dirname(RUNTIME_ROOT)) }
    end
  end

  def test_rejects_symlinked_roots_directories_and_files
    with_bundle do |config_dir, workload_dir, bundle_root|
      linked_dir = File.join(bundle_root, "linked-config")
      File.symlink(config_dir, linked_dir)
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: linked_dir, workload_dir: workload_dir) }

      moved = File.join(bundle_root, "real-config")
      File.rename(config_dir, moved)
      Dir.mkdir(config_dir)
      File.symlink(File.join(moved, "rippled.cfg"), File.join(config_dir, "rippled.cfg"))
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
  end

  def test_rejects_a_runtime_root_that_is_demonstrably_a_symlink
    publisher = XrplReserveStudy::RuntimePublisher
    original_root = publisher::RUNTIME_ROOT
    FileUtils.mkdir_p(File.dirname(original_root))
    probe_root = Dir.mktmpdir("runtime-root-symlink-probe-", File.dirname(original_root))
    FileUtils.remove_entry(probe_root)

    Dir.mktmpdir do |outside|
      File.symlink(outside, probe_root)
      assert File.symlink?(probe_root), "runtime-root symlink probe was not installed"
      publisher.send(:remove_const, :RUNTIME_ROOT)
      publisher.const_set(:RUNTIME_ROOT, probe_root)

      error = assert_input_error do
        loader.load(
          run_id: RUN_ID,
          config_dir: File.join(probe_root, "config"),
          workload_dir: File.join(probe_root, "workload")
        )
      end
      assert_match(/runtime root must not be a symlink/, error.message)
    ensure
      publisher.send(:remove_const, :RUNTIME_ROOT)
      publisher.const_set(:RUNTIME_ROOT, original_root)
      File.unlink(probe_root) if File.symlink?(probe_root)
    end
  end

  def test_rejects_a_path_swap_that_hides_an_extra_descriptor_bound_entry
    with_bundle do |config_dir, workload_dir, bundle_root|
      File.binwrite(File.join(config_dir, "extra"), "hidden from pathname enumeration")
      clean_config = File.join(bundle_root, "clean-config")
      displaced_config = File.join(bundle_root, "descriptor-bound-config")
      XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: RUN_ID, output_dir: clean_config)
      original_lstat = File.method(:lstat)
      original_children = Dir.method(:children)
      swapped = false
      restored = false

      swapping_lstat = lambda do |path, *arguments|
        stat = original_lstat.call(path, *arguments)
        if path == config_dir && !swapped
          File.rename(config_dir, displaced_config)
          File.rename(clean_config, config_dir)
          swapped = true
        end
        stat
      end
      restoring_children = lambda do |path, *arguments|
        children = original_children.call(path, *arguments)
        if path == config_dir && swapped && !restored
          File.rename(config_dir, clean_config)
          File.rename(displaced_config, config_dir)
          restored = true
        end
        children
      end

      File.stub(:lstat, swapping_lstat) do
        Dir.stub(:children, restoring_children) do
          error = assert_input_error do
            loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir)
          end
          assert_match(/directory entries do not match/, error.message)
        end
      end
      assert swapped, "path-swap adversary did not execute"
    ensure
      if swapped && !restored
        File.rename(config_dir, clean_config) if File.exist?(config_dir)
        File.rename(displaced_config, config_dir) if File.exist?(displaced_config)
      end
    end
  end

  def test_rejects_wrong_directory_entries_and_config_bytes
    with_bundle do |config_dir, workload_dir|
      File.binwrite(File.join(config_dir, "extra"), "x")
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
    with_bundle do |config_dir, workload_dir|
      File.unlink(File.join(config_dir, "rippled.cfg"))
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
    with_bundle do |config_dir, workload_dir|
      File.binwrite(File.join(config_dir, "rippled.cfg"), "altered")
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
    %w[extra missing].each do |mode|
      with_bundle do |config_dir, workload_dir|
        mode == "extra" ? File.binwrite(File.join(workload_dir, "extra"), "x") : File.unlink(File.join(workload_dir, "manifest.json"))
        assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end
  end

  def test_rejects_invalid_missing_duplicate_and_mismatched_checksums
    variants = [
      "not-a-checksum\n",
      "#{'0' * 64}  accounts.jsonl\n",
      "#{'0' * 64}  accounts.jsonl\n#{'1' * 64}  accounts.jsonl\n",
      "#{'0' * 64}  accounts.jsonl\n#{'1' * 64}  manifest.json\n"
    ]
    variants.each do |bytes|
      with_bundle do |config_dir, workload_dir|
        File.binwrite(File.join(workload_dir, "SHA256SUMS"), bytes)
        assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end
  end

  def test_rejects_every_locked_manifest_boundary
    mutations = {
      "run_id" => "r0500000-a000010000-n02",
      "study_id" => "other-study",
      "study_sha256" => "0" * 64,
      "network_id" => 1,
      "source_account" => "rBad",
      "base_reserve_xrp" => 1.0,
      "base_reserve_drops" => 1_000_000,
      "repetition" => 2,
      "generation_scope" => "full-plan",
      "generated_account_count" => 2,
      "planned_account_count" => 25_000,
      "accounts_path" => "other.jsonl",
      "accounts_sha256" => "0" * 64,
      "counted_run" => true,
      "private_keys_generated" => true,
      "signing_state" => "signed"
    }
    mutations.each do |key, value|
      with_bundle do |config_dir, workload_dir|
        mutate_manifest(workload_dir) { |manifest| manifest[key] = value }
        assert_input_error(key) { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end
  end

  def test_rejects_forbidden_keys_at_any_depth
    %w[secret seed private_key signed tx_blob].each do |key|
      with_bundle do |config_dir, workload_dir|
        mutate_manifest(workload_dir) { |manifest| manifest["nested"] = { key => "forbidden" } }
        assert_input_error(key) { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end
  end

  def test_rejects_noncanonical_blank_multiple_and_invalid_intents
    with_bundle do |config_dir, workload_dir|
      record = JSON.parse(File.binread(File.join(workload_dir, "accounts.jsonl")))
      File.binwrite(File.join(workload_dir, "accounts.jsonl"), " #{JSON.generate(record)}\n")
      rewrite_sums(workload_dir)
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
    ["\n", :multiple].each do |variant|
      with_bundle do |config_dir, workload_dir|
        path = File.join(workload_dir, "accounts.jsonl")
        original = File.binread(path)
        File.binwrite(path, variant == :multiple ? original * 2 : variant)
        rewrite_sums(workload_dir)
        assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end

    mutations = {
      "ordinal" => 2,
      "transaction_type" => "OfferCreate",
      "source_account" => "rBad",
      "destination_account" => "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",
      "amount_drops" => "500001",
      "network_id" => 1
    }
    mutations.each do |key, value|
      with_bundle do |config_dir, workload_dir|
        mutate_record(workload_dir) { |record| record[key] = value }
        assert_input_error(key) { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
      end
    end
    with_bundle do |config_dir, workload_dir|
      mutate_record(workload_dir) { |record| record["destination_account"] = "rMalformed" }
      assert_input_error { loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir) }
    end
  end

  def test_rejects_a_valid_nonreserved_destination_from_a_different_ordinal
    substituted_destination = "rwKFceaiJ3eFYUYWrhAamfV8Z4wei5FJxq"
    with_bundle do |config_dir, workload_dir|
      mutate_record(workload_dir) { |record| record["destination_account"] = substituted_destination }

      error = assert_input_error do
        loader.load(run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir)
      end
      assert_match(/planned run/, error.message)
    end
  end

  private

  def loader
    XrplReserveStudy::CapacityExecutionInputs.new
  end

  def with_bundle
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("execution-inputs-", RUNTIME_ROOT) do |root|
      config_dir = File.join(root, "config")
      workload_dir = File.join(root, "workload")
      XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: RUN_ID, output_dir: config_dir)
      XrplReserveStudy::WorkloadGenerator.new.generate(
        run_id: RUN_ID, scope: "pilot", pilot_accounts: 1, output_dir: workload_dir
      )
      yield config_dir, workload_dir, root
    end
  end

  def mutate_manifest(directory)
    path = File.join(directory, "manifest.json")
    manifest = JSON.parse(File.binread(path))
    yield manifest
    File.binwrite(path, "#{JSON.pretty_generate(manifest)}\n")
    rewrite_sums(directory)
  end

  def mutate_record(directory)
    path = File.join(directory, "accounts.jsonl")
    record = JSON.parse(File.binread(path))
    yield record
    File.binwrite(path, "#{JSON.generate(record)}\n")
    mutate_manifest(directory) { |manifest| manifest["accounts_sha256"] = Digest::SHA256.file(path).hexdigest }
  end

  def rewrite_sums(directory)
    bytes = %w[accounts.jsonl manifest.json].map do |name|
      "#{Digest::SHA256.file(File.join(directory, name)).hexdigest}  #{name}\n"
    end.join
    File.binwrite(File.join(directory, "SHA256SUMS"), bytes)
  end

  def assert_input_error(label = nil, &block)
    error = assert_raises(XrplReserveStudy::CapacityExecutionInputError, label, &block)
    refute_empty error.message
    error
  end

  def assert_deeply_frozen(value)
    assert value.frozen?, "#{value.class} was mutable"
    case value
    when Hash
      value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array
      value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
