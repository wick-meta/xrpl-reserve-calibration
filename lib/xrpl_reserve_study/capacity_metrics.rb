# frozen_string_literal: true

module XrplReserveStudy
  module CapacityMetrics
    PROVISIONING_METRIC_NAMES = %w[
      build_wall_seconds snapshot_wall_seconds clone_wall_seconds reset_wall_seconds recovery_wall_seconds
      allocated_logical_cpus cpu_seconds peak_memory_bytes state_disk_bytes io_read_bytes io_write_bytes
      attempted_transactions validated_transactions burned_fees_drops locked_xrp_drops released_xrp_drops
      ledger_growth_bytes database_growth_bytes ledger_close_seconds_p95 max_queue_depth finality_seconds_p95
      reset_confirmed recovery_confirmed
    ].freeze

    class Error < StudyError; end

    class Reducer
      SAMPLE_KEYS = %w[
        schema_version phase sample_sequence elapsed_seconds validated_ledger_index
        validated_ledger_hash ledger_close_time ledger_state_bytes database_bytes
        resident_memory_bytes memory_current_bytes memory_limit_bytes process_cpu_seconds
        allocated_logical_cpus free_disk_bytes disk_total_bytes
      ].freeze
      METRIC_NAMES = %w[
        ledger_bytes database_bytes resident_memory_bytes cpu_utilization_ratio
        ledger_close_seconds transaction_success_ratio recovery_seconds
      ].freeze
      MEMORY_LIMIT_BYTES = 17_179_869_184
      ALLOCATED_LOGICAL_CPUS = 4
      WARMUP_SECONDS = 300
      MINIMUM_MEASUREMENT_SECONDS = 1_800
      THRESHOLD_LIMITS = {
        "transaction_success_ratio_min" => [">=", 0.99].freeze,
        "ledger_close_seconds_p95_max" => ["<=", 5.0].freeze,
        "recovery_seconds_max" => ["<=", 300].freeze,
        "required_free_memory_ratio_min" => [">=", 0.10].freeze,
        "required_free_disk_ratio_min" => [">=", 0.10].freeze
      }.freeze
      ABORT_LIMITS = {
        "max_ledger_close_seconds" => 30,
        "max_resident_memory_bytes" => MEMORY_LIMIT_BYTES,
        "min_free_disk_bytes" => 10_737_418_240
      }.freeze
      FORBIDDEN_KEY = /secret|seed|private[_-]?key|signed|signature|signing|tx_blob|transaction_blob/i

      def initialize(study_data: nil)
        @study_data = study_data || LockedCapacityInputs.new(error_class: Error).study.data
        validate_study_data!
      end

      def summarize(post_warmup:, measurement_samples:, attempted_transactions:, validated_successes:,
                    restart_started_seconds:, tracking_resumed_seconds:)
        validate_transaction_counts!(attempted_transactions, validated_successes)
        validate_recovery!(restart_started_seconds, tracking_resumed_seconds)
        validate_samples!(post_warmup, measurement_samples)

        all_samples = [post_warmup] + measurement_samples
        measurement_elapsed_seconds = measurement_samples.last.fetch("elapsed_seconds") - post_warmup.fetch("elapsed_seconds")
        reject! unless measurement_elapsed_seconds >= MINIMUM_MEASUREMENT_SECONDS

        intervals = all_samples.each_cons(2).map do |previous, current|
          current.fetch("elapsed_seconds") - previous.fetch("elapsed_seconds")
        end
        close_metrics = interval_summary(intervals)
        final_sample = measurement_samples.last
        ledger_bytes = final_sample.fetch("ledger_state_bytes") - post_warmup.fetch("ledger_state_bytes")
        database_bytes = final_sample.fetch("database_bytes") - post_warmup.fetch("database_bytes")
        reject! if ledger_bytes.negative? || database_bytes.negative?

        resident_memory_bytes = measurement_samples.map { |sample| sample.fetch("resident_memory_bytes") }.max
        cpu_utilization_ratio = (final_sample.fetch("process_cpu_seconds") - post_warmup.fetch("process_cpu_seconds")).fdiv(
          measurement_elapsed_seconds * ALLOCATED_LOGICAL_CPUS
        )
        transaction_success_ratio = validated_successes.fdiv(attempted_transactions)
        recovery_seconds = tracking_resumed_seconds - restart_started_seconds
        free_memory_ratio = measurement_samples.map do |sample|
          (sample.fetch("memory_limit_bytes") - sample.fetch("memory_current_bytes")).fdiv(sample.fetch("memory_limit_bytes"))
        end.min
        free_disk_ratio = measurement_samples.map do |sample|
          sample.fetch("free_disk_bytes").fdiv(sample.fetch("disk_total_bytes"))
        end.min
        free_disk_bytes = measurement_samples.map { |sample| sample.fetch("free_disk_bytes") }.min

        observed = {
          "transaction_success_ratio_min" => transaction_success_ratio,
          "ledger_close_seconds_p95_max" => close_metrics.fetch("p95"),
          "recovery_seconds_max" => recovery_seconds,
          "required_free_memory_ratio_min" => free_memory_ratio,
          "required_free_disk_ratio_min" => free_disk_ratio
        }
        thresholds = threshold_summary(observed)

        deep_freeze(
          "schema_version" => "capacity-metrics-summary-v1",
          "metric_protocol_version" => "capacity-metrics-protocol-v1",
          "sample_count" => measurement_samples.length,
          "post_warmup_ledger_index" => post_warmup.fetch("validated_ledger_index"),
          "measurement_end_ledger_index" => final_sample.fetch("validated_ledger_index"),
          "measurement_elapsed_seconds" => measurement_elapsed_seconds,
          "metrics" => {
            "ledger_bytes" => ledger_bytes,
            "database_bytes" => database_bytes,
            "resident_memory_bytes" => resident_memory_bytes,
            "cpu_utilization_ratio" => cpu_utilization_ratio,
            "ledger_close_seconds" => close_metrics,
            "transaction_success_ratio" => transaction_success_ratio,
            "recovery_seconds" => recovery_seconds
          },
          "resource_minima" => {
            "free_memory_ratio" => free_memory_ratio,
            "free_disk_ratio" => free_disk_ratio,
            "free_disk_bytes" => free_disk_bytes
          },
          "thresholds" => thresholds,
          "thresholds_passed" => thresholds.values.all? { |threshold| threshold.fetch("passed") },
          "abort_rule_breaches" => abort_rule_breaches(intervals, resident_memory_bytes, free_disk_bytes)
        )
      end

      private

      def validate_study_data!
        reject! unless @study_data.is_a?(Hash)
        reject! unless @study_data.fetch("metrics") == METRIC_NAMES
        reject! unless @study_data.fetch("workload").is_a?(Hash) &&
                       @study_data.fetch("workload").fetch("warmup_seconds") == WARMUP_SECONDS &&
                       @study_data.fetch("workload").fetch("measurement_seconds") == MINIMUM_MEASUREMENT_SECONDS

        thresholds = @study_data.fetch("acceptance_thresholds")
        reject! unless thresholds.is_a?(Hash)
        THRESHOLD_LIMITS.each do |name, (_operator, limit)|
          reject! unless thresholds.fetch(name) == limit
        end
        reject! unless (thresholds.keys - THRESHOLD_LIMITS.keys - ["rationale"]).empty?

        abort_rules = @study_data.fetch("abort_rules")
        reject! unless abort_rules == ABORT_LIMITS
      rescue KeyError, TypeError
        reject!
      end

      def validate_transaction_counts!(attempted, successes)
        reject! unless nonnegative_integer?(attempted) && attempted.positive?
        reject! unless nonnegative_integer?(successes) && successes <= attempted
      end

      def validate_recovery!(started, resumed)
        reject! unless finite_nonnegative_numeric?(started) && finite_nonnegative_numeric?(resumed) && resumed >= started
      end

      def validate_samples!(post_warmup, measurement_samples)
        reject! unless measurement_samples.is_a?(Array) && !measurement_samples.empty?
        validate_sample!(post_warmup, "post-warmup")
        measurement_samples.each { |sample| validate_sample!(sample, "measurement") }
        reject! unless post_warmup.fetch("elapsed_seconds") >= WARMUP_SECONDS

        all_samples = [post_warmup] + measurement_samples
        hashes = {}
        all_samples.each_cons(2) do |previous, current|
          reject! unless current.fetch("sample_sequence") == previous.fetch("sample_sequence") + 1
          reject! unless current.fetch("elapsed_seconds") > previous.fetch("elapsed_seconds")
          reject! unless current.fetch("validated_ledger_index") == previous.fetch("validated_ledger_index") + 1
          reject! unless current.fetch("process_cpu_seconds") >= previous.fetch("process_cpu_seconds")
          reject! unless current.fetch("ledger_state_bytes") >= previous.fetch("ledger_state_bytes")
          reject! unless current.fetch("database_bytes") >= previous.fetch("database_bytes")
        end
        all_samples.each do |sample|
          hash = sample.fetch("validated_ledger_hash")
          index = sample.fetch("validated_ledger_index")
          reject! if hashes.key?(hash) && hashes.fetch(hash) != index
          hashes[hash] = index
        end
      end

      def validate_sample!(sample, phase)
        reject! unless sample.is_a?(Hash)
        reject_forbidden_keys!(sample)
        reject! unless sample.keys.all? { |key| key.is_a?(String) } && sample.keys.sort == SAMPLE_KEYS.sort
        reject! unless sample.fetch("schema_version") == "capacity-metric-sample-v1" && sample.fetch("phase") == phase
        reject! unless nonnegative_integer?(sample.fetch("sample_sequence"))
        reject! unless finite_nonnegative_numeric?(sample.fetch("elapsed_seconds"))
        reject! unless positive_integer?(sample.fetch("validated_ledger_index"))
        reject! unless sample.fetch("validated_ledger_hash").is_a?(String) && sample.fetch("validated_ledger_hash").match?(/\A[A-F0-9]{64}\z/)
        %w[ledger_close_time ledger_state_bytes database_bytes resident_memory_bytes memory_current_bytes free_disk_bytes].each do |name|
          reject! unless nonnegative_integer?(sample.fetch(name))
        end
        reject! unless sample.fetch("memory_limit_bytes") == MEMORY_LIMIT_BYTES
        reject! unless sample.fetch("memory_current_bytes") <= MEMORY_LIMIT_BYTES
        reject! unless finite_nonnegative_numeric?(sample.fetch("process_cpu_seconds"))
        reject! unless sample.fetch("allocated_logical_cpus") == ALLOCATED_LOGICAL_CPUS
        reject! unless positive_integer?(sample.fetch("disk_total_bytes"))
        reject! unless sample.fetch("free_disk_bytes") <= sample.fetch("disk_total_bytes")
      rescue KeyError, TypeError
        reject!
      end

      def threshold_summary(observed)
        THRESHOLD_LIMITS.each_with_object({}) do |(name, (operator, limit)), summary|
          value = observed.fetch(name)
          passed = operator == ">=" ? value >= limit : value <= limit
          summary[name] = { "operator" => operator, "limit" => limit, "observed" => value, "passed" => passed }
        end
      end

      def interval_summary(intervals)
        ordered = intervals.sort
        {
          "count" => ordered.length,
          "minimum" => ordered.first,
          "maximum" => ordered.last,
          "p50" => nearest_rank(ordered, 0.50),
          "p95" => nearest_rank(ordered, 0.95)
        }
      end

      def nearest_rank(ordered, percentile)
        ordered[(percentile * ordered.length).ceil - 1]
      end

      def abort_rule_breaches(intervals, resident_memory_bytes, free_disk_bytes)
        breaches = []
        breaches << "ledger-close-seconds" if intervals.any? { |interval| interval > ABORT_LIMITS.fetch("max_ledger_close_seconds") }
        breaches << "resident-memory-bytes" if resident_memory_bytes > ABORT_LIMITS.fetch("max_resident_memory_bytes")
        breaches << "free-disk-bytes" if free_disk_bytes < ABORT_LIMITS.fetch("min_free_disk_bytes")
        breaches
      end

      def reject_forbidden_keys!(value)
        case value
        when Hash
          value.each do |key, nested|
            reject! if String(key).match?(FORBIDDEN_KEY)
            reject_forbidden_keys!(nested)
          end
        when Array
          value.each { |nested| reject_forbidden_keys!(nested) }
        end
      end

      def finite_nonnegative_numeric?(value)
        value.is_a?(Numeric) && value.finite? && value >= 0
      rescue NoMethodError
        false
      end

      def nonnegative_integer?(value)
        value.is_a?(Integer) && value >= 0
      end

      def positive_integer?(value)
        value.is_a?(Integer) && value.positive?
      end

      def reject!
        raise Error, "invalid capacity metrics input"
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array
          value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end
  end
end
