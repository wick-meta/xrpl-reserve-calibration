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

  # Break caught: retaining the old arbitrary executor/snapshot path would
  # bypass the final calibrated executor's private-network and clone gates.
  def test_rejects_the_legacy_arbitrary_executor_before_secret_read
    called = false
    executor = FakeExecutor.new
    assert_raises(XrplReserveStudy::CompleteReservesRunError) do
      XrplReserveStudy::CompleteReservesRun.new(executor: executor).call(
        item: {}, secret_reader: -> { called = true; +"secret" }
      )
    end
    refute called
    assert_equal 0, executor.calls
  end
end
