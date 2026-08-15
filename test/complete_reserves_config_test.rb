# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesConfigTest < Minitest::Test
  def test_render_changes_both_and_only_both_reserve_assignments
    run = { "run_id" => "cr-test", "base_reserve_xrp" => 0.1, "owner_reserve_xrp" => 0.02 }
    with_runtime_directory do |directory|
      record = XrplReserveStudy::CompleteReservesConfig.new.render(run: run, output_dir: File.join(directory, "config"))
      text = File.binread(File.join(directory, "config", "rippled.cfg"))
      assert_includes text, "account_reserve = 100000\n"
      assert_includes text, "owner_reserve = 20000\n"
      assert_equal 2, record.fetch("changed_assignment_count")
    end
  end

  private

  def with_runtime_directory
    directory = File.expand_path("../capacity/runtime/complete-reserves-config-test-#{Process.pid}-#{rand(1_000_000)}", __dir__)
    yield directory
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end
