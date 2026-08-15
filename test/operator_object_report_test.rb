# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"
require_relative "schema_validator"

class OperatorObjectReportTest < Minitest::Test
  HASH = "A" * 64
  SHA = "a" * 64

  def test_loads_a_minimal_hash_bound_aggregate_report
    with_report(valid_report) do |path|
      report = XrplReserveStudy::OperatorObjectReport.load(path)

      assert_equal "operator-local", report.fetch("operator_id")
      assert_equal 106_285_742, report.fetch("ledger_index")
      assert_equal HASH, report.fetch("ledger_hash")
      assert_equal({ "offer" => 5, "trust_line" => 3 }, report.fetch("class_counts"))
      assert report.to_h.frozen?
      assert report.fetch("class_counts").frozen?
    end
  end

  def test_rejects_unknown_or_sensitive_content_and_malformed_binding
    cases = {
      "unknown key" => valid_report.merge("hostname" => "private.example"),
      "secret-shaped value" => valid_report.merge("operator_id" => "seed=sEdTestOnly"),
      "bad hash" => valid_report.merge("ledger_hash" => "A" * 63),
      "unknown class" => valid_report.merge("class_counts" => { "unknown" => 1 }),
      "private evidence URL" => valid_report.merge("operator_evidence_url" => "https://127.0.0.1/report")
    }
    cases.each do |label, report|
      with_report(report) do |path|
        error = assert_raises(XrplReserveStudy::OwnerObjectDistributionError, label) do
          XrplReserveStudy::OperatorObjectReport.load(path)
        end
        assert_match(/report/, error.message)
      end
    end
  end

  def test_example_conforms_to_the_closed_report_schema
    schema = JSON.parse(File.read(File.expand_path("../study/operator-owner-object-report-v1.schema.json", __dir__)))
    example = JSON.parse(File.read(File.expand_path("../study/operator-owner-object-report-v1.example.json", __dir__)))

    assert TestSchemaValidator.valid?(schema, example)
    refute TestSchemaValidator.valid?(schema, example.merge("extra" => true))
  end

  private

  def valid_report
    {
      "schema_version" => "operator-owner-object-report-v1",
      "operator_id" => "operator-local",
      "dataset_type" => "clio",
      "ledger_index" => 106_285_742,
      "ledger_hash" => HASH,
      "query_sha256" => SHA,
      "result_sha256" => "b" * 64,
      "classifier_version" => "owner-object-classifier-v1",
      "account_roots" => 8,
      "class_counts" => { "offer" => 5, "trust_line" => 3 }
    }
  end

  def with_report(record)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "report.json")
      File.write(path, JSON.generate(record))
      yield path
    end
  end
end
