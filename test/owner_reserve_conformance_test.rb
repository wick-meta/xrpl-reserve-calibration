# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class OwnerReserveConformanceTest < Minitest::Test
  class FakeClient
    def isolated?; true; end
    def exercise(recipe:, secret:)
      { "before_balance_drops" => 1_000_000, "after_lock_balance_drops" => 800_000,
        "after_release_balance_drops" => 1_000_000, "owner_count_before" => 0,
        "owner_count_after_lock" => 1, "owner_count_after_release" => 0,
        "terminal_result" => "tesSUCCESS", "cleanup_result" => "tesSUCCESS" }
    end
  end

  def test_closed_case_records_lock_and_verified_release
    record = XrplReserveStudy::OwnerReserveConformance.new(client: FakeClient.new).call(
      case_id: "offer-lifecycle", secret_reader: -> { "secret" }
    )
    assert_equal "passed", record.fetch("status")
    assert_equal 200_000, record.fetch("locked_xrp_drops")
    assert_equal 200_000, record.fetch("released_xrp_drops")
  end

  def test_rejects_unknown_case_before_secret_read
    called = false
    assert_raises(XrplReserveStudy::OwnerReserveConformanceError) do
      XrplReserveStudy::OwnerReserveConformance.new(client: FakeClient.new).call(case_id: "arbitrary", secret_reader: -> { called = true; "secret" })
    end
    refute called
  end
end
