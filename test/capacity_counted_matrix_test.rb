# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CapacityCountedMatrixTest < Minitest::Test
  def test_rejects_disabled_authorization_before_reading_secret
    reads = 0
    matrix = XrplReserveStudy::CapacityCountedMatrix.new
    error = assert_raises(XrplReserveStudy::CapacityCountedMatrixError) do
      matrix.call(secret_reader: -> { reads += 1; "must-not-be-read" })
    end

    assert_match(/not authorized/, error.message)
    assert_equal 0, reads
  end
end
