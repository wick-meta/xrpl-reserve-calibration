# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class CapacityPilotSamplerTest < Minitest::Test
  MEMORY_LIMIT = XrplReserveStudy::CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES
  MIN_FREE_DISK = XrplReserveStudy::CapacityMetrics::Reducer::ABORT_LIMITS.fetch("min_free_disk_bytes")
  DESTINATIONS = %w[
    rPh7FjNmSnqQGC5zni2dA52UpxgYMy4Yc3
    rwKFceaiJ3eFYUYWrhAamfV8Z4wei5FJxq
    rrmaT2jDvv1cCzL5zLsav1XX2hXx9iXHz
  ].freeze

  class Clock
    attr_accessor :now
    attr_reader :sleeps

    def initialize(now = 0.0, overhead: 0.0)
      @now = now
      @overhead = overhead
      @sleeps = []
    end

    def call
      @now
    end

    def sleep(duration)
      @sleeps << duration
      @now += duration + @overhead
    end
  end

  class ExecutionEngine
    attr_reader :advance_calls, :completed_records, :prepare_calls, :validated_transaction_count
    attr_accessor :failure_phase, :finality_delay, :first_prepare_delay, :mutator, :shallow_record, :sign_delay, :submit_delay

    def initialize(state, clock)
      @state = state
      @clock = clock
      @prepare_calls = []
      @advance_calls = []
      @ordinal = 0
      @sign_delay = 0
      @submit_delay = 0
      @first_prepare_delay = 0
      @finality_delay = 0
      @completed_records = [].freeze
      @validated_transaction_count = 0
    end

    def with_authority(authority)
      yield self
    ensure
      authority.clear unless authority.frozen?
    end

    def prepare_scheduled(measurement_sample_sequence:, previous_ledger:)
      @prepare_calls << [measurement_sample_sequence, previous_ledger, @clock.call]
      @clock.now += @first_prepare_delay if measurement_sample_sequence == 1
      @clock.now += @sign_delay
      @clock.now += @submit_delay
      raise execution_error("runtime-error") if @failure_phase == :post_submit
      @pending = Object.new.freeze
    end

    def advance_scheduled(attempt:, on_ledger_advance: nil)
      raise "wrong attempt" unless attempt.equal?(@pending)
      sequence, previous = @prepare_calls.last.values_at(0, 1)
      @advance_calls << [sequence, @clock.call]
      @state.advance(previous_ledger: previous)
      on_ledger_advance&.call
      @validated_transaction_count += 1
      if @failure_phase == :after_finality || @failure_phase == :interrupted_after_finality
        code = @failure_phase == :interrupted_after_finality ? "interrupted" : "runtime-error"
        raise execution_error(code)
      end
      @clock.now += @finality_delay
      @ordinal += 1
      record = { "schema_version" => "capacity-pilot-execution-v1", "execution_scope" => "non-counted-pilot",
        "run_id" => "r0500000-a000010000-n01", "ordinal" => @ordinal,
        "destination_account" => DESTINATIONS.fetch(@ordinal - 1), "measurement_sample_sequence" => sequence,
        "transaction_hash" => format("%064X", @ordinal), "preliminary_result" => "tesSUCCESS",
        "final_result" => "tesSUCCESS", "validated_ledger_index" => @state.index,
        "validated_ledger_hash" => @state.hash, "destination_accountroot_verified" => true,
        "status" => "validated-success", "counted_run" => false }
      @mutator&.call(record)
      record = @shallow_record ? record.freeze : deep_freeze(record)
      @completed_records = deep_freeze(@completed_records + [record]) unless @mutator
      raise execution_error("interrupted") if @failure_phase == :after_record
      record
    end

    private

    def execution_error(code)
      progress = deep_freeze(
        "validated_transaction_count" => @validated_transaction_count,
        "completed_transaction_count" => @completed_records.length,
        "completed_records" => @completed_records.dup
      )
      XrplReserveStudy::CapacityPilotExecutionError.new(code, progress)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end

  class LedgerState
    attr_reader :advance_calls, :advance_times, :index, :hash
    attr_accessor :delay

    def initialize(clock)
      @clock = clock
      @index = 2
      @hash = format("%064X", @index).freeze
      @advance_calls = []
      @advance_times = []
      @delay = 0
    end

    def advance(previous_ledger: nil)
      @advance_calls << previous_ledger
      @advance_times << @clock.call
      @index += 1
      @hash = format("%064X", @index).freeze
      @clock.now += @delay
      ledger
    end

    def ledger
      deep_freeze("validated_ledger_index" => @index, "validated_ledger_hash" => @hash)
    end

    private

    def deep_freeze(value)
      value.each { |key, nested| key.freeze; nested.freeze }
      value.freeze
    end
  end

  class Collector
    attr_reader :calls
    attr_accessor :delay, :mutator

    def initialize(state, clock)
      @state = state
      @clock = clock
      @calls = []
      @delay = 0
    end

    def capture(phase:, sample_sequence:, run_started_monotonic:)
      @calls << [phase, sample_sequence, run_started_monotonic]
      sample = {
        "schema_version" => "capacity-metric-sample-v1", "phase" => phase,
        "sample_sequence" => sample_sequence, "elapsed_seconds" => @clock.call - run_started_monotonic,
        "validated_ledger_index" => @state.index, "validated_ledger_hash" => @state.hash,
        "ledger_close_time" => sample_sequence, "ledger_state_bytes" => sample_sequence,
        "database_bytes" => sample_sequence, "resident_memory_bytes" => 1_024,
        "memory_current_bytes" => 2_048, "memory_limit_bytes" => MEMORY_LIMIT,
        "process_cpu_seconds" => sample_sequence.to_f, "allocated_logical_cpus" => 4,
        "free_disk_bytes" => MIN_FREE_DISK + 1, "disk_total_bytes" => MIN_FREE_DISK * 2
      }
      @mutator&.call(sample)
      @clock.now += @delay
      deep_freeze(sample)
    end

    private

    def deep_freeze(value)
      value.each { |key, nested| key.freeze; nested.freeze }
      value.freeze
    end
  end

  class RecoveryProbe
    attr_reader :calls

    def initialize(values)
      @values = values
      @calls = 0
    end

    def validated_ledger
      @calls += 1
      @values.empty? ? nil : @values.shift
    end
  end

  def test_uses_absolute_deadlines_and_routes_exactly_three_scheduled_steps
    clock, state, collector, engine = fixtures
    collector.mutator = ->(sample) { clock.now += 10 if sample["phase"] == "post-warmup" }
    sampler = build_sampler(clock, state, collector, engine)
    authority = +"stubbed-authority"

    result = sampler.run(authority: authority)

    assert_equal "completed", result["status"]
    assert_equal 901, result["sample_count"]
    assert_equal 3, result["validated_transaction_count"]
    assert_equal 3, result["completed_record_count"]
    assert_equal [1, 450, 900], engine.prepare_calls.map(&:first)
    assert_equal 900, state.advance_calls.length
    assert state.advance_times.each_cons(2).all? { |left, right| right - left == 2.0 }
    assert_equal 901, collector.calls.length
    assert_equal ["post-warmup", 0, 0.0], collector.calls.first
    assert_equal ["measurement", 900, 0.0], collector.calls.last
    assert_operator result["measurement_samples"].last["elapsed_seconds"] - result["post_warmup_sample"]["elapsed_seconds"], :>=, 1_800
    assert_operator clock.sleeps.sum, :<=, 2_100
    assert_empty authority
    assert result.frozen?
  end

  def test_actual_advancement_boundaries_remain_two_seconds_apart_under_bounded_slow_work
    clock, state, collector, engine = fixtures
    engine.sign_delay = 0.75
    engine.submit_delay = 0.5
    engine.finality_delay = 0.1
    state.delay = 0.1
    collector.delay = 0.3

    result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")

    assert_equal "completed", result["status"]
    assert_equal 900, state.advance_times.length
    state.advance_times.each_cons(2).with_index do |(left, right), index|
      assert_in_delta 2.0, right - left, 1e-9, index
    end
    assert_equal engine.advance_calls.map(&:last), [state.advance_times[0], state.advance_times[449], state.advance_times[899]]
  end

  # Break caught: requiring an operating-system sleep to wake at exact floating-point equality.
  def test_repeated_real_monotonic_waits_accept_normal_bounded_overshoot
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    sampler = XrplReserveStudy::CapacityPilotSampler.new(
      collector: Object.new, ledger_advancer: Object.new, transaction_engine: Object.new,
      recovery_probe: Object.new, monotonic_clock: clock, sleeper: ->(seconds) { sleep(seconds) }
    )

    5.times do
      target = clock.call + 0.01
      observed = sampler.__send__(:wait_for_advance_target!, target, nil, [], [])
      assert_operator observed, :>=, target
      assert_operator observed, :<=, target + 1.0
    end
  end

  # Break caught: rejecting allowed timer jitter or accepting a wake after the frozen lateness ceiling.
  def test_accepts_exact_lateness_limit_and_rejects_one_over_before_advancing
    clock, state, collector, engine = fixtures(overhead: 1.0)
    result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    assert_equal "completed", result["status"]
    assert_equal 900, state.advance_times.length

    clock, state, collector, engine = fixtures(overhead: 1.000_001)
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "advance-deadline-missed", error.code
    assert_empty state.advance_times
  end

  def test_missed_advance_targets_abort_without_catch_up_bursts
    scenarios = {
      "slow signing" => ->(_state, _collector, engine) { engine.sign_delay = 3.000_001 },
      "slow submission" => ->(_state, _collector, engine) { engine.submit_delay = 3.000_001 },
      "slow collector" => ->(_state, collector, _engine) { collector.delay = 3.000_001 },
      "slow advancer" => ->(state, _collector, _engine) { state.delay = 1.000_001 }
    }
    scenarios.each do |name, configure|
      clock, state, collector, engine = fixtures
      configure.call(state, collector, engine)
      error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError, name) do
        build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
      end
      assert_equal "advance-deadline-missed", error.code, name
      expected_advances = if %w[slow\ signing slow\ submission].include?(name)
                            449
                          elsif %w[slow\ collector slow\ advancer slow\ finality].include?(name)
                            1
                          else
                            0
                          end
      assert_equal expected_advances, state.advance_times.length, name
      assert state.advance_times.each_cons(2).all? { |left, right| right - left >= 1.0 }, name
    end

    clock, state, collector, engine = fixtures(overhead: 1.000_001)
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "advance-deadline-missed", error.code
    assert_empty state.advance_times
  end

  def test_first_scheduled_payment_is_prepared_before_the_measured_cadence_begins
    clock, state, collector, engine = fixtures
    engine.first_prepare_delay = 2.250_001

    result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")

    assert_equal "completed", result["status"]
    assert_equal 3, result["validated_transaction_count"]
    assert_equal 900, state.advance_times.length
  end

  def test_finality_after_the_ledger_advance_does_not_count_as_advance_lateness
    clock, state, collector, engine = fixtures
    engine.finality_delay = 0.9

    result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")

    assert_equal "completed", result["status"]
    assert_equal 900, state.advance_times.length
  end

  def test_stops_immediately_after_each_abort_rule_breach
    mutations = {
      "resident-memory-bytes" => ->(sample) { sample["resident_memory_bytes"] = MEMORY_LIMIT + 1 },
      "free-disk-bytes" => ->(sample) { sample["free_disk_bytes"] = MIN_FREE_DISK - 1 }
    }
    mutations.each do |expected, mutation|
      clock, state, collector, engine = fixtures
      collector.mutator = mutation
      result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
      assert_equal "abort-rule-breach", result["status"]
      assert_equal [expected], result["abort_rule_breaches"]
      assert_equal 1, result["sample_count"]
      assert_empty engine.prepare_calls
      assert_empty state.advance_calls
    end

    clock, state, collector, engine = fixtures
    collector.mutator = ->(sample) { sample["elapsed_seconds"] += 31 if sample["phase"] == "measurement" && sample["sample_sequence"] == 2 }
    result = build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    assert_equal "abort-rule-breach", result["status"]
    assert_includes result["abort_rule_breaches"], "ledger-close-seconds"
    assert_equal 3, result["sample_count"]
  end

  def test_rejects_mutated_advancement_and_collector_bindings
    clock, state, collector, engine = fixtures
    bad_advancer = Object.new
    bad_advancer.define_singleton_method(:advance) do |previous_ledger:|
      { "validated_ledger_index" => previous_ledger["validated_ledger_index"] + 2,
        "validated_ledger_hash" => ("F" * 64).freeze }.freeze
    end
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, bad_advancer, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "invalid-ledger-advancement", error.code
    assert_equal 2, error.progress["sample_count"]
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 1, error.progress["completed_record_count"]

    clock, state, collector, engine = fixtures
    collector.mutator = ->(sample) { sample["validated_ledger_hash"] = "F" * 64 if sample["phase"] == "measurement" }
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "sample-ledger-binding-mismatch", error.code
    assert_equal ["ledger-hash"], error.progress.fetch("sample_progression_mismatches")
  end

  def test_rejects_invalid_clock_regression_nan_and_sleeper_behavior
    clock, state, collector, engine = fixtures
    clock.now = Float::NAN
    assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end

    clock, state, collector, engine = fixtures
    clock.now = XrplReserveStudy::CapacityPilotSampler::MAX_INTEGER + 1
    assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end

    clock, state, collector, engine = fixtures
    sleeper = ->(_duration) { clock.now -= 1 }
    assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine, sleeper: sleeper).run(authority: +"stubbed-authority")
    end
  end

  def test_enforces_numeric_equality_overflow_nonfinite_and_sample_size_boundaries
    sampler = build_sampler(*fixtures)
    max_integer = XrplReserveStudy::CapacityPilotSampler::MAX_INTEGER
    max_uint32 = XrplReserveStudy::CapacityPilotSampler::MAX_UINT32
    equality_samples = [
      metric_sample("validated_ledger_index" => max_uint32),
      metric_sample("ledger_close_time" => max_uint32),
      metric_sample("ledger_state_bytes" => max_integer),
      metric_sample("database_bytes" => max_integer),
      metric_sample("resident_memory_bytes" => max_integer),
      metric_sample("process_cpu_seconds" => max_integer),
      metric_sample("free_disk_bytes" => max_integer, "disk_total_bytes" => max_integer),
      metric_sample("disk_total_bytes" => max_integer)
    ]
    equality_samples.each_with_index do |sample, index|
      sampler.__send__(:validate_sample!, sample, phase: "measurement", sequence: 1)
      assert_operator JSON.generate(sample).bytesize, :<=, XrplReserveStudy::CapacityPilotSampler::MAX_SAMPLE_BYTES, index
    end

    invalid_samples = [
      metric_sample("validated_ledger_index" => max_uint32 + 1),
      metric_sample("ledger_close_time" => max_uint32 + 1),
      metric_sample("ledger_state_bytes" => max_integer + 1),
      metric_sample("database_bytes" => 10**100_000),
      metric_sample("process_cpu_seconds" => Float::INFINITY),
      metric_sample("process_cpu_seconds" => Float::NAN)
    ]
    invalid_samples.each do |sample|
      assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
        sampler.__send__(:validate_sample!, sample, phase: "measurement", sequence: 1)
      end
    end

    oversized = metric_sample(
      "ledger_close_time" => max_uint32, "ledger_state_bytes" => max_integer,
      "database_bytes" => max_integer, "resident_memory_bytes" => max_integer,
      "process_cpu_seconds" => max_integer, "free_disk_bytes" => max_integer,
      "disk_total_bytes" => max_integer
    )
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.__send__(:validate_sample!, oversized, phase: "measurement", sequence: 1)
    end
    assert_equal "metric-sample-size-limit", error.code
  end

  def test_stops_before_an_aggregate_serialized_result_exceeds_its_cap
    clock, state, collector, engine = fixtures
    maximum = XrplReserveStudy::CapacityPilotSampler::MAX_INTEGER
    collector.mutator = lambda do |sample|
      sample["ledger_state_bytes"] = maximum
      sample["database_bytes"] = maximum
      sample["process_cpu_seconds"] = maximum
    end
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "aggregate-size-limit", error.code
    assert_operator JSON.generate(error.progress).bytesize, :<=, XrplReserveStudy::CapacityPilotSampler::MAX_RESULT_BYTES
  end

  def test_cancellation_and_controlled_errors_preserve_exact_progress
    clock, state, collector, engine = fixtures
    checks = 0
    cancellation = -> { checks += 1; checks == 10 }
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine, cancellation: cancellation).run(authority: +"stubbed-authority")
    end
    assert_equal "interrupted", error.code
    assert_operator error.progress["sample_count"], :<=, 2
    assert_operator error.progress["validated_transaction_count"], :<=, 1

    clock, state, collector, engine = fixtures
    collector.define_singleton_method(:capture) { |**_| raise XrplReserveStudy::CapacityMetricSnapshotError, "raw child output" }
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "sampling-runtime-error", error.code
    refute_includes error.message, "raw child output"
  end

  # Break caught: a raw ledger-boundary Interrupt being downgraded after completed work.
  def test_raw_ledger_boundary_interrupt_is_interrupted_with_exact_progress
    clock, state, collector, engine = fixtures
    client = Object.new
    client.define_singleton_method(:call) { |_command, _parameters = {}| raise Interrupt }
    boundary = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory::CandidateLedgerBoundary.new(
      client: client, expected_reserve: 0.5
    )
    authority = +"stubbed-authority"
    sampler = XrplReserveStudy::CapacityPilotSampler.new(
      collector: collector, ledger_advancer: boundary, transaction_engine: engine,
      recovery_probe: boundary, monotonic_clock: clock, sleeper: clock.method(:sleep),
      cancellation: -> { false }
    )

    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.run(authority: authority)
    end

    assert_equal "interrupted", error.code
    assert_equal 2, error.progress.fetch("sample_count")
    assert_equal 1, error.progress.fetch("validated_transaction_count")
    assert_equal 1, error.progress.fetch("completed_record_count")
    assert_equal 1, error.progress.fetch("transaction_records").length
    assert_empty authority
  end

  def test_preserves_validated_finality_and_interruption_at_every_post_submit_boundary
    expectations = {
      post_submit: ["transaction-runtime-error", 0, 0],
      after_finality: ["transaction-runtime-error", 1, 0],
      interrupted_after_finality: ["interrupted", 1, 0],
      after_record: ["interrupted", 1, 1]
    }
    expectations.each do |phase, (code, validated, records)|
      clock, state, collector, engine = fixtures
      engine.failure_phase = phase
      error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError, phase) do
        build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
      end
      assert_equal code, error.code, phase
      assert_equal validated, error.progress["validated_transaction_count"], phase
      assert_equal records, error.progress["completed_record_count"], phase
      assert_equal 1, error.progress["sample_count"], phase
      assert_equal records, error.progress["transaction_records"].length, phase
    end

    clock, state, collector, engine = fixtures
    cancellation = -> { engine.advance_calls.length == 1 && collector.calls.length == 1 }
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine, cancellation: cancellation).run(authority: +"stubbed-authority")
    end
    assert_equal "interrupted", error.code
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 1, error.progress["completed_record_count"]
    assert_equal 1, error.progress["sample_count"]
  end

  # Break caught: a raw asynchronous Interrupt dropping a fully verified engine record.
  def test_raw_interrupts_preserve_exact_engine_progress_at_every_post_return_boundary
    interrupt_boundaries = %i[after_engine_return after_count_sync after_record_validation before_append after_append]
    interrupt_boundaries.each do |boundary|
      clock, state, collector, engine = fixtures
      sampler = build_sampler(clock, state, collector, engine)
      original_count_sync = sampler.method(:synchronize_validated_count!)
      original_record_validation = sampler.method(:validate_execution_record!)
      original_capacity = sampler.method(:ensure_aggregate_capacity!)
      count_sync_calls = record_validation_calls = capacity_calls = 0

      case boundary
      when :after_engine_return
        original_count = engine.method(:validated_transaction_count)
        calls = 0
        engine.define_singleton_method(:validated_transaction_count) do
          calls += 1
          raise Interrupt if calls == 1
          original_count.call
        end
      when :after_count_sync
        sampler.define_singleton_method(:synchronize_validated_count!) do |subject, current|
          value = original_count_sync.call(subject, current)
          count_sync_calls += 1
          raise Interrupt if count_sync_calls == 1
          value
        end
      when :after_record_validation
        sampler.define_singleton_method(:validate_execution_record!) do |*arguments|
          value = original_record_validation.call(*arguments)
          record_validation_calls += 1
          raise Interrupt if record_validation_calls == 1
          value
        end
      when :before_append
        sampler.define_singleton_method(:ensure_aggregate_capacity!) do |*arguments, **keywords|
          value = original_capacity.call(*arguments, **keywords)
          capacity_calls += 1
          raise Interrupt if capacity_calls == 2
          value
        end
      when :after_append
        original_capture = collector.method(:capture)
        collector.define_singleton_method(:capture) do |**keywords|
          sample = original_capture.call(**keywords)
          raise Interrupt if sample["phase"] == "measurement"
          sample
        end
      end

      error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError, boundary) do
        sampler.run(authority: +"stubbed-authority")
      end
      assert_equal "interrupted", error.code, boundary
      assert_equal 1, error.progress["validated_transaction_count"], boundary
      assert_equal 1, error.progress["completed_record_count"], boundary
      assert_equal 1, error.progress["transaction_records"].length, boundary
      assert_equal DESTINATIONS.first, error.progress.dig("transaction_records", 0, "destination_account"), boundary
    end
  end

  # Break caught: raw-interrupt reconciliation accepting an invalid engine record or appending twice.
  def test_raw_interrupt_progress_never_fabricates_or_duplicates_records
    clock, state, collector, engine = fixtures
    sampler = build_sampler(clock, state, collector, engine)
    original_count = engine.method(:validated_transaction_count)
    count_calls = 0
    engine.define_singleton_method(:validated_transaction_count) do
      count_calls += 1
      raise Interrupt if count_calls == 1
      original_count.call
    end
    original_records = engine.method(:completed_records)
    freezer = lambda do |value|
      case value
      when Hash then value.each { |key, nested| freezer.call(key); freezer.call(nested) }
      when Array then value.each { |nested| freezer.call(nested) }
      end
      value.freeze
    end
    engine.define_singleton_method(:completed_records) do
      records = Marshal.load(Marshal.dump(original_records.call))
      records.first["destination_account"] = DESTINATIONS.fetch(1)
      freezer.call(records)
    end

    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.run(authority: +"stubbed-authority")
    end
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 0, error.progress["completed_record_count"]
    assert_empty error.progress["transaction_records"]

    clock, state, collector, engine = fixtures
    sampler = build_sampler(clock, state, collector, engine)
    count_calls = 0
    engine.define_singleton_method(:validated_transaction_count) do
      count_calls += 1
      raise Interrupt if count_calls == 1
      0
    end
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.run(authority: +"stubbed-authority")
    end
    assert_equal 0, error.progress["validated_transaction_count"]
    assert_equal 0, error.progress["completed_record_count"]
    assert_empty error.progress["transaction_records"]
  end

  def test_cancellation_at_successive_boundaries_erases_authority_and_never_overstates_progress
    1.upto(20) do |target|
      clock, state, collector, engine = fixtures
      checks = 0
      cancellation = -> { checks += 1; checks == target }
      authority = +"stubbed-authority"
      error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError, target) do
        build_sampler(clock, state, collector, engine, cancellation: cancellation).run(authority: authority)
      end
      assert_equal "interrupted", error.code, target
      assert_empty authority, target
      assert_operator error.progress["sample_count"], :<=, collector.calls.length, target
      assert_operator error.progress["validated_transaction_count"], :<=, engine.advance_calls.length, target
    end
  end

  def test_rejects_mutated_transaction_record_schedule_type_and_finality_bindings
    mutations = [
      ->(record) { record["schema_version"] = "other" },
      ->(record) { record["execution_scope"] = "other" },
      ->(record) { record["run_id"] = "other" },
      ->(record) { record["ordinal"] = 2 },
      ->(record) { record["destination_account"] = "sensitive-looking-value" },
      ->(record) { record["measurement_sample_sequence"] = 1.0 },
      ->(record) { record["transaction_hash"] = "a" * 64 },
      ->(record) { record["preliminary_result"] = "tecFAILED" },
      ->(record) { record["final_result"] = "tecFAILED" },
      ->(record) { record["validated_ledger_index"] += 1 },
      ->(record) { record["validated_ledger_hash"] = "f" * 64 },
      ->(record) { record["destination_accountroot_verified"] = false },
      ->(record) { record["status"] = "failed" },
      ->(record) { record["counted_run"] = true },
      ->(record) { record["secret"] = "forbidden" }
    ]
    mutations.each do |mutation|
      clock, state, collector, engine = fixtures
      engine.mutator = mutation
      error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
        build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
      end
      assert_equal "invalid-transaction-execution-record", error.code
      assert_equal 1, error.progress["sample_count"]
      assert_equal 1, error.progress["validated_transaction_count"]
      assert_equal 0, error.progress["completed_record_count"]
    end


    clock, state, collector, engine = fixtures
    engine.shallow_record = true
    engine.mutator = ->(record) { record["destination_account"] = record["destination_account"].dup }
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine).run(authority: +"stubbed-authority")
    end
    assert_equal "invalid-transaction-execution-record", error.code
    assert_equal 1, error.progress["validated_transaction_count"]
    assert_equal 0, error.progress["completed_record_count"]
  end

  def test_recovery_accepts_a_valid_restarted_standalone_ledger_and_obeys_absolute_timeout
    clock, state, collector, engine = fixtures
    expected = state.ledger
    restarted = deep_freeze("validated_ledger_index" => 2, "validated_ledger_hash" => "F" * 64)
    probe = RecoveryProbe.new([nil, restarted])
    sampler = build_sampler(clock, state, collector, engine, recovery_probe: probe)
    result = sampler.recover(restart_started_monotonic: clock.call, expected_ledger: expected)
    assert_equal true, result["recovered"]
    assert_equal restarted, result["validated_ledger"]
    assert_equal 2, probe.calls

    clock, state, collector, engine = fixtures
    probe = RecoveryProbe.new([])
    sampler = build_sampler(clock, state, collector, engine, recovery_probe: probe)
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.recover(restart_started_monotonic: clock.call, expected_ledger: state.ledger)
    end
    assert_equal "recovery-timeout", error.code
    assert_operator clock.call, :>=, 300
    assert_equal 151, probe.calls

    clock, state, collector, engine = fixtures
    expected = state.ledger
    late_probe = Object.new
    late_probe.define_singleton_method(:validated_ledger) { clock.now += 301; expected }
    sampler = build_sampler(clock, state, collector, engine, recovery_probe: late_probe)
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      sampler.recover(restart_started_monotonic: 0.0, expected_ledger: expected)
    end
    assert_equal "recovery-timeout", error.code
    assert_equal 1, late_probe.instance_variable_get(:@calls).to_i if late_probe.instance_variable_defined?(:@calls)
  end

  def test_recovery_polls_start_just_before_equality_and_never_after_the_limit
    [0.0, 299.999, 300.0].each do |now|
      clock, state, collector, engine = fixtures
      clock.now = now
      probe = RecoveryProbe.new([state.ledger])
      result = build_sampler(clock, state, collector, engine, recovery_probe: probe).recover(
        restart_started_monotonic: 0.0, expected_ledger: state.ledger
      )
      assert_equal true, result["recovered"], now
      assert_equal now, result["recovery_seconds"], now
      assert_equal 1, probe.calls, now
    end


    clock, state, collector, engine = fixtures
    clock.now = 299.999
    probe = RecoveryProbe.new([nil, state.ledger])
    result = build_sampler(clock, state, collector, engine, recovery_probe: probe).recover(
      restart_started_monotonic: 0.0, expected_ledger: state.ledger
    )
    assert_equal true, result["recovered"]
    assert_equal 300.0, result["recovery_seconds"]
    assert_equal 2, probe.calls

    clock, state, collector, engine = fixtures
    clock.now = 300.0
    probe = RecoveryProbe.new([nil])
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine, recovery_probe: probe).recover(
        restart_started_monotonic: 0.0, expected_ledger: state.ledger
      )
    end
    assert_equal "recovery-timeout", error.code
    assert_equal 1, probe.calls

    clock, state, collector, engine = fixtures
    clock.now = 300.001
    probe = RecoveryProbe.new([state.ledger])
    error = assert_raises(XrplReserveStudy::CapacityPilotSamplerError) do
      build_sampler(clock, state, collector, engine, recovery_probe: probe).recover(
        restart_started_monotonic: 0.0, expected_ledger: state.ledger
      )
    end
    assert_equal "recovery-timeout", error.code
    assert_equal 0, probe.calls
  end

  private

  def metric_sample(overrides = {})
    sample = {
      "schema_version" => "capacity-metric-sample-v1", "phase" => "measurement",
      "sample_sequence" => 1, "elapsed_seconds" => 302.0,
      "validated_ledger_index" => 3, "validated_ledger_hash" => format("%064X", 3),
      "ledger_close_time" => 1, "ledger_state_bytes" => 1, "database_bytes" => 1,
      "resident_memory_bytes" => 1_024, "memory_current_bytes" => 2_048,
      "memory_limit_bytes" => MEMORY_LIMIT, "process_cpu_seconds" => 1.0,
      "allocated_logical_cpus" => 4, "free_disk_bytes" => MIN_FREE_DISK + 1,
      "disk_total_bytes" => MIN_FREE_DISK * 2
    }.merge(overrides)
    deep_freeze(sample)
  end

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
    when Array then value.each { |nested| deep_freeze(nested) }
    end
    value.freeze
  end

  def fixtures(overhead: 0.0)
    clock = Clock.new(0.0, overhead: overhead)
    state = LedgerState.new(clock)
    collector = Collector.new(state, clock)
    engine = ExecutionEngine.new(state, clock)
    [clock, state, collector, engine]
  end

  def build_sampler(clock, state, collector, engine, sleeper: nil, cancellation: -> { false }, recovery_probe: RecoveryProbe.new([]))
    XrplReserveStudy::CapacityPilotSampler.new(
      collector: collector, ledger_advancer: state, transaction_engine: engine,
      recovery_probe: recovery_probe, monotonic_clock: clock, sleeper: sleeper || clock.method(:sleep),
      cancellation: cancellation
    )
  end
end
