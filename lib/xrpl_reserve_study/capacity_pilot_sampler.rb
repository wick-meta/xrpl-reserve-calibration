# frozen_string_literal: true

require "json"

module XrplReserveStudy
  class CapacityPilotSamplerError < StudyError
    attr_reader :code, :progress

    def initialize(code, progress)
      @code = code
      @progress = progress
      super("capacity pilot sampling failed (#{code})")
    end
  end

  class CapacityPilotSampler
    SAMPLE_KEYS = CapacityMetrics::Reducer::SAMPLE_KEYS
    EXECUTION_KEYS = CapacityPilotExecutionEngine::EXECUTION_KEYS
    LEDGER_KEYS = CapacityPilotExecutionEngine::LEDGER_KEYS
    HASH_PATTERN = /\A[A-F0-9]{64}\z/
    RECOVERY_POLL_SECONDS = 2
    MAX_UINT32 = 4_294_967_295
    MAX_INTEGER = (2**63) - 1
    MAX_ELAPSED_SECONDS = 3_600
    MAX_SAMPLE_BYTES = 560
    MAX_RESULT_BYTES = 500_000
    RESULT_ENVELOPE_RESERVE_BYTES = 2_048

    def initialize(collector:, ledger_advancer:, transaction_engine:, recovery_probe:,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(seconds) { sleep(seconds) }, cancellation: -> { false })
      @collector = collector
      @ledger_advancer = ledger_advancer
      @transaction_engine = transaction_engine
      @recovery_probe = recovery_probe
      @clock = monotonic_clock
      @sleeper = sleeper
      @cancellation = cancellation
      locked = LockedCapacityInputs.new(error_class: CapacityPilotSamplerError)
      @protocol = locked.pilot_protocol.data
      @runtime_pacing = @protocol.fetch("runtime_pacing")
      @abort_limits = locked.study.data.fetch("abort_rules")
      run_id = @protocol.fetch("representative_run_id")
      generator = WorkloadGenerator.new(inputs: locked)
      @destinations = 1.upto(@protocol.fetch("pilot_accounts")).map do |ordinal|
        generator.__send__(:derived_destination, run_id, ordinal)
      end.freeze
      @last_clock = nil
      @observed_advance_completions = []
    rescue CapacityPilotSamplerError
      raise
    rescue StandardError
      raise CapacityPilotSamplerError.new("invalid-sampler-configuration", empty_progress)
    end

    def run(authority:)
      post_warmup = nil
      samples = []
      transactions = []
      validated_transaction_count = 0
      @active_post_warmup = post_warmup
      @active_samples = samples
      @active_transactions = transactions
      @active_validated_transaction_count = validated_transaction_count
      @observed_advance_completions = []
      run_started = monotonic_time
      check_cancelled!(post_warmup, samples, transactions)
      wait_until(run_started + @protocol.fetch("warmup_seconds"), post_warmup, samples, transactions)
      check_cancelled!(post_warmup, samples, transactions)

      post_warmup = capture_sample("post-warmup", 0, run_started)
      @active_post_warmup = post_warmup
      validate_sample!(post_warmup, phase: "post-warmup", sequence: 0)
      ensure_aggregate_capacity!(post_warmup, samples, transactions)
      breaches = abort_breaches(nil, post_warmup)
      return sampling_result(
        "abort-rule-breach", post_warmup, samples, transactions,
        validated_transaction_count, breaches
      ) unless breaches.empty?

      previous_sample = post_warmup
      schedule = @protocol.fetch("transaction_schedule").to_h do |entry|
        [entry.fetch("measurement_sample_sequence"), entry.fetch("ordinal")]
      end

      @transaction_engine.with_authority(authority) do |engine|
        first_attempt = if schedule.key?(1)
                          previous_ledger = ledger_from_sample(previous_sample)
                          @active_previous_ledger = previous_ledger
                          engine.prepare_scheduled(
                            measurement_sample_sequence: 1, previous_ledger: previous_ledger
                          )
                        end
        check_cancelled!(post_warmup, samples, transactions)
        measurement_started = monotonic_time
        1.upto(@protocol.fetch("measurement_sample_count")) do |sequence|
          check_cancelled!(post_warmup, samples, transactions)
          advance_target = measurement_started + (sequence * @runtime_pacing.fetch("target_cadence_seconds"))
          previous_ledger = ledger_from_sample(previous_sample)
          @active_previous_ledger = previous_ledger
          advanced_ledger = if schedule.key?(sequence)
                              attempt = if sequence == 1
                                          first_attempt
                                        else
                                          engine.prepare_scheduled(
                                            measurement_sample_sequence: sequence, previous_ledger: previous_ledger
                                          )
                                        end
                              wait_for_advance_target!(advance_target, post_warmup, samples, transactions)
                              check_cancelled!(post_warmup, samples, transactions)
                              completion = nil
                              record = engine.advance_scheduled(
                                attempt: attempt, on_ledger_advance: -> { completion = monotonic_time }
                              )
                              validated_transaction_count = synchronize_validated_count!(
                                engine, validated_transaction_count
                              )
                              @active_validated_transaction_count = validated_transaction_count
                              validate_execution_record!(record, schedule.fetch(sequence), sequence, previous_ledger)
                              ensure_aggregate_capacity!(post_warmup, samples, transactions, transaction: record)
                              transactions << record
                              validate_advance_completion!(
                                advance_target, completion, post_warmup, samples, transactions,
                                validated_transaction_count
                              )
                              ledger_from_execution(record)
                            else
                              wait_for_advance_target!(advance_target, post_warmup, samples, transactions)
                              check_cancelled!(post_warmup, samples, transactions)
                              ledger = advance_ledger(previous_ledger)
                              completion = monotonic_time
                              validate_advance_completion!(
                                advance_target, completion, post_warmup, samples, transactions,
                                validated_transaction_count
                              )
                              ledger
                            end
          check_cancelled!(post_warmup, samples, transactions)

          sample = capture_sample("measurement", sequence, run_started)
          validate_sample!(sample, phase: "measurement", sequence: sequence)
          validate_sample_progression!(previous_sample, sample, advanced_ledger)
          ensure_aggregate_capacity!(post_warmup, samples, transactions, sample: sample)
          samples << sample
          previous_sample = sample
          check_cancelled!(post_warmup, samples, transactions)

          breaches = abort_breaches(samples.length == 1 ? post_warmup : samples[-2], sample)
          unless breaches.empty?
            return sampling_result(
              "abort-rule-breach", post_warmup, samples, transactions,
              validated_transaction_count, breaches
            )
          end
        end
      end

      reject!("incomplete-sampling", post_warmup, samples, transactions) unless
        samples.length == @protocol.fetch("measurement_sample_count") &&
        transactions.length == @protocol.fetch("pilot_accounts") &&
        validated_transaction_count == @protocol.fetch("pilot_accounts")
      sampling_result("completed", post_warmup, samples, transactions, validated_transaction_count, [])
    rescue CapacityPilotSamplerError
      raise
    rescue CapacityPilotExecutionError => error
      validated_transaction_count = synchronize_execution_error!(
        error, transactions, validated_transaction_count
      )
      @active_validated_transaction_count = validated_transaction_count
      code = error.code == "interrupted" ? "interrupted" : "transaction-runtime-error"
      reject!(
        code, post_warmup, samples, transactions, validated_transaction_count,
        transaction_execution_code: error.code
      )
    rescue CapacityMetricSnapshotError => error
      reject!("sampling-runtime-error", post_warmup, samples, transactions, validated_transaction_count,
              metric_snapshot_stage: error.stage)
    rescue Interrupt
      validated_transaction_count = synchronize_engine_progress!(
        @transaction_engine, validated_transaction_count, transactions
      )
      reject!("interrupted", post_warmup, samples, transactions, validated_transaction_count)
    rescue StandardError
      reject!("sampling-runtime-error", post_warmup, samples, transactions, validated_transaction_count)
    ensure
      erase_string!(authority)
      @active_post_warmup = nil
      @active_samples = nil
      @active_transactions = nil
      @active_validated_transaction_count = nil
      @active_previous_ledger = nil
    end

    def recover(restart_started_monotonic:, expected_ledger:)
      validate_ledger!(expected_ledger)
      started = validate_time_argument!(restart_started_monotonic)
      reject!("invalid-recovery-start", nil, [], []) if monotonic_time < started
      deadline = started + @protocol.dig("controlled_restart", "recovery_seconds_max")

      loop do
        check_cancelled!(nil, [], [])
        now = monotonic_time
        reject!("recovery-timeout", nil, [], []) if now > deadline
        observed = @recovery_probe.validated_ledger
        recovered_at = monotonic_time
        if observed
          begin
            validate_ledger!(observed)
            # A standalone restart creates a new genesis-ledger chain. Recovery
            # establishes that the verified candidate resumed validated-ledger
            # tracking; it does not require the pre-restart ledger hash to persist.
            if recovered_at <= deadline
              return deep_freeze(
                "recovered" => true, "recovery_seconds" => recovered_at - started,
                "validated_ledger" => deep_copy(observed)
              )
            end
          rescue CapacityPilotSamplerError
            # A malformed or unrelated probe result cannot establish recovery.
          end
        end
        reject!("recovery-timeout", nil, [], []) if recovered_at >= deadline
        remaining = deadline - recovered_at
        reject!("recovery-timeout", nil, [], []) unless remaining.positive?
        sleep_bounded([RECOVERY_POLL_SECONDS, remaining].min)
      end
    rescue CapacityPilotSamplerError
      raise
    rescue Interrupt
      reject!("interrupted", nil, [], [])
    rescue StandardError
      reject!("recovery-runtime-error", nil, [], [])
    end

    private

    def capture_sample(phase, sequence, run_started)
      @collector.capture(phase: phase, sample_sequence: sequence, run_started_monotonic: run_started)
    end

    def advance_ledger(previous)
      response = @ledger_advancer.advance(previous_ledger: previous)
      validate_ledger!(response)
      reject!("invalid-ledger-advancement", nil, [], []) unless
        response.fetch("validated_ledger_index") == previous.fetch("validated_ledger_index") + 1 &&
        response.fetch("validated_ledger_hash") != previous.fetch("validated_ledger_hash")
      response
    rescue CapacityPilotSamplerError
      raise
    rescue StandardError
      reject!("ledger-advancement-runtime-error", nil, [], [])
    end

    def validate_execution_record!(record, ordinal, sequence, previous)
      valid = record.instance_of?(Hash) && deeply_frozen?(record) && record.keys == EXECUTION_KEYS &&
        exact_string?(record["schema_version"], "capacity-pilot-execution-v1") &&
        exact_string?(record["execution_scope"], "non-counted-pilot") &&
        exact_string?(record["run_id"], @protocol.fetch("representative_run_id")) &&
        record["ordinal"].instance_of?(Integer) && record["ordinal"] == ordinal &&
        exact_string?(record["destination_account"], @destinations.fetch(ordinal - 1)) &&
        record["measurement_sample_sequence"].instance_of?(Integer) &&
        record["measurement_sample_sequence"] == sequence && valid_hash?(record["transaction_hash"]) &&
        exact_string?(record["preliminary_result"], "tesSUCCESS") &&
        exact_string?(record["final_result"], "tesSUCCESS") &&
        record["validated_ledger_index"].instance_of?(Integer) &&
        record["validated_ledger_index"].between?(1, MAX_UINT32) &&
        record["validated_ledger_index"] == previous.fetch("validated_ledger_index") + 1 &&
        valid_hash?(record["validated_ledger_hash"]) &&
        !record["validated_ledger_hash"].eql?(previous.fetch("validated_ledger_hash")) &&
        record["destination_accountroot_verified"].equal?(true) &&
        exact_string?(record["status"], "validated-success") && record["counted_run"].equal?(false)
      reject!("invalid-transaction-execution-record", nil, [], []) unless valid
    end

    def validate_sample!(sample, phase:, sequence:)
      valid = sample.instance_of?(Hash) && deeply_frozen?(sample) && sample.keys.sort == SAMPLE_KEYS.sort &&
        sample.keys.all? { |key| key.instance_of?(String) } &&
        exact_string?(sample["schema_version"], "capacity-metric-sample-v1") &&
        exact_string?(sample["phase"], phase) &&
        sample["sample_sequence"].instance_of?(Integer) && sample["sample_sequence"] == sequence &&
        sequence.between?(0, @protocol.fetch("measurement_sample_count")) &&
        bounded_numeric?(sample["elapsed_seconds"], MAX_ELAPSED_SECONDS) &&
        bounded_integer?(sample["validated_ledger_index"], MAX_UINT32, minimum: 1) &&
        valid_hash?(sample["validated_ledger_hash"]) && bounded_integer?(sample["ledger_close_time"], MAX_UINT32) &&
        bounded_integer?(sample["ledger_state_bytes"], MAX_INTEGER) &&
        bounded_integer?(sample["database_bytes"], MAX_INTEGER) &&
        bounded_integer?(sample["resident_memory_bytes"], MAX_INTEGER) &&
        bounded_integer?(sample["memory_current_bytes"], CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES) &&
        sample["memory_limit_bytes"].instance_of?(Integer) &&
        sample["memory_limit_bytes"] == CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES &&
        sample["memory_current_bytes"] <= sample["memory_limit_bytes"] &&
        bounded_numeric?(sample["process_cpu_seconds"], MAX_INTEGER) &&
        sample["allocated_logical_cpus"].instance_of?(Integer) &&
        sample["allocated_logical_cpus"] == CapacityMetrics::Reducer::ALLOCATED_LOGICAL_CPUS &&
        bounded_integer?(sample["free_disk_bytes"], MAX_INTEGER) &&
        bounded_integer?(sample["disk_total_bytes"], MAX_INTEGER, minimum: 1) &&
        sample["free_disk_bytes"] <= sample["disk_total_bytes"]
      reject!("invalid-metric-sample", nil, [], []) unless valid
      reject!("metric-sample-size-limit", nil, [], []) if JSON.generate(sample).bytesize > MAX_SAMPLE_BYTES
    rescue JSON::GeneratorError
      reject!("invalid-metric-sample", nil, [], [])
    end

    def validate_sample_progression!(previous, current, advanced)
      mismatches = []
      mismatches << "ledger-index" unless
        current.fetch("validated_ledger_index") == previous.fetch("validated_ledger_index") + 1 &&
        current.fetch("validated_ledger_index") == advanced.fetch("validated_ledger_index")
      mismatches << "ledger-hash" unless current.fetch("validated_ledger_hash") == advanced.fetch("validated_ledger_hash")
      mismatches << "elapsed" unless current.fetch("elapsed_seconds") > previous.fetch("elapsed_seconds")
      mismatches << "cpu" unless current.fetch("process_cpu_seconds") >= previous.fetch("process_cpu_seconds")
      mismatches << "ledger-state" unless current.fetch("ledger_state_bytes") >= previous.fetch("ledger_state_bytes")
      mismatches << "database" unless current.fetch("database_bytes") >= previous.fetch("database_bytes")
      reject!("sample-ledger-binding-mismatch", nil, [], [], sample_progression_mismatches: mismatches) unless mismatches.empty?
    end

    def abort_breaches(previous, current)
      breaches = []
      if previous && current.fetch("elapsed_seconds") - previous.fetch("elapsed_seconds") >
                     @abort_limits.fetch("max_ledger_close_seconds")
        breaches << "ledger-close-seconds"
      end
      if current.fetch("resident_memory_bytes") > @abort_limits.fetch("max_resident_memory_bytes")
        breaches << "resident-memory-bytes"
      end
      if current.fetch("free_disk_bytes") < @abort_limits.fetch("min_free_disk_bytes")
        breaches << "free-disk-bytes"
      end
      breaches.freeze
    end

    def wait_until(deadline, post_warmup, samples, transactions)
      reject!("invalid-deadline", post_warmup, samples, transactions) unless bounded_numeric?(deadline, MAX_INTEGER)
      loop do
        now = monotonic_time
        return if now >= deadline
        check_cancelled!(post_warmup, samples, transactions)
        sleep_bounded(deadline - now)
      end
    end

    def wait_for_advance_target!(target, post_warmup, samples, transactions)
      reject!("invalid-advance-target", post_warmup, samples, transactions) unless bounded_numeric?(target, MAX_INTEGER)
      maximum_lateness = @runtime_pacing.fetch("maximum_target_lateness_seconds")
      now = monotonic_time
      reject!("advance-deadline-missed", post_warmup, samples, transactions) if now > target + maximum_lateness
      wait_until(target, post_warmup, samples, transactions) if now < target
      now = monotonic_time
      reject!("advance-deadline-missed", post_warmup, samples, transactions) unless
        now.between?(target, target + maximum_lateness)
      now
    end

    def validate_advance_completion!(target, completion, post_warmup, samples, transactions, validated_count)
      maximum_lateness = @runtime_pacing.fetch("maximum_target_lateness_seconds")
      interval = @runtime_pacing.fetch("consecutive_completion_interval_seconds")
      valid = bounded_numeric?(completion, MAX_INTEGER) &&
        completion.between?(target, target + maximum_lateness)
      if valid && @observed_advance_completions.any?
        elapsed = completion - @observed_advance_completions.last
        valid = elapsed.between?(interval.fetch("minimum"), interval.fetch("maximum"))
      end
      reject!("advance-deadline-missed", post_warmup, samples, transactions, validated_count) unless valid
      @observed_advance_completions << completion
      completion
    end

    def sleep_bounded(duration)
      raise TypeError unless bounded_numeric?(duration, MAX_INTEGER) && duration.positive?
      @sleeper.call(duration)
      monotonic_time
    end

    def check_cancelled!(post_warmup, samples, transactions)
      value = @cancellation.call
      reject!("invalid-cancellation-signal", post_warmup, samples, transactions) unless value.equal?(true) || value.equal?(false)
      reject!("interrupted", post_warmup, samples, transactions) if value
    rescue CapacityPilotSamplerError
      raise
    rescue StandardError
      reject!("interrupted", post_warmup, samples, transactions)
    end

    def monotonic_time
      value = @clock.call
      raise TypeError unless bounded_numeric?(value, MAX_INTEGER)
      raise TypeError if @last_clock && value < @last_clock
      @last_clock = value
      value
    end

    def validate_time_argument!(value)
      raise TypeError unless bounded_numeric?(value, MAX_INTEGER)
      value
    end

    def validate_ledger!(ledger)
      valid = ledger.instance_of?(Hash) && deeply_frozen?(ledger) && ledger.keys == LEDGER_KEYS &&
        bounded_integer?(ledger["validated_ledger_index"], MAX_UINT32, minimum: 1) &&
        valid_hash?(ledger["validated_ledger_hash"])
      reject!("invalid-validated-ledger", nil, [], []) unless valid
      ledger
    end

    def ledger_from_sample(sample)
      deep_freeze(
        "validated_ledger_index" => sample.fetch("validated_ledger_index"),
        "validated_ledger_hash" => sample.fetch("validated_ledger_hash").dup
      )
    end

    def ledger_from_execution(record)
      deep_freeze(
        "validated_ledger_index" => record.fetch("validated_ledger_index"),
        "validated_ledger_hash" => record.fetch("validated_ledger_hash").dup
      )
    end

    def sampling_result(status, post_warmup, samples, transactions, validated_count, breaches)
      result = {
        "status" => status,
        "post_warmup_sample" => deep_copy(post_warmup),
        "measurement_samples" => deep_copy(samples),
        "transaction_records" => deep_copy(transactions),
        "sample_count" => (post_warmup ? 1 : 0) + samples.length,
        "validated_transaction_count" => validated_count,
        "completed_record_count" => transactions.length,
        "abort_rule_breaches" => breaches.dup
      }
      reject!("aggregate-size-limit", post_warmup, samples, transactions, validated_count) if
        JSON.generate(result).bytesize > MAX_RESULT_BYTES
      deep_freeze(result)
    rescue JSON::GeneratorError
      reject!("aggregate-size-limit", post_warmup, samples, transactions, validated_count)
    end

    def reject!(code, post_warmup, samples, transactions, validated_count = nil, **diagnostics)
      if post_warmup.nil? && @active_samples
        post_warmup = @active_post_warmup
        samples = @active_samples
        transactions = @active_transactions
      end
      validated_count = @active_validated_transaction_count if validated_count.nil?
      validated_count ||= 0
      raise CapacityPilotSamplerError.new(
        code, progress(post_warmup, samples, transactions, validated_count, diagnostics)
      )
    end

    def synchronize_execution_error!(error, transactions, current_count)
      synchronize_progress_snapshot!(
        error.progress.fetch("validated_transaction_count"), error.progress.fetch("completed_records"),
        transactions, current_count
      )
    rescue KeyError, TypeError
      current_count
    end

    def synchronize_engine_progress!(engine, current_count, transactions)
      return current_count unless engine.respond_to?(:validated_transaction_count) &&
        engine.respond_to?(:completed_records)

      synchronize_progress_snapshot!(
        engine.validated_transaction_count, engine.completed_records, transactions, current_count
      )
    rescue Interrupt
      raise
    rescue StandardError
      current_count
    end

    def synchronize_progress_snapshot!(value, completed, transactions, current_count)
      return current_count unless value.instance_of?(Integer) &&
        value.between?(current_count, @protocol.fetch("pilot_accounts"))
      return value unless completed.instance_of?(Array) &&
        completed.length.between?(transactions.length, transactions.length + 1) &&
        completed.length <= value &&
        deeply_frozen?(completed) &&
        completed.first(transactions.length).eql?(transactions)
      return value if completed.length == transactions.length || !@active_previous_ledger

      record = completed.last
      schedule = @protocol.fetch("transaction_schedule").fetch(transactions.length)
      begin
        validate_execution_record!(
          record, schedule.fetch("ordinal"), schedule.fetch("measurement_sample_sequence"),
          @active_previous_ledger
        )
        ensure_aggregate_capacity!(
          @active_post_warmup, @active_samples, transactions, transaction: record
        )
        transactions << record
      rescue CapacityPilotSamplerError
        # Invalid, duplicate, unbound, or oversized records are never fabricated into progress.
      end
      value
    end

    def synchronize_validated_count!(engine, current_count)
      return current_count unless engine.respond_to?(:validated_transaction_count)
      value = engine.validated_transaction_count
      return current_count unless value.instance_of?(Integer) &&
        value.between?(current_count, @protocol.fetch("pilot_accounts"))

      value
    rescue StandardError
      current_count
    end

    def progress(post_warmup, samples, transactions, validated_count, diagnostics = {})
      value = {
        "sample_count" => (post_warmup ? 1 : 0) + samples.length,
        "validated_transaction_count" => validated_count,
        "completed_record_count" => transactions.length,
        "post_warmup_sample" => deep_copy(post_warmup),
        "measurement_samples" => deep_copy(samples),
        "transaction_records" => deep_copy(transactions)
      }
      diagnostics.each { |key, nested| value[key.to_s] = nested if nested }
      deep_freeze(value)
    end

    def empty_progress
      deep_freeze(
        "sample_count" => 0, "validated_transaction_count" => 0, "completed_record_count" => 0,
        "post_warmup_sample" => nil,
        "measurement_samples" => [], "transaction_records" => []
      )
    end

    def ensure_aggregate_capacity!(post_warmup, samples, transactions, sample: nil, transaction: nil)
      projected_samples = sample ? samples + [sample] : samples
      projected_transactions = transaction ? transactions + [transaction] : transactions
      projection = {
        "post_warmup_sample" => post_warmup,
        "measurement_samples" => projected_samples,
        "transaction_records" => projected_transactions
      }
      reject!("aggregate-size-limit", post_warmup, samples, transactions) if
        JSON.generate(projection).bytesize > MAX_RESULT_BYTES - RESULT_ENVELOPE_RESERVE_BYTES
    rescue JSON::GeneratorError
      reject!("aggregate-size-limit", post_warmup, samples, transactions)
    end

    def valid_hash?(value)
      value.instance_of?(String) && value.match?(HASH_PATTERN)
    end

    def finite_nonnegative?(value)
      (value.instance_of?(Integer) || value.instance_of?(Float)) && value.finite? && value >= 0
    rescue NoMethodError
      false
    end

    def bounded_numeric?(value, maximum)
      finite_nonnegative?(value) && value <= maximum
    end

    def bounded_integer?(value, maximum, minimum: 0)
      value.instance_of?(Integer) && value.between?(minimum, maximum)
    end

    def exact_string?(value, expected)
      value.instance_of?(String) && value.eql?(expected)
    end

    def deeply_frozen?(value)
      return false unless value.frozen?
      case value
      when Hash then value.all? { |key, nested| deeply_frozen?(key) && deeply_frozen?(nested) }
      when Array then value.all? { |nested| deeply_frozen?(nested) }
      else true
      end
    end

    def nonnegative_integer?(value)
      value.instance_of?(Integer) && value >= 0
    end

    def erase_string!(value)
      return unless value.is_a?(String) && !value.frozen?
      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
