# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class SponsorCalibrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PATH = File.join(ROOT, "study", "sponsor-calibration-v1.yml")

  def test_loads_closed_candidate_specific_matrix
    protocol = XrplReserveStudy::SponsorCalibration::Protocol.load(File.binread(PATH))

    assert_equal "3.3.0", protocol.data.fetch("candidate_release")
    assert_equal false, protocol.data.fetch("counted_execution_authorized")
    assert_equal %w[
      fee-only reserve-only combined object-mix failure-boundaries lifecycle
    ], protocol.scenario_ids
  end

  def test_rejects_unknown_top_level_keys
    bytes = File.binread(PATH).sub("candidate_release: 3.3.0\n", "candidate_release: 3.3.0\nextra: true\n")

    assert_raises(XrplReserveStudy::SponsorCalibration::ProtocolError) do
      XrplReserveStudy::SponsorCalibration::Protocol.load(bytes)
    end
  end

  def test_rejects_counted_authorization
    bytes = File.binread(PATH).sub("counted_execution_authorized: false", "counted_execution_authorized: true")

    assert_raises(XrplReserveStudy::SponsorCalibration::ProtocolError) do
      XrplReserveStudy::SponsorCalibration::Protocol.load(bytes)
    end
  end

  def test_requires_active_sponsor_amendment
    result = {
      "features" => {
        XrplReserveStudy::SponsorCalibration::Boundary::AMENDMENT_ID => {
          "name" => "Sponsor", "supported" => true, "enabled" => true
        }
      }
    }

    assert_equal true, XrplReserveStudy::SponsorCalibration::Boundary.amendment_active?(result)
    assert_raises(XrplReserveStudy::SponsorCalibration::BoundaryError) do
      XrplReserveStudy::SponsorCalibration::Boundary.require_amendment!(result.merge("extra" => true))
    end
  end

  def test_rejects_sponsored_observation_with_missing_fee_or_reserve_evidence
    observation = {
      "scenario_id" => "combined", "engine_result" => "tesSUCCESS",
      "fee_drops" => "10", "sponsor_balance_drops" => "999990",
      "sponsee_balance_drops" => "1000000", "sponsor_owner_count" => 1,
      "sponsee_owner_count" => 0, "sponsorship_entries" => 1
    }

    validated = XrplReserveStudy::SponsorCalibration::Boundary.validate_observation!(observation)
    assert_equal observation, validated

    observation.delete("sponsor_balance_drops")
    assert_raises(XrplReserveStudy::SponsorCalibration::BoundaryError) do
      XrplReserveStudy::SponsorCalibration::Boundary.validate_observation!(observation)
    end
  end

  def test_preflight_queries_only_feature_state_and_requires_active_amendment
    calls = []
    client = Object.new
    client.define_singleton_method(:call) do |command, parameters = {}|
      calls << [command, parameters]
      { "features" => {
        XrplReserveStudy::SponsorCalibration::Boundary::AMENDMENT_ID => {
          "name" => "Sponsor", "supported" => true, "enabled" => true
        }
      } }
    end

    assert_equal true, XrplReserveStudy::SponsorCalibration::Preflight.new(client: client).verify!
    assert_equal [["feature", {}]], calls
  end

  def test_builds_candidate_specific_sponsor_templates
    tx = XrplReserveStudy::SponsorCalibration::Transaction.template(
      scenario_id: "fee-only", sponsor: "rSponsor", account: "rSponsee",
      destination: "rDestination"
    )

    assert_equal 1, tx.fetch("SponsorFlags")
    assert_equal "rSponsor", tx.fetch("Sponsor")
    assert_equal "rSponsee", tx.fetch("Account")
    assert_equal "rDestination", tx.fetch("Destination")
    assert_equal 0x00000000, tx.fetch("Flags")
  end

  def test_reserve_template_sets_account_creation_flag_and_combined_sets_both_flags
    reserve = XrplReserveStudy::SponsorCalibration::Transaction.template(
      scenario_id: "reserve-only", sponsor: "rSponsor", account: "rSponsee",
      destination: "rDestination"
    )
    combined = XrplReserveStudy::SponsorCalibration::Transaction.template(
      scenario_id: "combined", sponsor: "rSponsor", account: "rSponsee",
      destination: "rDestination"
    )

    assert_equal 2, reserve.fetch("SponsorFlags")
    assert_equal 0x00080000, reserve.fetch("Flags")
    assert_equal 3, combined.fetch("SponsorFlags")
    assert_equal 0x00080000, combined.fetch("Flags")
  end

  def test_rejects_invalid_sponsor_template_combinations
    assert_raises(XrplReserveStudy::SponsorCalibration::BoundaryError) do
      XrplReserveStudy::SponsorCalibration::Transaction.template(
        scenario_id: "object-mix", sponsor: "rSponsor", account: "rSponsee",
        destination: "rDestination"
      )
    end
  end

  def test_validates_sponsor_signature_shape_without_accepting_secret_material
    tx = XrplReserveStudy::SponsorCalibration::Transaction.template(
      scenario_id: "fee-only", sponsor: "rSponsor", account: "rSponsee",
      destination: "rDestination"
    )
    signed = XrplReserveStudy::SponsorCalibration::Transaction.with_signature(
      tx, signing_pub_key: "synthetic-public-key", txn_signature: "synthetic-signature"
    )

    assert_equal signed, XrplReserveStudy::SponsorCalibration::Transaction.validate!(signed)
    assert_raises(XrplReserveStudy::SponsorCalibration::BoundaryError) do
      XrplReserveStudy::SponsorCalibration::Transaction.validate!(tx.merge("SponsorFlags" => 0))
    end
    assert_raises(XrplReserveStudy::SponsorCalibration::BoundaryError) do
      XrplReserveStudy::SponsorCalibration::Transaction.with_signature(
        tx, signing_pub_key: "", txn_signature: "synthetic-signature"
      )
    end
  end
end
