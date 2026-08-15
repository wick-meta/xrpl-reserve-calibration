# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/xrpl_reserve_study"

class StudyTest < Minitest::Test
  STUDY_PATH = File.expand_path("../study/reserve-calibration-v1.yml", __dir__)

  def test_plan_has_24_cells_and_72_runs
    plan = XrplReserveStudy::Study.new(STUDY_PATH).plan

    assert_equal 24, plan.fetch("cell_count")
    assert_equal 72, plan.fetch("run_count")
    assert_equal 72, plan.fetch("runs").map { |run| run.fetch("run_id") }.uniq.length
  end

  def test_plan_is_deterministic
    first = XrplReserveStudy::Study.new(STUDY_PATH).plan
    second = XrplReserveStudy::Study.new(STUDY_PATH).plan

    assert_equal first, second
  end

  def test_model_uses_same_population_for_every_option
    result = XrplReserveStudy::Study.new(STUDY_PATH).model(
      accounts: 100,
      owned_objects: 50,
      owner_reserve_xrp: 0.2
    )

    current = result.fetch("scenarios").find { |row| row.fetch("base_reserve_xrp") == 1.0 }
    one = result.fetch("scenarios").find { |row| row.fetch("base_reserve_xrp") == 1.0 }
    tenth = result.fetch("scenarios").find { |row| row.fetch("base_reserve_xrp") == 0.1 }
    assert_in_delta 110.0, one.fetch("total_locked_xrp")
    assert_in_delta 110.0, current.fetch("total_locked_xrp")
    assert_in_delta 20.0, tenth.fetch("total_locked_xrp")
    assert_in_delta(-90.0, tenth.fetch("delta_from_reference_xrp"))
  end

  def test_rejects_missing_fields
    Tempfile.create(["study", ".yml"]) do |file|
      file.write("study_id: incomplete\n")
      file.flush

      error = assert_raises(XrplReserveStudy::StudyError) do
        XrplReserveStudy::Study.new(file.path)
      end
      assert_match(/missing keys/, error.message)
    end
  end
end
