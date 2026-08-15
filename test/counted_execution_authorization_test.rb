# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CountedExecutionAuthorizationTest < Minitest::Test
  def test_accepts_only_the_exact_disabled_tracked_authorization
    authorization = XrplReserveStudy::CountedExecutionAuthorization.load(
      File.binread(File.expand_path("../study/counted-execution-authorization-v1.yml", __dir__))
    )
    assert_equal false, authorization.fetch("authorized")
    assert authorization.frozen?
  end

  def test_rejects_any_authorization_that_enables_counted_execution
    bytes = <<~YAML
      schema_version: counted-execution-authorization-v1
      authorized: true
    YAML

    error = assert_raises(XrplReserveStudy::CountedExecutionAuthorizationError) do
      XrplReserveStudy::CountedExecutionAuthorization.load(bytes)
    end
    assert_match(/invalid counted execution authorization/, error.message)
  end
end
