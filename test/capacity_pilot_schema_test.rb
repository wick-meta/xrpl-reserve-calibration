# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "schema_validator"

class CapacityPilotSchemaTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HASH = "a" * 64
  LEDGER_HASH = "B" * 64
  ACCOUNT = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"

  def test_execution_schema_accepts_only_sanitized_closed_records
    schema = schema("capacity-pilot-execution-v1.schema.json")
    record = execution_record

    assert TestSchemaValidator.valid?(schema, record)
    %w[seed secret private_key signed_blob signature host hostname username path location timezone endpoint].each do |field|
      refute TestSchemaValidator.valid?(schema, record.merge(field => "redacted")), field
    end
    [
      record.merge("ordinal" => 4),
      record.merge("measurement_sample_sequence" => 2),
      record.merge("transaction_hash" => "A" * 63),
      record.merge("validated_ledger_index" => 0),
      record.merge("destination_accountroot_verified" => false),
      record.merge("status" => "failed")
    ].each { |invalid| refute TestSchemaValidator.valid?(schema, invalid) }
  end

  def test_result_schema_accepts_all_dispositions_but_only_complete_passed_success
    schema = schema("capacity-pilot-result-v1.schema.json")
    valid_records.each_value { |value| assert TestSchemaValidator.valid?(schema, value), value.fetch("disposition_code") }

    valid_records.each do |disposition, value|
      refute TestSchemaValidator.valid?(schema, value.merge("pilot_complete" => !value.fetch("pilot_complete"))), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("status" => alternate_status(value.fetch("status")))), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("disposition_code" => alternate_disposition(disposition))), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("reset_confirmed" => false)), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("bindings_validated" => false)), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("counted_execution_authorized" => true)), disposition
      refute TestSchemaValidator.valid?(schema, value.merge("native_execution_established" => true)), disposition
    end

    threshold = valid_records.fetch("threshold-failure")
    %w[controlled_restart_recovered].each do |field|
      refute TestSchemaValidator.valid?(schema, threshold.merge(field => false)), field
    end
    [threshold.merge("sample_count" => 900), threshold.merge("transaction_count" => 2),
     threshold.merge("thresholds_passed" => true), threshold.merge("abort_rule_breached" => true)].each do |invalid|
      refute TestSchemaValidator.valid?(schema, invalid)
    end

    validation = valid_records.fetch("validation-failure")
    [validation.merge("sample_count" => 900), validation.merge("transaction_count" => 2),
     validation.merge("thresholds_passed" => true), validation.merge("abort_rule_breached" => true),
     validation.merge("controlled_restart_recovered" => true)].each do |invalid|
      refute TestSchemaValidator.valid?(schema, invalid)
    end

    breach = valid_records.fetch("abort-rule-breach")
    [breach.merge("sample_count" => 0), breach.merge("abort_rule_breached" => false),
     breach.merge("thresholds_passed" => true), breach.merge("controlled_restart_recovered" => true)].each do |invalid|
      refute TestSchemaValidator.valid?(schema, invalid)
    end

    %w[interrupted runtime-error].each do |disposition|
      value = valid_records.fetch(disposition)
      [value.merge("thresholds_passed" => true), value.merge("abort_rule_breached" => true),
       value.merge("controlled_restart_recovered" => true), value.merge("sample_count" => 902),
       value.merge("transaction_count" => 4)].each do |invalid|
        refute TestSchemaValidator.valid?(schema, invalid), disposition
      end
    end

    incomplete = valid_records.fetch("incomplete")
    [incomplete.merge("sample_count" => 1), incomplete.merge("transaction_count" => 1),
     incomplete.merge("thresholds_passed" => true), incomplete.merge("abort_rule_breached" => true),
     incomplete.merge("controlled_restart_recovered" => true)].each do |invalid|
      refute TestSchemaValidator.valid?(schema, invalid)
    end

    passed = valid_records.fetch("success")
    [passed.merge("sample_count" => 900), passed.merge("transaction_count" => 2),
     passed.merge("thresholds_passed" => false), passed.merge("abort_rule_breached" => true),
     passed.merge("controlled_restart_recovered" => false),
     passed.merge("extra" => false)].each { |invalid| refute TestSchemaValidator.valid?(schema, invalid) }
  end

  def test_partial_disposition_progress_is_bound_to_the_exact_payment_schedule
    schema = schema("capacity-pilot-result-v1.schema.json")
    assert_equal "Fully captured samples, including the post-warmup sample.",
                 schema.dig("properties", "sample_count", "description")
    assert_equal "Scheduled Payment transactions that completed validated finality.",
                 schema.dig("properties", "transaction_count", "description")
    abort_record = valid_records.fetch("abort-rule-breach")
    partial_records = %w[interrupted runtime-error].to_h do |disposition|
      [disposition, valid_records.fetch(disposition)]
    end

    [
      [1, 0], [2, 1], [449, 1], [450, 1], [451, 2], [899, 2], [900, 2], [901, 3]
    ].each do |sample_count, transaction_count|
      assert TestSchemaValidator.valid?(
        schema, abort_record.merge("sample_count" => sample_count, "transaction_count" => transaction_count)
      ), "abort #{sample_count}/#{transaction_count}"
    end
    [
      [0, 0], [1, 0], [1, 1], [2, 1], [449, 1], [450, 1], [450, 2],
      [451, 2], [899, 2], [900, 2], [900, 3], [901, 3]
    ].each do |sample_count, transaction_count|
      partial_records.each do |disposition, record|
        assert TestSchemaValidator.valid?(
          schema, record.merge("sample_count" => sample_count, "transaction_count" => transaction_count)
        ), "#{disposition} #{sample_count}/#{transaction_count}"
      end
    end

    [
      [1, 1], [2, 0], [2, 2], [450, 0], [450, 2], [451, 1], [451, 3],
      [900, 1], [900, 3], [901, 2]
    ].each do |sample_count, transaction_count|
      refute TestSchemaValidator.valid?(
        schema, abort_record.merge("sample_count" => sample_count, "transaction_count" => transaction_count)
      ), "abort #{sample_count}/#{transaction_count}"
    end
    [
      [0, 1], [1, 2], [2, 0], [2, 2], [449, 2], [450, 0], [450, 3],
      [451, 1], [451, 3], [899, 3], [900, 1], [901, 2]
    ].each do |sample_count, transaction_count|
      partial_records.each do |disposition, record|
        refute TestSchemaValidator.valid?(
          schema, record.merge("sample_count" => sample_count, "transaction_count" => transaction_count)
        ), "#{disposition} #{sample_count}/#{transaction_count}"
      end
    end
  end

  private

  def schema(name)
    JSON.parse(File.binread(File.join(ROOT, "schemas", name)))
  end

  def execution_record
    {
      "schema_version" => "capacity-pilot-execution-v1", "execution_scope" => "non-counted-pilot",
      "run_id" => "r0500000-a000010000-n01", "ordinal" => 1,
      "destination_account" => ACCOUNT, "measurement_sample_sequence" => 1,
      "transaction_hash" => "A" * 64, "preliminary_result" => "tesSUCCESS",
      "final_result" => "tesSUCCESS", "validated_ledger_index" => 2,
      "validated_ledger_hash" => LEDGER_HASH, "destination_accountroot_verified" => true,
      "status" => "validated-success", "counted_run" => false
    }
  end

  def result_record(status:, disposition:, sample_count:, transaction_count:, thresholds_passed: false,
                    abort_rule_breached: false, controlled_restart_recovered: false, pilot_complete: false)
    {
      "schema_version" => "capacity-pilot-result-v1", "pilot_scope" => "non-counted-pilot",
      "candidate_specific" => true, "status" => status, "disposition_code" => disposition,
      "pilot_complete" => pilot_complete, "counted_execution_authorized" => false,
      "native_execution_established" => false, "source_commit" => "b" * 40,
      "run_id" => "r0500000-a000010000-n01", "protocol_sha256" => HASH,
      "manifest_sha256" => HASH, "transactions_sha256" => HASH, "samples_sha256" => HASH,
      "metrics_summary_sha256" => HASH, "sample_count" => sample_count, "transaction_count" => transaction_count,
      "thresholds_passed" => thresholds_passed, "abort_rule_breached" => abort_rule_breached,
      "controlled_restart_recovered" => controlled_restart_recovered, "reset_confirmed" => true,
      "bindings_validated" => true
    }
  end

  def valid_records
    @valid_records ||= {
      "success" => result_record(status: "passed", disposition: "success", sample_count: 901,
                                 transaction_count: 3, thresholds_passed: true,
                                 controlled_restart_recovered: true, pilot_complete: true),
      "threshold-failure" => result_record(status: "failed", disposition: "threshold-failure",
                                           sample_count: 901, transaction_count: 3,
                                           controlled_restart_recovered: true),
      "validation-failure" => result_record(status: "failed", disposition: "validation-failure",
                                            sample_count: 901, transaction_count: 3),
      "incomplete" => result_record(status: "failed", disposition: "incomplete", sample_count: 0,
                                    transaction_count: 0),
      "abort-rule-breach" => result_record(status: "aborted", disposition: "abort-rule-breach",
                                           sample_count: 450, transaction_count: 1,
                                           abort_rule_breached: true),
      "interrupted" => result_record(status: "aborted", disposition: "interrupted", sample_count: 12,
                                     transaction_count: 1),
      "runtime-error" => result_record(status: "aborted", disposition: "runtime-error", sample_count: 899,
                                       transaction_count: 2)
    }
  end

  def alternate_status(status)
    ({ "passed" => "failed", "failed" => "aborted", "aborted" => "failed" }).fetch(status)
  end

  def alternate_disposition(disposition)
    case disposition
    when "success" then "threshold-failure"
    when "threshold-failure", "validation-failure", "incomplete" then "interrupted"
    else "threshold-failure"
    end
  end
end
