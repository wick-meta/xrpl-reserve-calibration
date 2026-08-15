# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesRunTest < Minitest::Test
  class FakeExecutor
    attr_reader :calls
    def initialize; @calls = 0; end
    def call(run:, snapshot:, secret:)
      @calls += 1
      { "status" => "passed", "summary" => { "thresholds_passed" => true }, "samples" => "", "transactions" => "" }
    end
  end

  def test_rejects_snapshot_mismatch_before_secret_and_runs_exactly_once
    called = false
    executor = FakeExecutor.new
    run = { "run_id" => "cr-run", "base_reserve_xrp" => 1.0, "owner_reserve_xrp" => 0.2, "scale" => 1.0 }
    snapshot = { "base_reserve_drops" => 100_000, "owner_reserve_drops" => 200_000, "scale" => 1.0 }
    assert_raises(XrplReserveStudy::CompleteReservesRunError) do
      XrplReserveStudy::CompleteReservesRun.new(executor: executor).call(run: run, snapshot: snapshot, secret_reader: -> { called = true; "secret" })
    end
    refute called
    assert_equal 0, executor.calls
  end
end
