# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class AccountDeleteLifecycleTest < Minitest::Test
  def test_plan_separates_special_fee_from_base_and_owner_reserve_measurements
    plan = XrplReserveStudy::AccountDeleteLifecycle.plan

    assert_equal "account-delete-lifecycle", plan.fetch("workload_id")
    assert_equal false, plan.fetch("counted_run")
    assert_equal false, plan.fetch("execution_authorized")
    assert_equal "isolated-network-only", plan.fetch("network_scope")
    assert_equal %w[populate observe cleanup attempt_account_delete recover reset publish], plan.fetch("steps")
    assert_equal "one-owner-reserve-increment", plan.fetch("special_fee_rule")
    assert_includes plan.fetch("metrics"), "fee_burned_drops"
    assert_includes plan.fetch("metrics"), "owner_count_before"
    assert_includes plan.fetch("metrics"), "balance_transferred_drops"
    assert plan.frozen?
  end

  def test_accepts_successful_delete_only_after_obligations_and_owner_objects_are_gone
    result = XrplReserveStudy::AccountDeleteLifecycle.validate_observation(success_observation)

    assert_equal true, result.fetch("account_deleted")
    assert_equal "tesSUCCESS", result.fetch("account_delete_result")
    assert_equal 200_000, result.fetch("fee_burned_drops")
    assert_equal 0, result.fetch("owner_count_after")
    assert_equal false, result.fetch("counted_run")
    assert result.frozen?
  end

  def test_rejects_success_claim_with_blockers_or_remaining_owner_count
    assert_raises(XrplReserveStudy::AccountDeleteLifecycleError) do
      XrplReserveStudy::AccountDeleteLifecycle.validate_observation(
        success_observation.merge("deletion_blockers_before" => ["RippleState"])
      )
    end
    assert_raises(XrplReserveStudy::AccountDeleteLifecycleError) do
      XrplReserveStudy::AccountDeleteLifecycle.validate_observation(
        success_observation.merge("owner_count_after" => 1)
      )
    end
  end

  def test_requires_special_fee_even_for_a_validated_failed_delete
    failed = success_observation.merge(
      "account_delete_result" => "tecHAS_OBLIGATIONS",
      "account_deleted" => false,
      "deletion_blockers_before" => ["RippleState"],
      "owner_count_after" => 1
    )

    result = XrplReserveStudy::AccountDeleteLifecycle.validate_observation(failed)
    assert_equal false, result.fetch("account_deleted")
    assert_equal 200_000, result.fetch("fee_burned_drops")

    assert_raises(XrplReserveStudy::AccountDeleteLifecycleError) do
      XrplReserveStudy::AccountDeleteLifecycle.validate_observation(failed.merge("fee_drops" => 10, "fee_burned_drops" => 10))
    end
  end

  private

  def success_observation
    {
      "network_scope" => "isolated-network-only",
      "counted_run" => false,
      "execution_authorized" => false,
      "account_delete_result" => "tesSUCCESS",
      "account_deleted" => true,
      "fee_drops" => 200_000,
      "fee_burned_drops" => 200_000,
      "reserve_increment_drops" => 200_000,
      "base_reserve_drops" => 1_000_000,
      "owner_count_before" => 3,
      "owner_count_after" => 0,
      "deletion_blockers_before" => [],
      "cleanup_finality" => true,
      "sequence" => 100,
      "validated_ledger_index" => 400,
      "balance_before_drops" => 4_000_000,
      "balance_transferred_drops" => 3_800_000,
      "ledger_growth_bytes" => -400,
      "database_growth_bytes" => -1_200,
      "close_time_seconds" => 2.0,
      "finality_seconds" => 2.0,
      "reset_confirmed" => true,
      "recovery_confirmed" => true
    }
  end
end
