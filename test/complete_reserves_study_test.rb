# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesStudyTest < Minitest::Test
  STUDY_PATH = File.expand_path("../study/complete-reserves-v1.yml", __dir__)
  DISTRIBUTION = { "account_roots" => 8_000_000, "owned_objects" => 12_000_000 }.freeze

  def test_plan_has_120_ordered_runs_for_declared_cells
    plan = XrplReserveStudy::CompleteReservesStudy.new(STUDY_PATH).plan(distribution: DISTRIBUTION)

    assert_equal 120, plan.fetch("run_count")
    assert_equal [1.0, 0.5, 0.25, 0.1], plan.fetch("base_reserve_options_xrp")
    assert_equal [0.2, 0.1, 0.05, 0.02], plan.fetch("owner_reserve_options_xrp")
    assert_equal 16_000_000, plan.fetch("runs").find { |run| run.fetch("program") == "base" && run.fetch("scale") == 2.0 }.fetch("account_root_target")
    assert_equal XrplReserveStudy::CompleteReservesStudy::RUN_ORDER_SHA256,
                 Digest::SHA256.hexdigest(plan.fetch("runs").map { |run| run.fetch("run_id") }.join("\n"))
    assert plan.frozen?
    assert plan.fetch("runs").all?(&:frozen?)
  end

  def test_rejects_changed_combined_scale_rule
    source = File.binread(STUDY_PATH).sub("  - 2.0\ncombined_scales:\n  - 1.5\n  - 2.0", "  - 2.0\ncombined_scales:\n  - 1.25\n  - 2.0")
    error = assert_raises(XrplReserveStudy::CompleteReservesStudyError) do
      XrplReserveStudy::CompleteReservesStudy.new(STUDY_PATH, source: source)
    end

    assert_equal "invalid complete reserves study", error.message
  end
end
