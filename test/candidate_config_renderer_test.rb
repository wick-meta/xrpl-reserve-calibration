# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CandidateConfigRendererTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  STUDY_PATH = File.join(ROOT, "study", "reserve-calibration-v1.yml")
  CANONICAL_CONFIG_PATH = File.join(ROOT, "capacity", "config", "rippled.cfg")
  RUNTIME_ROOT = File.join(ROOT, "capacity", "runtime")

  def test_renders_each_preregistered_reserve_option_from_its_planned_run
    renderer = XrplReserveStudy::CandidateConfigRenderer.new
    expected_drops = { 1.0 => 1_000_000, 0.5 => 500_000, 0.25 => 250_000, 0.1 => 100_000 }

    with_runtime_directory do |directory|
      planned_runs_by_reserve.each do |reserve, run|
        metadata = renderer.render(run_id: run.fetch("run_id"), output_dir: File.join(directory, reserve.to_s, "config"))

        assert_equal reserve, metadata.fetch("base_reserve_xrp")
        assert_equal expected_drops.fetch(reserve), metadata.fetch("base_reserve_drops")
        assert_equal run.fetch("account_count"), metadata.fetch("account_count")
        assert_equal run.fetch("repetition"), metadata.fetch("repetition")
        assert_includes File.binread(File.join(directory, reserve.to_s, "config", "rippled.cfg")),
                        "account_reserve = #{expected_drops.fetch(reserve)}\n"
      end
    end
  end

  def test_only_account_reserve_decimal_changes_and_metadata_checksum_is_accurate
    canonical = File.binread(CANONICAL_CONFIG_PATH)
    run = planned_runs_by_reserve.fetch(0.5)

    with_runtime_directory do |directory|
      output_dir = File.join(directory, "config")
      metadata = XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: run.fetch("run_id"), output_dir: output_dir)
      rendered_path = File.join(output_dir, metadata.fetch("relative_config_path"))
      rendered = File.binread(rendered_path)
      expected = canonical.sub(/(^[ \t]*account_reserve[ \t]*=[ \t]*)\d+/) { "#{$1}500000" }

      assert_equal "rippled.cfg", metadata.fetch("relative_config_path")
      assert_equal expected, rendered
      assert_equal Digest::SHA256.hexdigest(rendered), metadata.fetch("sha256")
      assert_equal 0o755, File.stat(File.dirname(output_dir)).mode & 0o777
      assert_equal 0o755, File.stat(output_dir).mode & 0o777
      assert_equal(
        {
          "study/reserve-calibration-v1.yml" => Digest::SHA256.file(STUDY_PATH).hexdigest,
          "capacity/config/rippled.cfg" => Digest::SHA256.file(CANONICAL_CONFIG_PATH).hexdigest,
          "study/protocol-alignment-v1.yml" => Digest::SHA256.file(
            File.join(ROOT, "study", "protocol-alignment-v1.yml")
          ).hexdigest,
          "capacity/pilot-protocol-v1.yml" => Digest::SHA256.file(
            File.join(ROOT, "capacity", "pilot-protocol-v1.yml")
          ).hexdigest
        },
        metadata.fetch("input_sha256")
      )
      assert_equal ["rippled.cfg"], Dir.children(output_dir)
    end
  end

  def test_rejects_working_tree_input_bytes_that_do_not_match_the_tracked_lock
    altered_inputs = {
      "study/reserve-calibration-v1.yml" => "#{File.binread(STUDY_PATH)}\n# uncommitted study drift\n",
      "capacity/config/rippled.cfg" => "#{File.binread(CANONICAL_CONFIG_PATH)}\n# uncommitted config drift\n",
      "study/protocol-alignment-v1.yml" => "#{File.binread(File.join(ROOT, "study", "protocol-alignment-v1.yml"))}\n# uncommitted alignment drift\n",
      "capacity/pilot-protocol-v1.yml" => "#{File.binread(File.join(ROOT, "capacity", "pilot-protocol-v1.yml"))}\n# uncommitted pilot protocol drift\n"
    }

    altered_inputs.each do |relative_path, altered_bytes|
      sources = locked_sources
      sources[relative_path] = altered_bytes
      error = assert_raises(XrplReserveStudy::CandidateConfigError) do
        XrplReserveStudy::LockedCapacityInputs.new(error_class: XrplReserveStudy::CandidateConfigError, sources: sources)
      end

      assert_match(/input SHA-256 mismatch/, error.message)
    end
  end

  def test_rejects_an_unknown_run_id
    with_runtime_directory do |directory|
      error = assert_raises(XrplReserveStudy::CandidateConfigError) do
        XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: "not-a-planned-run", output_dir: File.join(directory, "config"))
      end

      assert_match(/unknown planned run ID/, error.message)
    end
  end

  def test_rejects_an_existing_output_directory
    run = planned_runs_by_reserve.fetch(1.0)

    with_runtime_directory do |directory|
      output_dir = File.join(directory, "config")
      Dir.mkdir(output_dir)

      error = assert_raises(XrplReserveStudy::CandidateConfigError) do
        XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: run.fetch("run_id"), output_dir: output_dir)
      end

      assert_match(/already exists/, error.message)
    end
  end

  def test_rejects_canonical_configuration_without_exactly_one_account_reserve_assignment
    {
      "missing" => "[voting]\nowner_reserve = 200000\n",
      "multiple" => "[voting]\naccount_reserve = 1000000\naccount_reserve = 500000\n"
    }.each do |name, content|
      error = assert_raises(XrplReserveStudy::CandidateConfigError, name) do
        XrplReserveStudy::CandidateConfigRenderer.new.send(:render_config, content, 1_000_000)
      end

      assert_match(/exactly one account_reserve assignment/, error.message)
    end
  end

  def test_failed_atomic_publication_removes_temporary_output
    run = planned_runs_by_reserve.fetch(1.0)

    with_runtime_directory do |directory|
      output_dir = File.join(directory, "config")
      children_before = Dir.children(directory)

      error = XrplReserveStudy::RuntimePublisher::Native.stub(
        :rename_noreplace,
        ->(*) { raise Errno::EIO, "simulated publication failure" }
      ) do
        assert_raises(XrplReserveStudy::CandidateConfigError) do
          XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: run.fetch("run_id"), output_dir: output_dir)
        end
      end

      assert_match(/could not write candidate configuration/, error.message)
      refute File.exist?(output_dir)
      assert_equal children_before, Dir.children(directory)
    end
  end

  def test_rejects_dotdot_output_escape
    error = assert_raises(XrplReserveStudy::CandidateConfigError) do
      XrplReserveStudy::CandidateConfigRenderer.new.render(
        run_id: planned_runs_by_reserve.fetch(1.0).fetch("run_id"),
        output_dir: File.join(RUNTIME_ROOT, "..", "escaped", "config")
      )
    end

    assert_match(/must be within/, error.message)
  end

  def test_rejects_symlink_output_escape
    with_runtime_directory do |directory|
      Dir.mktmpdir do |outside_directory|
        symlink_path = File.join(directory, "outside")
        File.symlink(outside_directory, symlink_path)

        error = assert_raises(XrplReserveStudy::CandidateConfigError) do
          XrplReserveStudy::CandidateConfigRenderer.new.render(
            run_id: planned_runs_by_reserve.fetch(1.0).fetch("run_id"),
            output_dir: File.join(symlink_path, "config")
          )
        end

        assert_match(/must resolve within/, error.message)
        refute File.exist?(File.join(outside_directory, "config", "rippled.cfg"))
      end
    end
  end

  def test_cli_rejects_alternate_study_and_output_outside_runtime_root
    Dir.mktmpdir do |directory|
      alternate_study_path = File.join(directory, "alternate-study.yml")
      alternate_study = File.read(File.join(ROOT, "study", "reserve-calibration-v1.yml")).sub("  - 0.1\n", "  - 0.75\n")
      File.write(alternate_study_path, alternate_study)

      _stdout, stderr, status = Open3.capture3(
        File.join(ROOT, "bin", "reserve-study"),
        "capacity-config",
        "--study", alternate_study_path,
        "--run-id", "r0750000-a000010000-n01",
        "--output-dir", File.join(RUNTIME_ROOT, "alternate-study-test", "config"),
        chdir: ROOT
      )

      refute status.success?
      assert_match(/--study is not supported for capacity-config/, stderr)
    end

    _stdout, stderr, status = Open3.capture3(
      File.join(ROOT, "bin", "reserve-study"),
      "capacity-config",
      "--run-id", planned_runs_by_reserve.fetch(1.0).fetch("run_id"),
      "--output-dir", File.join(ROOT, "capacity", "outside-runtime", "config"),
      chdir: ROOT
    )

    refute status.success?
    assert_match(/output directory must be within/, stderr)
  end

  def test_capacity_config_cli_rejects_every_command_inapplicable_option
    inapplicable_options = {
      "--study" => STUDY_PATH,
      "--endpoint" => "https://example.invalid",
      "--endpoints" => File.join(ROOT, "study", "mainnet-endpoints-v1.yml"),
      "--accounts" => "100",
      "--owned-objects" => "200",
      "--owner-reserve" => "0.2"
    }

    with_runtime_directory do |directory|
      inapplicable_options.each_with_index do |(option, value), index|
        output_dir = File.join(directory, "rejected-#{index}")
        _stdout, stderr, status = Open3.capture3(
          File.join(ROOT, "bin", "reserve-study"),
          "capacity-config",
          "--run-id", planned_runs_by_reserve.fetch(1.0).fetch("run_id"),
          "--output-dir", output_dir,
          option, value,
          chdir: ROOT
        )

        refute status.success?, option
        assert_match(/#{Regexp.escape(option)} is not supported for capacity-config/, stderr, option)
        refute File.exist?(output_dir), option
      end
    end
  end

  def test_capacity_config_cli_rejects_surplus_positionals_and_unknown_flags_through_controlled_errors
    [
      ["surplus positional", ["unexpected-positional"], /unexpected argument: unexpected-positional/],
      ["unknown flag", ["--unknown-capacity-option"], /invalid option: --unknown-capacity-option/]
    ].each do |name, extra_arguments, expected_error|
      with_runtime_directory do |directory|
        output_dir = File.join(directory, "config")
        _stdout, stderr, status = Open3.capture3(
          File.join(ROOT, "bin", "reserve-study"),
          "capacity-config",
          "--run-id", planned_runs_by_reserve.fetch(1.0).fetch("run_id"),
          "--output-dir", output_dir,
          *extra_arguments,
          chdir: ROOT
        )

        refute status.success?, name
        assert_match(/\Aerror: /, stderr, name)
        assert_match(expected_error, stderr, name)
        refute_match(/from .*bin\/reserve-study/, stderr, name)
        refute File.exist?(output_dir), name
      end
    end
  end

  private

  def with_runtime_directory
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("candidate-config-test-", RUNTIME_ROOT) { |directory| yield directory }
  end

  def planned_runs_by_reserve
    @planned_runs_by_reserve ||= XrplReserveStudy::Study.new(XrplReserveStudy::CandidateConfigRenderer::COMMITTED_STUDY_PATH).plan.fetch("runs").each_with_object({}) do |run, by_reserve|
      by_reserve[run.fetch("base_reserve_xrp")] ||= run
    end
  end

  def locked_sources
    XrplReserveStudy::LockedCapacityInputs::SOURCE_PATHS.to_h do |relative_path, absolute_path|
      [relative_path, File.binread(absolute_path)]
    end
  end
end
