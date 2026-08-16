# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "yaml"
require_relative "schema_validator"

class PublicReadinessTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONTRACT_PATH = File.join(ROOT, "study", "complete-reserves-public-contract-v1.yml")
  SHA256 = /^[0-9a-f]{64}$/

  def test_public_contract_binds_current_configs_schemas_and_operator_docs
    contract = YAML.safe_load(File.binread(CONTRACT_PATH), permitted_classes: [], aliases: false)

    assert_equal "complete-reserves-public-contract-v1", contract.fetch("schema_version")
    assert_equal false, contract.fetch("counted_execution_authorized")
    assert_equal "isolated-network-only", contract.fetch("execution_network_scope")
    assert_equal 120, contract.fetch("full_matrix_run_count")
    assert_equal 252_000, contract.fetch("serial_timed_floor_seconds")
    assert_equal "unbounded", contract.fetch("provisioning_time_status")
    assert_equal "explicit-disposition-required", contract.fetch("one_million_checkpoint")

    paths = contract.fetch("tracked_contracts").values +
      contract.fetch("record_schemas").values + contract.fetch("operator_documents").values
    assert_equal paths.uniq, paths
    paths.each do |relative|
      absolute = File.expand_path(relative, ROOT)
      assert absolute.start_with?(ROOT + File::SEPARATOR), "contract path escaped repository: #{relative}"
      assert File.file?(absolute), "contract path is missing: #{relative}"
    end

    authorization = YAML.safe_load(
      File.binread(File.join(ROOT, contract.dig("tracked_contracts", "authorization"))),
      permitted_classes: [], aliases: false
    )
    assert_equal false, authorization.fetch("authorized")
  end

  def test_secret_free_preflights_match_the_published_schema_and_disabled_state
    schema = JSON.parse(File.binread(File.join(ROOT, "schemas", "complete-reserves-preflight-v1.schema.json")))

    {
      "calibrated-v1" => { "cell_count" => 3, "timed_floor_seconds" => 6_300, "executor_available" => true },
      "full-v1" => { "cell_count" => 120, "timed_floor_seconds" => 252_000, "executor_available" => false }
    }.each do |profile, expected|
      stdout, stderr, status = Open3.capture3(
        File.join(ROOT, "bin", "reserve-study"), "complete-reserves-preflight", "--profile", profile,
        chdir: ROOT
      )
      assert status.success?, stderr
      record = JSON.parse(stdout)
      assert TestSchemaValidator.valid?(schema, record), "invalid #{profile} preflight: #{record.inspect}"
      expected.each { |key, value| assert_equal value, record.fetch(key) }
      assert_match SHA256, record.fetch("profile_sha256")
      assert_match SHA256, record.fetch("security_config_sha256")
      assert_equal "isolated-network-only", record.fetch("network_scope")
      assert_equal "unbounded", record.fetch("provisioning_time_status")
      assert_equal false, record.fetch("counted_run")
      assert_equal false, record.fetch("execution_authorized")
    end
  end

  def test_manual_complete_reserves_ci_runs_public_readiness_without_secrets
    workflow = File.binread(File.join(ROOT, ".github", "workflows", "complete-reserves.yml"))

    assert_includes workflow, "bin/check"
    assert_includes workflow, "complete-reserves-preflight --profile calibrated-v1"
    assert_includes workflow, "complete-reserves-preflight --profile full-v1"
    assert_includes workflow, "complete-reserves-matrix"
    refute_match(/secrets\.|XRPL_STANDALONE_GENESIS|pull_request_target|contents:\s*write/, workflow)
  end

  def test_public_guides_require_the_staged_operator_sequence
    readme = File.binread(File.join(ROOT, "README.md"))
    contributing = File.binread(File.join(ROOT, "CONTRIBUTING.md"))

    [readme, contributing].each do |document|
      normalized = document.gsub(/\s+/, " ")
      assert_includes normalized, "exact-ledger distribution"
      assert_includes normalized, "10k, 25k, and 50k"
      assert_includes normalized, "account-burst"
      assert_includes normalized, "object-burst"
      assert_includes normalized, "mixed"
      assert_includes normalized, "churn"
      assert_includes normalized, "recovery"
      assert_includes normalized, "1m"
      assert_includes normalized, "`measured`"
      assert_includes normalized, "`not_measured`"
      assert_includes normalized, "operator runtime adapter"
      assert_includes normalized, "120-run"
      assert_includes normalized, "hard-disabled"
      assert_includes normalized, "authorized: false"
      assert_match(/no counted complete-reserves evidence has been collected/i, normalized)
      assert_match(/no reserve-policy change is recommended/i, normalized)
    end
  end
end
