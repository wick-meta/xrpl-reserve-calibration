# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "stringio"
require_relative "../lib/xrpl_reserve_study"

class ReserveStudyCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "bin", "reserve-study")
  STUDY_PATH = File.join(ROOT, "study", "reserve-calibration-v1.yml")

  OPTIONS = {
    study: ["--study", STUDY_PATH],
    endpoint: ["--endpoint", "https://example.invalid"],
    endpoints: ["--endpoints", File.join(ROOT, "study", "mainnet-endpoints-v1.yml")],
    report: ["--report", File.join(ROOT, "test", "nonexistent-report.json")],
    output_dir: ["--output-dir", File.join(ROOT, "capacity", "runtime", "cli-contract-test")],
    run_id: ["--run-id", "r1000000-a000010000-n01"],
    pilot_accounts: ["--pilot-accounts", "1"],
    full_plan: ["--full-plan"],
    accounts: ["--accounts", "1"],
    owned_objects: ["--owned-objects", "1"],
    owner_reserve: ["--owner-reserve", "0.2"],
    secret_stdin: ["--secret-stdin"]
  }.freeze

  ALLOWED_OPTIONS = {
    "validate" => %i[study],
    "capacity-plan" => %i[study],
    "capacity-config" => %i[output_dir run_id],
    "capacity-workload" => %i[output_dir run_id pilot_accounts full_plan],
    "model" => %i[study accounts owned_objects owner_reserve],
    "baseline" => %i[endpoint],
    "baseline-set" => %i[endpoints output_dir],
    "complete-reserves-distribution" => %i[endpoints output_dir],
    "complete-reserves-import" => %i[report output_dir],
    "capacity-functional-smoke" => %i[run_id output_dir secret_stdin],
    "capacity-run-manifest" => %i[run_id pilot_accounts output_dir],
    "capacity-non-counted-pilot" => %i[run_id pilot_accounts secret_stdin],
    "sponsor-preflight" => []
  }.freeze

  def test_every_command_rejects_every_inapplicable_parsed_option_before_work
    ALLOWED_OPTIONS.each do |command, allowed|
      (OPTIONS.keys - allowed).each do |option|
        stdout, stderr, status = run_cli(command, *safe_prerequisites(command), *OPTIONS.fetch(option))

        refute status.success?, "#{command} accepted #{OPTIONS.fetch(option).first}"
        assert_empty stdout, "#{command} wrote stdout for #{OPTIONS.fetch(option).first}"
        assert_match(/\Aerror: /, stderr, command)
        assert_match(
          /#{Regexp.escape(OPTIONS.fetch(option).first)} is not supported for #{Regexp.escape(command)}/,
          stderr,
          command
        )
        refute_match(/from .*bin\/reserve-study/, stderr, command)
      end
    end
  end

  def test_every_command_rejects_surplus_positionals_before_work
    ALLOWED_OPTIONS.each_key do |command|
      stdout, stderr, status = run_cli(command, *safe_prerequisites(command), "unexpected-positional")

      refute status.success?, "#{command} accepted a surplus positional"
      assert_empty stdout, command
      assert_match(/\Aerror: /, stderr, command)
      assert_match(/unexpected argument: unexpected-positional/, stderr, command)
      refute_match(/from .*bin\/reserve-study/, stderr, command)
    end
  end

  def test_valid_local_commands_preserve_their_applicable_options
    stdout, stderr, status = run_cli("validate", "--study", STUDY_PATH)
    assert status.success?, stderr
    assert_equal true, JSON.parse(stdout).fetch("valid")

    stdout, stderr, status = run_cli("capacity-plan", "--study", STUDY_PATH)
    assert status.success?, stderr
    assert_equal 72, JSON.parse(stdout).fetch("run_count")

    stdout, stderr, status = run_cli(
      "model", "--study", STUDY_PATH, "--accounts", "2", "--owned-objects", "3", "--owner-reserve", "0.4"
    )
    assert status.success?, stderr
    assert_equal 2, JSON.parse(stdout).dig("inputs", "accounts")
  end

  def test_functional_smoke_requires_exact_run_id_and_secret_stdin_flags
    stdout, stderr, status = run_cli("capacity-functional-smoke", "--run-id", "r0500000-a000010000-n01")
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_match(/--secret-stdin/, stderr)

    stdout, stderr, status = run_cli("capacity-functional-smoke", "--secret-stdin")
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_match(/--run-id/, stderr)

    stdout, stderr, status = run_cli("capacity-functional-smoke", "--run-id", "r0500000-a000010000-n01", "--secret-stdin=value")
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_match(/error: /, stderr)
  end

  def test_complete_reserves_import_requires_a_report_path
    stdout, stderr, status = run_cli("complete-reserves-import")

    refute status.success?
    assert_empty stdout
    assert_match(/--report/, stderr)
  end

  def test_non_tty_secret_reader_accepts_one_bounded_line_and_rejects_every_other_shape
    assert_equal "a" * 128, XrplReserveStudy::CapacitySecretReader.read(
      input: StringIO.new("#{'a' * 128}\n"), error: StringIO.new
    )

    ["", "\n", "missing-newline", "two\nlines\n", "carriage\r\n", "nul\0byte\n", "#{'a' * 129}\n"].each do |bytes|
      error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError, bytes.inspect) do
        XrplReserveStudy::CapacitySecretReader.read(input: StringIO.new(bytes), error: StringIO.new)
      end
      assert_equal "invalid standalone secret input", error.message
      refute_includes error.message, bytes unless bytes.empty?
    end
  end

  def test_tty_secret_reader_prompts_only_on_stderr_uses_noecho_and_applies_common_validation
    input_class = Class.new(StringIO) do
      attr_reader :noecho_calls
      def tty?
        true
      end
      def noecho
        @noecho_calls = (@noecho_calls || 0) + 1
        yield
      end
    end
    input = input_class.new("fake-tty-value\n")
    error = StringIO.new

    assert_equal "fake-tty-value", XrplReserveStudy::CapacitySecretReader.read(input: input, error: error)
    assert_equal 1, input.noecho_calls
    assert_equal "Standalone secret: \n", error.string
  end

  def test_functional_smoke_cli_uses_fixed_runtime_paths_and_exit_dispositions
    passed = { "status" => "passed", "counted_run" => false, "pilot_complete" => false }
    stdout, stderr, status = run_cli_with_fake_smoke(passed, input: "fake-only\n")
    assert_equal 0, status.exitstatus, stderr
    summary = JSON.parse(stdout)
    assert_equal "passed", summary.fetch("status")
    assert_equal File.join(ROOT, "capacity", "runtime", "r0500000-a000010000-n01", "config"), summary.fetch("observed_config_dir")
    assert_equal File.join(ROOT, "capacity", "runtime", "r0500000-a000010000-n01", "workload", "pilot-000000001"), summary.fetch("observed_workload_dir")
    assert_equal File.join(ROOT, "capacity", "runtime", "r0500000-a000010000-n01", "execution", "functional-smoke-000000001"), summary.fetch("observed_output_dir")

    failed = { "status" => "failed", "error_code" => "rpc-failure", "counted_run" => false, "pilot_complete" => false }
    stdout, stderr, status = run_cli_with_fake_smoke(failed, input: "fake-only\n")
    assert_equal 2, status.exitstatus, stderr
    assert_equal "failed", JSON.parse(stdout).fetch("status")

    aborted = failed.merge("status" => "aborted")
    _stdout, stderr, status = run_cli_with_fake_smoke(aborted, input: "bad\r\n")
    assert_equal 1, status.exitstatus
    assert_match(/\Aerror: invalid standalone secret input\n\z/, stderr)
    refute_includes stderr, "bad"
  end

  def test_run_manifest_cli_requires_pilot_arguments_and_uses_only_fixed_input_paths
    stdout, stderr, status = run_cli("capacity-run-manifest", "--pilot-accounts", "3")
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_match(/--run-id/, stderr)

    stdout, stderr, status = run_cli("capacity-run-manifest", "--run-id", "r0500000-a000010000-n01")
    assert_equal 1, status.exitstatus
    assert_empty stdout
    assert_match(/--pilot-accounts/, stderr)

    stdout, stderr, status = run_cli_with_fake_manifest
    assert_equal 0, status.exitstatus, stderr
    result = JSON.parse(stdout)
    base = File.join(ROOT, "capacity", "runtime", "r0500000-a000010000-n01")
    assert_equal File.join(base, "config"), result.fetch("observed_config_dir")
    assert_equal File.join(base, "workload", "pilot-000000003"), result.fetch("observed_workload_dir")
    assert_equal File.join(base, "manifests", "non-counted-pilot-000000003"), result.fetch("observed_output_dir")
    assert_equal false, result.fetch("counted_run")
  end

  def test_non_counted_pilot_cli_requires_exact_fixed_profile_and_prints_only_sanitized_result
    invalid = [
      ["--run-id", "r1000000-a000010000-n01", "--pilot-accounts", "3", "--secret-stdin"],
      ["--run-id", "r0500000-a000010000-n01", "--pilot-accounts", "2", "--secret-stdin"],
      ["--run-id", "r0500000-a000010000-n01", "--pilot-accounts", "3"]
    ]
    invalid.each do |arguments|
      stdout, stderr, status = run_cli("capacity-non-counted-pilot", *arguments)
      refute status.success?
      assert_empty stdout
      assert_match(/error: /, stderr)
    end

    passed = {
      "status" => "passed", "disposition_code" => "success", "pilot_complete" => true,
      "counted_execution_authorized" => false, "native_execution_established" => false
    }
    stdout, stderr, status = run_cli_with_fake_pilot(passed)
    assert_equal 0, status.exitstatus, stderr
    result = JSON.parse(stdout)
    base = File.join(ROOT, "capacity", "runtime", "r0500000-a000010000-n01")
    assert_equal File.join(base, "config"), result.fetch("observed_config_dir")
    assert_equal File.join(base, "workload", "pilot-000000003"), result.fetch("observed_workload_dir")
    assert_equal File.join(base, "manifests", "non-counted-pilot-000000003"), result.fetch("observed_manifest_dir")
    assert_equal File.join(base, "execution", "non-counted-pilot-000000003"), result.fetch("observed_output_dir")
    assert_equal false, result.fetch("counted_execution_authorized")
    assert_equal false, result.fetch("native_execution_established")

    failed = passed.merge("status" => "failed", "disposition_code" => "threshold-failure", "pilot_complete" => false)
    stdout, stderr, status = run_cli_with_fake_pilot(failed)
    assert_equal 2, status.exitstatus, stderr
    assert_equal "threshold-failure", JSON.parse(stdout).fetch("disposition_code")
  end

  private

  def run_cli(command, *arguments)
    Open3.capture3(CLI, command, *arguments, chdir: ROOT)
  end

  def safe_prerequisites(command)
    case command
    when "baseline"
      ["--endpoint", "http://127.0.0.1:1"]
    when "baseline-set"
      ["--endpoints", File.join(ROOT, "test", "nonexistent-endpoints.yml")]
    when "complete-reserves-distribution"
      ["--endpoints", File.join(ROOT, "test", "nonexistent-endpoints.yml")]
    when "complete-reserves-import"
      ["--report", File.join(ROOT, "test", "nonexistent-report.json")]
    when "capacity-functional-smoke"
      ["--run-id", "r0500000-a000010000-n01", "--secret-stdin"]
    when "capacity-non-counted-pilot"
      ["--run-id", "r0500000-a000010000-n01", "--pilot-accounts", "3", "--secret-stdin"]
    else
      []
    end
  end

  def run_cli_with_fake_smoke(record, input:)
    script = <<~'RUBY'
      require "json"
      require "xrpl_reserve_study"
      XrplReserveStudy::CapacityFunctionalSmoke.class_eval do
        define_method(:initialize) { |**| }
        define_method(:run) do |run_id:, config_dir:, workload_dir:, output_dir:, secret_reader:|
          secret_reader.call
          JSON.parse(ENV.fetch("FAKE_SMOKE_RECORD")).merge(
            "observed_run_id" => run_id,
            "observed_config_dir" => config_dir,
            "observed_workload_dir" => workload_dir,
            "observed_output_dir" => output_dir
          )
        end
      end
      ARGV.replace(JSON.parse(ENV.fetch("FAKE_SMOKE_ARGS")))
      load File.join(Dir.pwd, "bin", "reserve-study")
    RUBY
    environment = {
      "FAKE_SMOKE_RECORD" => JSON.generate(record),
      "FAKE_SMOKE_ARGS" => JSON.generate([
        "capacity-functional-smoke", "--run-id", "r0500000-a000010000-n01", "--secret-stdin"
      ])
    }
    Open3.capture3(environment, "ruby", "-Ilib", "-e", script, stdin_data: input, chdir: ROOT)
  end

  def run_cli_with_fake_manifest
    script = <<~'RUBY'
      require "json"
      require "xrpl_reserve_study"
      XrplReserveStudy::CapacityRunManifest.class_eval do
        define_method(:initialize) { |**| }
        define_method(:publish) do |run_id:, pilot_accounts:, config_dir:, workload_dir:, output_dir:|
          {
            "run_id" => run_id, "generated_account_count" => pilot_accounts,
            "observed_config_dir" => config_dir, "observed_workload_dir" => workload_dir,
            "observed_output_dir" => output_dir, "counted_run" => false
          }
        end
      end
      ARGV.replace(["capacity-run-manifest", "--run-id", "r0500000-a000010000-n01", "--pilot-accounts", "3"])
      load File.join(Dir.pwd, "bin", "reserve-study")
    RUBY
    Open3.capture3("ruby", "-Ilib", "-e", script, chdir: ROOT)
  end

  def run_cli_with_fake_pilot(record)
    script = <<~'RUBY'
      require "json"
      require "xrpl_reserve_study"
      XrplReserveStudy::CapacityNonCountedPilot.class_eval do
        define_method(:initialize) { |**| }
        define_method(:run) do |run_id:, config_dir:, workload_dir:, manifest_dir:, output_dir:, secret_reader:|
          secret_reader.call
          JSON.parse(ENV.fetch("FAKE_PILOT_RECORD")).merge(
            "observed_run_id" => run_id, "observed_config_dir" => config_dir,
            "observed_workload_dir" => workload_dir, "observed_manifest_dir" => manifest_dir,
            "observed_output_dir" => output_dir
          )
        end
      end
      ARGV.replace([
        "capacity-non-counted-pilot", "--run-id", "r0500000-a000010000-n01",
        "--pilot-accounts", "3", "--secret-stdin"
      ])
      load File.join(Dir.pwd, "bin", "reserve-study")
    RUBY
    Open3.capture3(
      { "FAKE_PILOT_RECORD" => JSON.generate(record) },
      "ruby", "-Ilib", "-e", script, stdin_data: "test-only\n", chdir: ROOT
    )
  end
end
