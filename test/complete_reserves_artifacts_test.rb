# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CompleteReservesArtifactsTest < Minitest::Test
  def test_rejects_sensitive_or_incomplete_result_before_publication
    artifacts = XrplReserveStudy::CompleteReservesArtifacts.new
    result = { "run_id" => "cr-test", "status" => "passed", "counted_run" => false, "distribution_sha256" => "a" * 64,
               "snapshot_id" => "snapshot", "object_counts_by_class" => { "offer" => 1 }, "locked_xrp_drops" => 1,
               "released_xrp_drops" => 1, "owner_count_lifecycle" => [0, 1, 0] }
    assert_raises(XrplReserveStudy::CompleteReservesArtifactsError) { artifacts.publish_disposition(result: result.merge("secret" => "no"), summary: {}) }
  end
end
