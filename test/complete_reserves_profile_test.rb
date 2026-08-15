# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesProfileTest < Minitest::Test
  PROFILE_PATH = File.expand_path("../study/complete-reserves-profiles-v1.yml", __dir__)
  DISTRIBUTION = { "account_roots" => 8_000_000, "owned_objects" => 12_000_000 }.freeze

  def test_calibrated_cells_cover_the_three_frozen_account_root_targets
    cells = XrplReserveStudy::CompleteReservesProfile.new(PROFILE_PATH).calibrated_cells(distribution: DISTRIBUTION)

    assert_equal [10_000, 25_000, 50_000], cells.map { |cell| cell.fetch("account_root_target") }
    assert cells.all? { |cell| cell.fetch("profile_id") == "complete-reserves-calibrated-v1" }
    assert cells.all? { |cell| cell.fetch("counted_run") == false }
    assert cells.all? { |cell| cell.fetch("warmup_seconds") == 300 }
    assert cells.all? { |cell| cell.fetch("measurement_seconds") == 1_800 }
  end

  def test_full_matrix_cells_preserve_the_canonical_frozen_120_cell_plan
    cells = XrplReserveStudy::CompleteReservesProfile.new(PROFILE_PATH).full_matrix_cells(distribution: DISTRIBUTION)

    assert_equal 120, cells.length
    assert cells.all? { |cell| cell.fetch("profile_id") == "complete-reserves-full-matrix-v1" }
    assert_equal XrplReserveStudy::CompleteReservesStudy::RUN_ORDER_SHA256,
                 Digest::SHA256.hexdigest(cells.map { |cell| cell.fetch("run_id") }.join("\n"))
  end

  def test_rejects_profile_with_changed_keys_targets_timing_id_or_counted_status
    source = File.binread(PROFILE_PATH)
    mutations = [
      ->(value) { value.sub("profile_id: complete-reserves-calibrated-v1", "profile_id: changed") },
      ->(value) { value.sub("profile_id: complete-reserves-full-matrix-v1", "profile_id: changed") },
      ->(value) { value.sub("  - 10000", "  - 0") },
      ->(value) { value.sub("warmup_seconds: 300", "warmup_seconds: 301") },
      ->(value) { value.sub("measurement_seconds: 1800", "measurement_seconds: 1799") },
      ->(value) { value.sub("counted_run: false", "counted_run: true") },
      ->(value) { value + "unexpected: false\n" }
    ]

    mutations.each do |mutation|
      error = assert_raises(XrplReserveStudy::CompleteReservesProfileError) do
        XrplReserveStudy::CompleteReservesProfile.new(PROFILE_PATH, source: mutation.call(source))
      end
      assert_equal "invalid complete reserves profile", error.message
    end
  end
end
