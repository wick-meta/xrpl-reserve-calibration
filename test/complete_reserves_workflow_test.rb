# frozen_string_literal: true

require "minitest/autorun"

class CompleteReservesWorkflowTest < Minitest::Test
  def test_workflow_is_manual_read_only_and_has_no_mutable_inputs
    text = File.binread(File.expand_path("../.github/workflows/complete-reserves.yml", __dir__))
    assert_includes text, "workflow_dispatch:"
    assert_includes text, "contents: read"
    assert_includes text, "environment: complete-reserves"
    assert_includes text, "bin/reserve-study complete-reserves-matrix"
    refute_match(/inputs:|https?:\/\//, text)
  end
end
