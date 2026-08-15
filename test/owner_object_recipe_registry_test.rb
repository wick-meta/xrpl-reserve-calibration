# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class OwnerObjectRecipeRegistryTest < Minitest::Test
  def test_registers_every_distribution_classifier_once_with_executable_recipe_fields
    recipes = XrplReserveStudy::OwnerObjectRecipeRegistry.new.all
    classifier_kinds = XrplReserveStudy::OwnerObjectDistribution::CLASSIFIERS.values

    assert_equal classifier_kinds.sort, recipes.map(&:kind).sort
    assert_equal classifier_kinds.length, recipes.length
    assert_equal recipes.length, recipes.map(&:kind).uniq.length
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
    assert_equal false, recipe.creation_steps.fetch(0).fetch("direct_injection")
    assert_equal true, recipe.creation_steps.fetch(0).fetch("validated_observation")
  end

  def test_returns_the_exact_unsupported_symbol_for_every_absent_required_feature
    recipes = XrplReserveStudy::OwnerObjectRecipeRegistry.new.all.select { |recipe| !recipe.required_amendments.empty? }

    recipes.each do |recipe|
      absent = XrplReserveStudy::OwnerObjectRecipeRegistry.new(active_amendments: recipe.required_amendments.drop(1))
      present = XrplReserveStudy::OwnerObjectRecipeRegistry.new(active_amendments: recipe.required_amendments)

      assert_equal :unsupported_candidate_feature, absent.fetch(recipe.kind), recipe.kind
      assert_instance_of XrplReserveStudy::OwnerObjectRecipeRegistry::Recipe, present.fetch(recipe.kind), recipe.kind
    end
  end

  def test_models_xchain_create_account_claim_ids_with_commit_first_attestation_and_protocol_cleanup
    recipe = XrplReserveStudy::OwnerObjectRecipeRegistry.new.fetch("xchain_owned_create_account_claim_id")

    assert_equal ["XChainAccountCreateCommit", "XChainAddAccountCreateAttestation"], recipe.creation_steps.map { |step| step.fetch("transaction_type") }
    assert_equal "first", recipe.creation_steps.fetch(1).fetch("attestation")
    assert_equal "creates_owned_object", recipe.creation_steps.fetch(1).fetch("effect")
    assert_equal ["XChainAddAccountCreateAttestation"], recipe.cleanup_steps.map { |step| step.fetch("transaction_type") }
    assert_equal "required_completion", recipe.cleanup_steps.fetch(0).fetch("attestation")
    assert_equal true, recipe.cleanup_steps.fetch(0).fetch("protocol_driven")
    refute_includes recipe.creation_steps.map { |step| step.fetch("transaction_type") }, "XChainCreateClaimID"
  end

  def test_rejects_duplicate_recipe_definitions_before_hash_conversion
    definitions = XrplReserveStudy::OwnerObjectRecipeRegistry.send(:definitions)

    error = assert_raises(XrplReserveStudy::OwnerObjectRecipeRegistryError) do
      XrplReserveStudy::OwnerObjectRecipeRegistry.send(:validate_definitions!, definitions + [definitions.first])
    end

    assert_equal "owner object recipe kinds must be unique", error.message
  end
end
