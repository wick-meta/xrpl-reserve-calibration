# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class OwnerObjectRecipeRegistryTest < Minitest::Test
  EXPECTED_KINDS = %w[
    check deposit_preauthorization escrow nftoken_offer nftoken_page offer oracle payment_channel signer_list ticket trust_line
    amm credential did mptoken mpt_issuance permissioned_domain delegate xchain_owned_claim_id xchain_owned_create_account_claim_id
  ].freeze

  def test_registers_every_distribution_classifier_once_with_executable_recipe_fields
    recipes = XrplReserveStudy::OwnerObjectRecipeRegistry.new.all

    assert_equal EXPECTED_KINDS.sort, recipes.map(&:kind).sort
    assert_equal EXPECTED_KINDS.length, recipes.map(&:kind).uniq.length
    recipes.each do |recipe|
      assert_instance_of Array, recipe.required_amendments
      assert_instance_of Array, recipe.creation_steps
      assert_instance_of Array, recipe.cleanup_steps
      assert_kind_of Hash, recipe.finality_query
      assert_operator recipe.owner_delta, :>=, 0
      assert_includes [true, false], recipe.derived
    end
  end

  def test_marks_nftoken_pages_as_derived_mint_verified_recipes
    recipe = XrplReserveStudy::OwnerObjectRecipeRegistry.new.fetch("nftoken_page")

    assert_equal true, recipe.derived
    assert_equal ["NFTokenMint"], recipe.creation_steps.map { |step| step.fetch("transaction_type") }
    assert_equal "account_objects", recipe.finality_query.fetch("method")
    assert_equal "NFTokenPage", recipe.finality_query.fetch("ledger_entry_type")
  end

  def test_returns_the_exact_unsupported_symbol_when_a_required_feature_is_absent
    registry = XrplReserveStudy::OwnerObjectRecipeRegistry.new(active_amendments: [])

    assert_equal :unsupported_candidate_feature, registry.fetch("amm")
    refute_equal :unsupported_candidate_feature, registry.fetch("offer")
  end
end
