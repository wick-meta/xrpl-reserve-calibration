# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesMatrixTest < Minitest::Test
  def test_matrix_rejects_before_secret_read_when_authorization_is_false
    called = false
    assert_raises(XrplReserveStudy::CompleteReservesMatrixError) do
      XrplReserveStudy::CompleteReservesMatrix.new.call(secret_reader: -> { called = true; "secret" })
    end
    refute called
  end

  def test_matrix_remains_hard_disabled_after_authorization
    authorization = Object.new
    authorization.define_singleton_method(:authorize!) { true }
    called = false

    error = assert_raises(XrplReserveStudy::CompleteReservesMatrixError) do
      XrplReserveStudy::CompleteReservesMatrix.new(authorization: authorization).call(
        secret_reader: -> { called = true; "secret" }
      )
    end

    assert_equal "matrix execution is unavailable in this implementation phase", error.message
    refute called
  end
end
