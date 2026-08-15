# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class MainnetObserverTest < Minitest::Test
  def test_requires_https
    error = assert_raises(XrplReserveStudy::ObservationError) do
      XrplReserveStudy::MainnetObserver.new(endpoint: "http://example.com")
    end

    assert_match(/HTTPS/, error.message)
  end

  def test_rejects_endpoint_credentials
    error = assert_raises(XrplReserveStudy::ObservationError) do
      XrplReserveStudy::MainnetObserver.new(endpoint: "https://user:secret@example.com")
    end

    assert_match(/credentials/, error.message)
  end

  def test_rejects_query_and_fragment
    error = assert_raises(XrplReserveStudy::ObservationError) do
      XrplReserveStudy::MainnetObserver.new(endpoint: "https://example.com/rpc?token=secret")
    end

    assert_match(/query or fragment/, error.message)
  end
end
