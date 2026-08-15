# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"
require_relative "schema_validator"

class OperatorObjectDistributionImporterTest < Minitest::Test
  COMMIT = "a" * 40

  def test_imports_a_local_aggregate_as_operator_local_distribution_evidence
    Dir.mktmpdir do |directory|
      report_path = File.join(directory, "report.json")
      output = File.join(directory, "bundle")
      File.write(report_path, JSON.generate(valid_report))

      bundle = XrplReserveStudy::OperatorObjectDistributionImporter.new.import(
        report_path: report_path, output_dir: output, source_commit: COMMIT
      )
      loaded = XrplReserveStudy::OwnerObjectDistribution.new(manifest_path: manifest_path).load(output)

      assert_equal "captured", bundle.fetch("status")
      assert_equal "operator_local", bundle.fetch("evidence_tier")
      assert_equal "indexed_aggregate_report", bundle.fetch("observations").first.fetch("observation_method")
      assert_equal 8, loaded.fetch("account_roots")
      assert_equal({ "offer" => 5, "trust_line" => 3 }, loaded.fetch("class_counts"))
      assert File.file?(File.join(output, "owner-object-distribution.json"))
      schema = JSON.parse(File.read(File.expand_path("../schemas/owner-object-distribution-bundle-v1.schema.json", __dir__)))
      assert TestSchemaValidator.valid?(schema, JSON.parse(File.read(File.join(output, "owner-object-distribution.json"))))
    end
  end

  def test_rejects_an_existing_output_directory
    Dir.mktmpdir do |directory|
      report_path = File.join(directory, "report.json")
      output = File.join(directory, "bundle")
      File.write(report_path, JSON.generate(valid_report))
      Dir.mkdir(output)

      assert_raises(XrplReserveStudy::OwnerObjectDistributionError) do
        XrplReserveStudy::OperatorObjectDistributionImporter.new.import(
          report_path: report_path, output_dir: output, source_commit: COMMIT
        )
      end
    end
  end

  def test_rejects_bundle_observations_that_mix_provenance_forms
    Dir.mktmpdir do |directory|
      report_path = File.join(directory, "report.json")
      output = File.join(directory, "bundle")
      File.write(report_path, JSON.generate(valid_report))
      XrplReserveStudy::OperatorObjectDistributionImporter.new.import(
        report_path: report_path, output_dir: output, source_commit: COMMIT
      )
      path = File.join(output, "owner-object-distribution.json")
      record = JSON.parse(File.read(path))
      record.fetch("observations").first["endpoint"] = "https://should-not-be-here.example/"
      File.write(path, JSON.generate(record))

      assert_raises(XrplReserveStudy::OwnerObjectDistributionError) do
        XrplReserveStudy::OwnerObjectDistribution.new(manifest_path: manifest_path).load(output)
      end
    end
  end

  private

  def manifest_path
    File.expand_path("../study/owner-object-endpoints-v1.yml", __dir__)
  end

  def valid_report
    {
      "schema_version" => "operator-owner-object-report-v1",
      "operator_id" => "operator-local",
      "dataset_type" => "operator_database",
      "ledger_index" => 106_285_742,
      "ledger_hash" => "A" * 64,
      "query_sha256" => "a" * 64,
      "result_sha256" => "b" * 64,
      "classifier_version" => "owner-object-classifier-v1",
      "account_roots" => 8,
      "class_counts" => { "offer" => 5, "trust_line" => 3 }
    }
  end
end
