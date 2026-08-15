# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CapacityCountedArtifactsTest < Minitest::Test
  def test_publishes_one_immutable_disposition_per_run
    artifacts = XrplReserveStudy::CapacityCountedArtifacts.new
    run_id = "r0000001-a000000001-n01"
      result = artifacts.publish_disposition(
        run_id: run_id,
        result: { "status" => "passed", "counted_run" => true },
        samples: "{\"sample\":1}\n", transactions: "{\"transaction\":1}\n",
        summary: { "thresholds_passed" => true }
      )

      assert_equal run_id, result.fetch("run_id")
      assert_raises(XrplReserveStudy::CapacityCountedArtifactsError) do
        artifacts.publish_disposition(
          run_id: run_id,
          result: { "status" => "passed", "counted_run" => true },
          samples: "{\"sample\":1}\n", transactions: "{\"transaction\":1}\n",
          summary: { "thresholds_passed" => true }
        )
    end
  end

  def test_rejects_sensitive_result_content_before_publication
    artifacts = XrplReserveStudy::CapacityCountedArtifacts.new
    assert_raises(XrplReserveStudy::CapacityCountedArtifactsError) do
      artifacts.publish_disposition(
        run_id: "r0000002-a000000001-n01",
        result: { "status" => "passed", "counted_run" => true, "secret" => "forbidden" },
        samples: "{\"sample\":1}\n", transactions: "{\"transaction\":1}\n",
        summary: { "thresholds_passed" => true }
      )
    end
  end
end
