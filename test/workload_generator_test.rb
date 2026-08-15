# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class WorkloadGeneratorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNTIME_ROOT = File.join(ROOT, "capacity", "runtime")
  PILOT_RUN_ID = "r0500000-a000010000-n01"
  ZERO_ACCOUNT = "rrrrrrrrrrrrrrrrrrrrrhoLvTp"
  ONE_ACCOUNT = "rrrrrrrrrrrrrrrrrrrrBZbvji"

  def test_encodes_the_zero_account_id_with_the_canonical_xrpl_vector
    assert_equal "rrrrrrrrrrrrrrrrrrrrrhoLvTp",
                 XrplReserveStudy::WorkloadGenerator.encode_account_id("\0" * 20)
  end

  def test_generates_compact_unsigned_payment_intents_and_deterministic_manifest
    with_runtime_directory do |directory|
      output_dir = File.join(directory, "pilot")
      result = XrplReserveStudy::WorkloadGenerator.new.generate(
        run_id: PILOT_RUN_ID,
        scope: "pilot",
        pilot_accounts: 3,
        output_dir: output_dir
      )

      assert_equal ["SHA256SUMS", "accounts.jsonl", "manifest.json"], Dir.children(output_dir).sort
      records = File.readlines(File.join(output_dir, "accounts.jsonl"), chomp: true).map do |line|
        assert_equal line, JSON.generate(JSON.parse(line))
        JSON.parse(line)
      end
      assert_equal [1, 2, 3], records.map { |record| record.fetch("ordinal") }
      records.each do |record|
        assert_equal "Payment", record.fetch("transaction_type")
        assert_equal "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", record.fetch("source_account")
        assert_match(/\Ar[#{Regexp.escape(XrplReserveStudy::WorkloadGenerator::BASE58_ALPHABET)}]+\z/,
                     record.fetch("destination_account"))
        assert_equal "500000", record.fetch("amount_drops")
        assert_equal 21_338, record.fetch("network_id")
        assert_equal %w[amount_drops destination_account network_id ordinal source_account transaction_type],
                     record.keys.sort
      end
      assert_equal records.map { |record| record.fetch("destination_account") }.uniq.length, records.length

      accounts_bytes = File.binread(File.join(output_dir, "accounts.jsonl"))
      manifest = JSON.parse(File.binread(File.join(output_dir, "manifest.json")))
      expected_manifest = {
        "schema_version" => "capacity-workload-v1",
        "study_id" => "reserve-calibration-v1",
        "study_sha256" => "4d00f2bd5c8a189be7f215c94e7baf9f455dc663429c509ae16ced95fda5c216",
        "run_id" => PILOT_RUN_ID,
        "workload_name" => "accountroot-create-and-hold-v1",
        "generation_scope" => "pilot",
        "counted_run" => false,
        "base_reserve_xrp" => 0.5,
        "base_reserve_drops" => 500_000,
        "planned_account_count" => 10_000,
        "generated_account_count" => 3,
        "repetition" => 1,
        "network_id" => 21_338,
        "source_account" => "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",
        "destination_model" => "keyless-synthetic-account-id-v1",
        "private_keys_generated" => false,
        "signing_state" => "unsigned-intents",
        "account_id_derivation" => "sha256(input)[0,20], input=xrpl-reserve-calibration/keyless-account-id-v1\\0<study_id>\\0<random_seed>\\0<run_id>\\0<ordinal>; reserved retry=sha256(input||\\0retry\\0<N>)[0,20]; address=base58(version-byte-0||account-id||first-4(double-sha256(version-byte-0||account-id))), alphabet=rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz",
        "accounts_path" => "accounts.jsonl",
        "accounts_sha256" => Digest::SHA256.hexdigest(accounts_bytes)
      }
      assert_equal expected_manifest, manifest
      assert_equal 3, result.fetch("generated_account_count")
      assert_equal expected_manifest.fetch("accounts_sha256"), result.dig("artifact_sha256", "accounts.jsonl")
      assert_equal Digest::SHA256.file(File.join(output_dir, "manifest.json")).hexdigest,
                   result.dig("artifact_sha256", "manifest.json")
    end
  end

  def test_pilot_is_an_exact_prefix_of_full_plan_and_bytes_are_directory_independent
    with_runtime_directory do |directory|
      pilot_a = File.join(directory, "pilot-a")
      pilot_b = File.join(directory, "nested", "pilot-b")
      full = File.join(directory, "full")
      generator = XrplReserveStudy::WorkloadGenerator.new
      generator.generate(run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 7, output_dir: pilot_a)
      generator.generate(run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 7, output_dir: pilot_b)
      generator.generate(run_id: PILOT_RUN_ID, scope: "full-plan", output_dir: full)

      assert_equal File.binread(File.join(pilot_a, "accounts.jsonl")),
                   File.binread(File.join(pilot_b, "accounts.jsonl"))
      assert_equal File.binread(File.join(pilot_a, "manifest.json")),
                   File.binread(File.join(pilot_b, "manifest.json"))
      pilot_lines = File.readlines(File.join(pilot_a, "accounts.jsonl"))
      full_lines = File.readlines(File.join(full, "accounts.jsonl"))
      assert_equal 7, pilot_lines.length
      assert_equal 10_000, full_lines.length
      assert_equal pilot_lines, full_lines.first(7)

      destinations = full_lines.map { |line| JSON.parse(line).fetch("destination_account") }
      assert_equal 10_000, destinations.uniq.length
      refute_includes destinations, ZERO_ACCOUNT
      refute_includes destinations, ONE_ACCOUNT
    end
  end

  def test_reserved_account_ids_retry_with_numbered_suffixes_until_an_allowed_digest
    digests = [
      ("\0" * 32).b,
      (("\0" * 19) + "\1" + ("\0" * 12)).b,
      (("\2" * 20) + ("\0" * 12)).b
    ]
    inputs = []
    account_id_digest = lambda do |bytes|
      inputs << bytes
      digests.shift || raise("unexpected extra digest")
    end
    generator = XrplReserveStudy::WorkloadGenerator.new
    refute generator.respond_to?(:digest_account_id_input), "digest boundary must not be public"
    supports_private_digest_boundary = generator.respond_to?(:digest_account_id_input, true)
    assert supports_private_digest_boundary, "WorkloadGenerator must keep a private digest boundary"
    return unless supports_private_digest_boundary

    with_runtime_directory do |directory|
      output_dir = File.join(directory, "retry")
      generator.stub(:digest_account_id_input, account_id_digest) do
        generator.generate(
          run_id: PILOT_RUN_ID,
          scope: "pilot",
          pilot_accounts: 1,
          output_dir: output_dir
        )
      end

      base = [
        "xrpl-reserve-calibration/keyless-account-id-v1",
        "reserve-calibration-v1",
        "260803",
        PILOT_RUN_ID,
        "1"
      ].join("\0").b
      assert_equal [base, base + "\0retry\0".b + "1", base + "\0retry\0".b + "2"], inputs
      destination = JSON.parse(File.readlines(File.join(output_dir, "accounts.jsonl")).first)
                        .fetch("destination_account")
      refute_includes [ZERO_ACCOUNT, ONE_ACCOUNT], destination
      assert_empty digests
    end
  end

  def test_rejects_public_account_id_digest_substitution
    error = assert_raises(ArgumentError) do
      XrplReserveStudy::WorkloadGenerator.new(account_id_digest: ->(*) { "\0" * 32 })
    end

    assert_match(/wrong number of arguments|unknown keyword/, error.message)
  end

  def test_uses_each_preregistered_base_reserve_as_a_decimal_drop_string
    expected = {
      1.0 => "1000000",
      0.5 => "500000",
      0.25 => "250000",
      0.1 => "100000"
    }

    with_runtime_directory do |directory|
      expected.each_with_index do |(reserve, amount), index|
        run = planned_runs_by_reserve.fetch(reserve)
        output_dir = File.join(directory, "reserve-#{index}")
        XrplReserveStudy::WorkloadGenerator.new.generate(
          run_id: run.fetch("run_id"), scope: "pilot", pilot_accounts: 1, output_dir: output_dir
        )
        record = JSON.parse(File.readlines(File.join(output_dir, "accounts.jsonl")).first)

        assert_equal amount, record.fetch("amount_drops")
      end
    end
  end

  def test_checksums_match_and_outputs_contain_no_secret_material
    with_runtime_directory do |directory|
      output_dir = File.join(directory, "pilot")
      XrplReserveStudy::WorkloadGenerator.new.generate(
        run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 3, output_dir: output_dir
      )

      expected_sums = %w[accounts.jsonl manifest.json].sort.map do |name|
        "#{Digest::SHA256.file(File.join(output_dir, name)).hexdigest}  #{name}\n"
      end.join
      assert_equal expected_sums, File.binread(File.join(output_dir, "SHA256SUMS"))

      combined = Dir.children(output_dir).sort.map { |name| File.binread(File.join(output_dir, name)) }.join
      refute_includes combined, "260803"
      refute_match(/master_seed|master_key|"private_key"|"secret"/i, combined)
      records = File.readlines(File.join(output_dir, "accounts.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      refute records.flat_map(&:values).grep(String).any? { |value| value.match?(/\As[A-Za-z0-9]{20,}\z/) }
      manifest = JSON.parse(File.binread(File.join(output_dir, "manifest.json")))
      assert_equal false, manifest.fetch("private_keys_generated")
      refute manifest.keys.any? { |key| key.match?(/\A(?:random_seed|master_seed|master_key|private_key|secret)\z/i) }
    end
  end

  def test_rejects_unknown_runs_invalid_scopes_and_invalid_pilot_counts
    generator = XrplReserveStudy::WorkloadGenerator.new
    invalid = [
      ["unknown run", { run_id: "not-planned", scope: "pilot", pilot_accounts: 1 }, /unknown planned run ID/],
      ["unknown scope", { run_id: PILOT_RUN_ID, scope: "other", pilot_accounts: 1 }, /scope must be pilot or full-plan/],
      ["missing pilot count", { run_id: PILOT_RUN_ID, scope: "pilot" }, /pilot account count/],
      ["zero pilot", { run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 0 }, /between 1 and 10000/],
      ["oversize pilot", { run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 10_001 }, /between 1 and 10000/],
      ["full plan with pilot count", { run_id: PILOT_RUN_ID, scope: "full-plan", pilot_accounts: 1 }, /not supported for full-plan/]
    ]

    with_runtime_directory do |directory|
      invalid.each_with_index do |(name, arguments, expected), index|
        error = assert_raises(XrplReserveStudy::WorkloadGenerationError, name) do
          generator.generate(**arguments, output_dir: File.join(directory, "invalid-#{index}"))
        end
        assert_match expected, error.message, name
        refute File.exist?(File.join(directory, "invalid-#{index}")), name
      end
    end
  end

  def test_rejects_locked_input_drift
    sources = locked_sources
    sources["study/reserve-calibration-v1.yml"] =
      "#{sources.fetch("study/reserve-calibration-v1.yml")}\n# drift\n"

    error = assert_raises(XrplReserveStudy::WorkloadGenerationError) do
      XrplReserveStudy::LockedCapacityInputs.new(
        error_class: XrplReserveStudy::WorkloadGenerationError, sources: sources
      )
    end
    assert_match(/input SHA-256 mismatch/, error.message)
  end

  def test_rejects_path_and_symlink_escape_existing_output_and_cleans_atomic_failure
    generator = XrplReserveStudy::WorkloadGenerator.new
    outside = File.join(ROOT, "capacity", "outside-runtime", "workload")
    error = assert_raises(XrplReserveStudy::WorkloadGenerationError) do
      generator.generate(run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 1, output_dir: outside)
    end
    assert_match(/must be within/, error.message)

    with_runtime_directory do |directory|
      existing = File.join(directory, "existing")
      Dir.mkdir(existing)
      error = assert_raises(XrplReserveStudy::WorkloadGenerationError) do
        generator.generate(run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 1, output_dir: existing)
      end
      assert_match(/already exists/, error.message)

      Dir.mktmpdir do |outside_directory|
        symlink = File.join(directory, "outside")
        File.symlink(outside_directory, symlink)
        error = assert_raises(XrplReserveStudy::WorkloadGenerationError) do
          generator.generate(
            run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 1,
            output_dir: File.join(symlink, "workload")
          )
        end
        assert_match(/must resolve within/, error.message)
        assert_empty Dir.children(outside_directory)
      end

      failed = File.join(directory, "failed")
      children_before = Dir.children(directory).sort
      error = XrplReserveStudy::RuntimePublisher::Native.stub(
        :rename_noreplace,
        ->(*) { raise Errno::EIO, "simulated publication failure" }
      ) do
        assert_raises(XrplReserveStudy::WorkloadGenerationError) do
          generator.generate(run_id: PILOT_RUN_ID, scope: "pilot", pilot_accounts: 1, output_dir: failed)
        end
      end
      assert_match(/could not write capacity workload/, error.message)
      refute File.exist?(failed)
      assert_equal children_before, Dir.children(directory).sort
    end
  end

  def test_manifest_schema_is_closed_and_defines_only_relative_artifact_paths
    schema = JSON.parse(File.binread(File.join(ROOT, "schemas", "capacity-workload-v1.schema.json")))
    manifest_properties = schema.fetch("properties")

    assert_equal false, schema.fetch("additionalProperties")
    assert_equal manifest_properties.keys.sort, schema.fetch("required").sort
    assert_equal "capacity-workload-v1", manifest_properties.fetch("schema_version").fetch("const")
    assert_equal "^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$)).+$", manifest_properties.fetch("accounts_path").fetch("pattern")
    refute manifest_properties.key?("random_seed")
    refute manifest_properties.key?("secret")
    refute manifest_properties.key?("private_key")
  end

  def test_capacity_workload_cli_defaults_and_strict_boundaries
    default_output = File.join(RUNTIME_ROOT, PILOT_RUN_ID, "workload", "pilot-000000003")
    refute File.exist?(default_output), "default test output unexpectedly exists"
    begin
      stdout, stderr, status = Open3.capture3(
        File.join(ROOT, "bin", "reserve-study"), "capacity-workload",
        "--run-id", PILOT_RUN_ID, "--pilot-accounts", "3", chdir: ROOT
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal 3, result.fetch("generated_account_count")
      assert_equal Digest::SHA256.file(File.join(default_output, "accounts.jsonl")).hexdigest,
                   result.dig("artifact_sha256", "accounts.jsonl")
    ensure
      FileUtils.remove_entry(default_output) if File.exist?(default_output)
    end

    inapplicable = {
      "--study" => File.join(ROOT, "study", "reserve-calibration-v1.yml"),
      "--endpoint" => "https://example.invalid",
      "--endpoints" => File.join(ROOT, "study", "mainnet-endpoints-v1.yml"),
      "--accounts" => "1",
      "--owned-objects" => "1",
      "--owner-reserve" => "0.2"
    }
    invalid = [
      ["missing run ID", ["--pilot-accounts", "1"], /missing argument: --run-id/],
      ["missing scope", ["--run-id", PILOT_RUN_ID], /pilot-accounts.*full-plan/],
      ["both scopes", ["--run-id", PILOT_RUN_ID, "--pilot-accounts", "1", "--full-plan"], /mutually exclusive/],
      ["zero count", ["--run-id", PILOT_RUN_ID, "--pilot-accounts", "0"], /between 1 and 10000/],
      ["surplus", ["--run-id", PILOT_RUN_ID, "--pilot-accounts", "1", "surplus"], /unexpected argument: surplus/],
      ["unknown flag", ["--run-id", PILOT_RUN_ID, "--pilot-accounts", "1", "--unknown-workload-option"], /invalid option/]
    ]
    inapplicable.each do |option, value|
      invalid << [option, ["--run-id", PILOT_RUN_ID, "--pilot-accounts", "1", option, value], /#{Regexp.escape(option)} is not supported for capacity-workload/]
    end

    with_runtime_directory do |directory|
      invalid.each_with_index do |(name, arguments, expected), index|
        stdout, stderr, status = Open3.capture3(
          File.join(ROOT, "bin", "reserve-study"), "capacity-workload", *arguments,
          "--output-dir", File.join(directory, "invalid-#{index}"), chdir: ROOT
        )
        refute status.success?, name
        assert_empty stdout, name
        assert_match(/\Aerror: /, stderr, name)
        assert_match expected, stderr, name
        refute_match(/from .*bin\/reserve-study/, stderr, name)
        refute File.exist?(File.join(directory, "invalid-#{index}")), name
      end
    end
  end

  def test_capacity_config_rejects_workload_only_flags
    [
      ["--pilot-accounts", "1"],
      ["--full-plan"]
    ].each do |arguments|
      _stdout, stderr, status = Open3.capture3(
        File.join(ROOT, "bin", "reserve-study"), "capacity-config",
        "--run-id", PILOT_RUN_ID, *arguments, chdir: ROOT
      )
      refute status.success?, arguments.first
      assert_match(/#{Regexp.escape(arguments.first)} is not supported for capacity-config/, stderr)
    end
  end

  private

  def with_runtime_directory
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("workload-test-", RUNTIME_ROOT) { |directory| yield directory }
  end

  def planned_runs_by_reserve
    @planned_runs_by_reserve ||= XrplReserveStudy::Study.new(
      XrplReserveStudy::LockedCapacityInputs::COMMITTED_STUDY_PATH
    ).plan.fetch("runs").each_with_object({}) do |run, by_reserve|
      by_reserve[run.fetch("base_reserve_xrp")] ||= run
    end
  end

  def locked_sources
    XrplReserveStudy::LockedCapacityInputs::SOURCE_PATHS.to_h do |relative_path, absolute_path|
      [relative_path, File.binread(absolute_path)]
    end
  end
end
