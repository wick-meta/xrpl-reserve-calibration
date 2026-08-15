# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module XrplReserveStudy
  class OperatorObjectDistributionImporter
    def import(report_path:, output_dir:, source_commit:)
      validate_commit!(source_commit)
      report = OperatorObjectReport.load(report_path)
      destination = File.expand_path(output_dir)
      raise OwnerObjectDistributionError, "output directory already exists" if File.exist?(destination)
      staging = "#{destination}.tmp-#{Process.pid}"
      raise OwnerObjectDistributionError, "temporary output directory already exists" if File.exist?(staging)

      observation = {
        "observation_method" => "indexed_aggregate_report",
        "operator_id" => report.fetch("operator_id"),
        "dataset_type" => report.fetch("dataset_type"),
        "ledger_index" => report.fetch("ledger_index"),
        "ledger_hash" => report.fetch("ledger_hash"),
        "account_roots" => report.fetch("account_roots"),
        "class_counts" => report.fetch("class_counts"),
        "query_sha256" => report.fetch("query_sha256"),
        "result_sha256" => report.fetch("result_sha256"),
        "classifier_version" => report.fetch("classifier_version")
      }
      observation["operator_evidence_url"] = report.fetch("operator_evidence_url") if report.to_h.key?("operator_evidence_url")
      bundle = {
        "schema_version" => "owner-object-distribution-bundle-v1",
        "status" => "captured", "evidence_tier" => "operator_local",
        "source_commit" => source_commit, "captured_at" => Time.now.utc.iso8601(6),
        "selection_rule" => "operator-indexed-aggregate-report-v1",
        "target_ledger_index" => report.fetch("ledger_index"), "ledger_hash" => report.fetch("ledger_hash"),
        "account_roots" => report.fetch("account_roots"), "class_counts" => report.fetch("class_counts"),
        "observations" => [observation], "class_allocation_tie_break" => "ascending-class-name"
      }
      FileUtils.mkdir_p(staging)
      File.write(File.join(staging, "owner-object-distribution.json"), JSON.pretty_generate(bundle) + "\n")
      FileUtils.mv(staging, destination)
      OwnerObjectDistribution.deep_freeze(bundle)
    rescue OwnerObjectDistributionError
      FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      raise
    end

    private

    def validate_commit!(value)
      raise OwnerObjectDistributionError, "source_commit must be a 40-character lowercase Git commit" unless value.is_a?(String) && value.match?(/\A[a-f0-9]{40}\z/)
    end
  end
end
