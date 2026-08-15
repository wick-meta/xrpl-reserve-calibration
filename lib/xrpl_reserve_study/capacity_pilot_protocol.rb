# frozen_string_literal: true

require "yaml"

module XrplReserveStudy
  class CapacityPilotProtocolError < StudyError; end

  class CapacityPilotProtocol
    ERROR = "invalid capacity pilot protocol"
    EXPECTED_DATA = {
      "schema_version" => "capacity-pilot-protocol-v1",
      "study_id" => "reserve-calibration-v1",
      "status" => "frozen-before-live-pilot",
      "pilot_scope" => "non-counted-pilot",
      "candidate_specific" => true,
      "candidate_release" => "3.3.0",
      "workload_name" => "accountroot-create-and-hold-v1",
      "representative_run_id" => "r0500000-a000010000-n01",
      "pilot_accounts" => 3,
      "warmup_seconds" => 300,
      "measurement_seconds" => 1_800,
      "sample_cadence_seconds" => 2,
      "sample_cadence_basis" => "between-ledger-advancements",
      "post_warmup_sample_count" => 1,
      "measurement_sample_count" => 900,
      "total_sample_count" => 901,
      "ledger_advancements_per_measurement_step" => 1,
      "transaction_type" => "Payment",
      "scheduled_transactions_per_step" => 1,
      "scheduled_step_operation_order" => %w[
        sign-one-payment
        submit-one-payment
        advance-one-standalone-ledger
      ],
      "unscheduled_transactions_per_step" => 0,
      "unscheduled_step_operation" => "advance-one-standalone-ledger-without-transaction",
      "sample_capture_stage" => "after-ledger-advancement",
      "validated_ledger_binding" => "exact-index-and-hash",
      "runtime_pacing" => {
        "target_cadence_seconds" => 2.0,
        "target_mode" => "absolute-monotonic",
        "maximum_target_lateness_seconds" => 1.0,
        "observed_boundary" => "ledger-advancement-completion",
        "consecutive_completion_interval_seconds" => { "minimum" => 1.0, "maximum" => 3.0 },
        "scheduled_preparation_stage" => "before-target"
      },
      "transaction_schedule" => [
        { "ordinal" => 1, "measurement_sample_sequence" => 1 },
        { "ordinal" => 2, "measurement_sample_sequence" => 450 },
        { "ordinal" => 3, "measurement_sample_sequence" => 900 }
      ],
      "controlled_restart" => {
        "starts_after_measurement_sample" => 900,
        "recovery_seconds_max" => 300,
        "poll_scope" => "verified-candidate-only",
        "recovery_success_condition" => "validated-ledger-tracking-resumed"
      },
      "success_requirements" => %w[
        three-validated-successful-attempts
        exactly-901-schema-valid-ordered-samples
        schema-valid-metrics-summary
        no-abort-rule-breach
        all-predeclared-thresholds-passed
        controlled-restart-recovery-validated
        confirmed-reset
        exact-source-manifest-environment-bindings
      ],
      "native_execution_established" => false,
      "counted_execution_authorized" => false,
      "cross_version_pooling_allowed" => false,
      "cross_version_generalization_allowed" => false
    }.freeze

    attr_reader :data

    def self.load(bytes, error_class: CapacityPilotProtocolError)
      raise error_class, ERROR unless bytes.is_a?(String)

      stream = Psych.parse_stream(bytes)
      unless stream.is_a?(Psych::Nodes::Stream) && stream.children.length == 1
        raise error_class, ERROR
      end
      document = stream.children.fetch(0)
      unless document.is_a?(Psych::Nodes::Document) && document.children.length == 1 && document.root
        raise error_class, ERROR
      end

      reject_duplicate_mapping_keys!(document.root, error_class)
      class_loader = Psych::ClassLoader::Restricted.new([], [])
      scanner = Psych::ScalarScanner.new(class_loader)
      new(Psych::Visitors::NoAliasRuby.new(scanner, class_loader).accept(document), error_class: error_class)
    rescue Psych::Exception
      raise error_class, ERROR
    end

    def self.reject_duplicate_mapping_keys!(node, error_class)
      if node.is_a?(Psych::Nodes::Mapping)
        seen = {}
        node.children.each_slice(2) do |key, value|
          raise error_class, ERROR unless key.is_a?(Psych::Nodes::Scalar)
          raise error_class, ERROR if seen.key?(key.value)

          seen[key.value] = true
          reject_duplicate_mapping_keys!(value, error_class)
        end
      elsif node.respond_to?(:children) && node.children
        node.children.each { |child| reject_duplicate_mapping_keys!(child, error_class) }
      end
    end
    private_class_method :reject_duplicate_mapping_keys!

    def initialize(data, error_class: CapacityPilotProtocolError)
      @error_class = error_class
      exact_value!(data, EXPECTED_DATA)
      @data = deep_freeze(copy(data))
    rescue CapacityPilotProtocolError
      raise
    rescue StandardError
      reject!
    end

    private

    def exact_value!(actual, expected)
      case expected
      when Hash
        reject! unless actual.instance_of?(Hash) && actual.keys == expected.keys
        expected.each { |key, value| exact_value!(actual.fetch(key), value) }
      when Array
        reject! unless actual.instance_of?(Array) && actual.length == expected.length
        expected.each_index { |index| exact_value!(actual.fetch(index), expected.fetch(index)) }
      when String
        reject! unless actual.instance_of?(String) && actual == expected
      when Integer
        reject! unless actual.instance_of?(Integer) && actual == expected
      when Float
        reject! unless actual.instance_of?(Float) && actual.eql?(expected)
      when TrueClass, FalseClass
        reject! unless actual.equal?(expected)
      else
        reject!
      end
    end

    def copy(value)
      case value
      when Hash then value.each_with_object({}) { |(key, nested), result| result[key.dup] = copy(nested) }
      when Array then value.map { |nested| copy(nested) }
      when String then value.dup
      else value
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise @error_class, ERROR
    end
  end
end
