# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/xrpl_reserve_study"
require_relative "schema_validator"

class CapacityMetricsTest < Minitest::Test
  STUDY_PATH = File.expand_path("../study/reserve-calibration-v1.yml", __dir__)
  MEMORY_LIMIT = 17_179_869_184
  DISK_TOTAL = 100_000_000_000

  def test_summarizes_exact_preregistered_metrics_and_deeply_freezes_output
    summary = reducer.summarize(
      post_warmup: sample(0, elapsed: 300, ledger: 100, state: 1_000, database: 2_000, rss: 100, memory_current: 100, cpu: 10, disk_free: 90_000_000_000),
      measurement_samples: interval_samples(Array.new(60, 30), state: 1_300, database: 2_600),
      attempted_transactions: 100,
      validated_successes: 100,
      restart_started_seconds: 3_000,
      tracking_resumed_seconds: 3_120
    )

    assert_equal "capacity-metrics-summary-v1", summary.fetch("schema_version")
    assert_equal "capacity-metrics-protocol-v1", summary.fetch("metric_protocol_version")
    assert_equal 60, summary.fetch("sample_count")
    assert_equal 100, summary.fetch("post_warmup_ledger_index")
    assert_equal 160, summary.fetch("measurement_end_ledger_index")
    assert_equal 1_800, summary.fetch("measurement_elapsed_seconds")
    assert_equal 300, summary.dig("metrics", "ledger_bytes")
    assert_equal 600, summary.dig("metrics", "database_bytes")
    assert_equal 700, summary.dig("metrics", "resident_memory_bytes")
    assert_in_delta(1.0 / 12, summary.dig("metrics", "cpu_utilization_ratio"))
    assert_equal({ "count" => 60, "minimum" => 30, "maximum" => 30, "p50" => 30, "p95" => 30 }, summary.dig("metrics", "ledger_close_seconds"))
    assert_equal 1.0, summary.dig("metrics", "transaction_success_ratio")
    assert_equal 120, summary.dig("metrics", "recovery_seconds")
    assert_equal 30_000_000_000, summary.dig("resource_minima", "free_disk_bytes")
    assert_in_delta((MEMORY_LIMIT - 700).fdiv(MEMORY_LIMIT), summary.dig("resource_minima", "free_memory_ratio"))
    assert_in_delta 0.3, summary.dig("resource_minima", "free_disk_ratio")
    assert_equal [], summary.fetch("abort_rule_breaches")
    assert_deeply_frozen(summary)
  end

  def test_uses_nearest_rank_percentiles_for_one_two_and_twenty_intervals
    { [1_800] => [1_800, 1_800], [600, 1_200] => [600, 1_200], (81..100).to_a => [90, 99] }.each do |intervals, expected|
      summary = summarize_with_intervals(intervals)
      assert_equal expected.fetch(0), summary.dig("metrics", "ledger_close_seconds", "p50"), intervals.inspect
      assert_equal expected.fetch(1), summary.dig("metrics", "ledger_close_seconds", "p95"), intervals.inspect
    end
  end

  def test_accepts_threshold_limits_with_the_nearest_valid_memory_boundary
    samples = baseline_and_intervals(Array.new(360, 5), memory_current: MEMORY_LIMIT - (MEMORY_LIMIT / 10) - 1, disk_free: 10_000_000_000)
    summary = summarize(samples, attempted: 100, successes: 99, restart: 10, resumed: 310)

    assert_equal true, summary.fetch("thresholds_passed")
    assert summary.fetch("thresholds").values.all? { |threshold| threshold.fetch("passed") }
  end

  def test_marks_every_acceptance_threshold_failure
    cases = {
      "transaction_success_ratio_min" => ->(samples) { [samples, 100, 98, 10, 20] },
      "ledger_close_seconds_p95_max" => ->(_samples) { [baseline_and_intervals([900, 900]), 100, 100, 10, 20] },
      "recovery_seconds_max" => ->(samples) { [samples, 100, 100, 10, 311] },
      "required_free_memory_ratio_min" => ->(_samples) { [baseline_and_intervals([900, 900], memory_current: MEMORY_LIMIT - 1), 100, 100, 10, 20] },
      "required_free_disk_ratio_min" => ->(_samples) { [baseline_and_intervals([900, 900], disk_free: 9_999_999_999), 100, 100, 10, 20] }
    }
    cases.each do |name, input|
      samples, attempted, successes, restart, resumed = input.call(valid_samples)
      summary = summarize(samples, attempted: attempted, successes: successes, restart: restart, resumed: resumed)
      assert_equal false, summary.fetch("thresholds_passed"), name
      assert_equal false, summary.dig("thresholds", name, "passed"), name
    end
  end

  def test_reports_every_abort_rule_breach_in_stable_order
    samples = baseline_and_intervals([31] + Array.new(354, 5), rss: MEMORY_LIMIT + 1, disk_free: 9_999_999_999)
    summary = summarize(samples)

    assert_equal %w[ledger-close-seconds resident-memory-bytes free-disk-bytes], summary.fetch("abort_rule_breaches")
  end

  def test_rejects_unknown_missing_and_mixed_type_sample_keys
    unknown = valid_samples
    unknown.fetch(1)["unexpected"] = 1
    missing = valid_samples
    missing.fetch(1).delete("database_bytes")
    mixed_type = valid_samples
    mixed_type.fetch(1)["sample_sequence"] = 1.0
    [unknown, missing, mixed_type].each do |samples|
      assert_metric_error { summarize(samples) }
    end
  end

  def test_rejects_nonfinite_values_and_wrong_fixed_sample_constants
    [Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 0)].each do |value|
      samples = valid_samples
      samples.fetch(1)["elapsed_seconds"] = value
      assert_metric_error { summarize(samples) }
    end
    samples = valid_samples
    samples.fetch(1)["memory_limit_bytes"] = MEMORY_LIMIT - 1
    assert_metric_error { summarize(samples) }
    samples = valid_samples
    samples.fetch(1)["allocated_logical_cpus"] = 3
    assert_metric_error { summarize(samples) }
  end

  # Break caught: allowing an impossible free-space ratio above one at the reducer boundary.
  def test_rejects_free_disk_bytes_above_disk_total_bytes
    samples = valid_samples
    samples.fetch(1)["free_disk_bytes"] = DISK_TOTAL + 1

    assert_metric_error { summarize(samples) }
  end

  # Break caught: emitting a summary which the published semantic schema rejects.
  def test_producer_summary_round_trips_through_the_closed_schema
    summary = summarize(valid_samples)
    schema = JSON.parse(File.binread(File.expand_path("../schemas/capacity-metrics-summary-v1.schema.json", __dir__)))

    assert TestSchemaValidator.valid?(schema, summary)
  end

  # Break caught: accepting line-terminated hashes or mutable threshold contracts in schemas.
  def test_schemas_reject_line_terminated_hashes_and_threshold_contract_mutations
    sample_schema = JSON.parse(File.binread(File.expand_path("../schemas/capacity-metric-sample-v1.schema.json", __dir__)))
    ["\n", "\r\n"].each do |terminator|
      invalid = sample(0, elapsed: 300, ledger: 100, state: 1_000, database: 2_000)
      invalid["validated_ledger_hash"] = invalid.fetch("validated_ledger_hash") + terminator
      refute TestSchemaValidator.valid?(sample_schema, invalid), terminator.inspect
    end

    summary = summarize(valid_samples)
    summary_schema = JSON.parse(File.binread(File.expand_path("../schemas/capacity-metrics-summary-v1.schema.json", __dir__)))
    assert TestSchemaValidator.valid?(summary_schema, summary)
    summary.fetch("thresholds").each do |name, threshold|
      wrong_operator = threshold.merge("operator" => threshold.fetch("operator") == ">=" ? "<=" : ">=")
      wrong_limit = threshold.merge("limit" => threshold.fetch("limit") + 1)
      refute TestSchemaValidator.valid?(
        summary_schema, summary.merge("thresholds" => summary.fetch("thresholds").merge(name => wrong_operator))
      ), "#{name} operator"
      refute TestSchemaValidator.valid?(
        summary_schema, summary.merge("thresholds" => summary.fetch("thresholds").merge(name => wrong_limit))
      ), "#{name} limit"
    end
  end

  # Break caught: mutating the process-wide fixed threshold protocol through a nested array.
  def test_threshold_protocol_constants_are_deeply_immutable
    limits = XrplReserveStudy::CapacityMetrics::Reducer::THRESHOLD_LIMITS

    assert limits.values.all?(&:frozen?)
    assert_raises(FrozenError) { limits.fetch("transaction_success_ratio_min")[0] = "<=" }
  end

  def test_rejects_sequence_time_ledger_and_hash_discontinuities
    mutations = [
      ->(samples) { samples.fetch(2)["sample_sequence"] = 3 },
      ->(samples) { samples.fetch(2)["sample_sequence"] = 1 },
      ->(samples) { samples.fetch(2)["elapsed_seconds"] = samples.fetch(1).fetch("elapsed_seconds") },
      ->(samples) { samples.fetch(2)["elapsed_seconds"] = samples.fetch(1).fetch("elapsed_seconds") - 1 },
      ->(samples) { samples.fetch(2)["validated_ledger_index"] = 104 },
      ->(samples) { samples.fetch(2)["validated_ledger_index"] = 101 },
      ->(samples) { samples.fetch(2)["validated_ledger_hash"] = samples.fetch(1).fetch("validated_ledger_hash") }
    ]
    mutations.each do |mutation|
      samples = valid_samples
      mutation.call(samples)
      assert_metric_error { summarize(samples) }
    end
  end

  def test_rejects_regressing_counters_and_end_bytes_below_baseline
    [
      ->(samples) { samples.fetch(2)["process_cpu_seconds"] = samples.fetch(1).fetch("process_cpu_seconds") - 1 },
      ->(samples) { samples.fetch(2)["ledger_state_bytes"] = samples.fetch(1).fetch("ledger_state_bytes") - 1 },
      ->(samples) { samples.fetch(2)["database_bytes"] = samples.fetch(1).fetch("database_bytes") - 1 },
      ->(samples) { samples.fetch(-1)["ledger_state_bytes"] = 999 },
      ->(samples) { samples.fetch(-1)["database_bytes"] = 1_999 }
    ].each do |mutation|
      samples = valid_samples
      mutation.call(samples)
      assert_metric_error { summarize(samples) }
    end
  end

  def test_rejects_invalid_transaction_counts_recovery_and_measurement_duration
    assert_metric_error { summarize(valid_samples, attempted: 0) }
    assert_metric_error { summarize(valid_samples, attempted: 2, successes: 3) }
    assert_metric_error { summarize(valid_samples, restart: 20, resumed: 19) }
    assert_metric_error { summarize(interval_samples([1], start_elapsed: 300, total_elapsed: 1_799)) }
  end

  def test_rejects_forbidden_shaped_keys_at_any_depth
    ["se" + "cret", "seed", "private_" + "key", "si" + "gned", "si" + "gnature", "tx_blob"].each do |name|
      samples = valid_samples
      samples.fetch(1)["nested"] = { "further" => { name => "present" } }
      assert_metric_error { summarize(samples) }
    end
  end

  private

  def reducer
    XrplReserveStudy::CapacityMetrics::Reducer.new(study_data: XrplReserveStudy::Study.new(STUDY_PATH).data)
  end

  def summarize(samples, attempted: 100, successes: 100, restart: 10, resumed: 20)
    reducer.summarize(
      post_warmup: samples.fetch(0), measurement_samples: samples.drop(1), attempted_transactions: attempted,
      validated_successes: successes, restart_started_seconds: restart, tracking_resumed_seconds: resumed
    )
  end

  def summarize_with_intervals(intervals)
    summarize(baseline_and_intervals(intervals), restart: 10, resumed: 20)
  end

  def valid_samples
    baseline_and_intervals([900, 900])
  end

  def baseline_and_intervals(intervals, **settings)
    [sample(0, elapsed: 300, ledger: 100, state: 1_000, database: 2_000, cpu: 10)] + interval_samples(intervals, **settings)
  end

  def interval_samples(intervals, start_elapsed: 300, total_elapsed: nil, state: nil, database: nil, rss: nil, memory_current: nil, cpu: nil, disk_free: nil)
    elapsed = start_elapsed
    intervals.each_with_index.map do |interval, index|
      elapsed += interval
      elapsed = start_elapsed + total_elapsed if total_elapsed && index == intervals.length - 1
      sample(
        index + 1, elapsed: elapsed, ledger: 101 + index, state: state || 1_000 + ((index + 1) * 100),
        database: database || 2_000 + ((index + 1) * 200), rss: value_for(rss, 100 + ((index + 1) * 10), index),
        memory_current: value_for(memory_current, 100 + ((index + 1) * 10), index), cpu: value_for(cpu, 10 + ((index + 1) * 10), index),
        disk_free: value_for(disk_free, 90_000_000_000 - ((index + 1) * 1_000_000_000), index)
      )
    end
  end

  def value_for(value, default, index)
    value.is_a?(Array) ? value.fetch(index) : (value || default)
  end

  def sample(sequence, elapsed:, ledger:, state:, database:, rss: 100, memory_current: 100, cpu: 10, disk_free: 90_000_000_000)
    {
      "schema_version" => "capacity-metric-sample-v1", "phase" => sequence.zero? ? "post-warmup" : "measurement",
      "sample_sequence" => sequence, "elapsed_seconds" => elapsed, "validated_ledger_index" => ledger,
      "validated_ledger_hash" => format("%064X", ledger), "ledger_close_time" => ledger,
      "ledger_state_bytes" => state, "database_bytes" => database, "resident_memory_bytes" => rss,
      "memory_current_bytes" => memory_current, "memory_limit_bytes" => MEMORY_LIMIT, "process_cpu_seconds" => cpu,
      "allocated_logical_cpus" => 4, "free_disk_bytes" => disk_free, "disk_total_bytes" => DISK_TOTAL
    }
  end

  def assert_metric_error(&block)
    error = assert_raises(XrplReserveStudy::CapacityMetrics::Error, &block)
    refute_empty error.message
  end

  def assert_deeply_frozen(value)
    assert value.frozen?, "#{value.class} was mutable"
    case value
    when Hash
      value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array
      value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
