# frozen_string_literal: true

require "yaml"

module XrplReserveStudy
  class ProtocolAlignmentError < StudyError; end

  class ProtocolAlignment
    TOP_LEVEL_KEYS = %w[
      schema_version study_id status effective_stage original_reference candidate_execution_target
      resolution source_impact_assessment remaining_gates
    ].freeze
    REFERENCE_KEYS = %w[release commit annotated_tag_object tag_verification release_url].freeze
    RESOLUTION_KEYS = %w[
      method implementation_equivalence_claimed cross_version_pooling_allowed
      cross_version_generalization_allowed original_study_modified matrix_modified metrics_modified
      thresholds_modified abort_rules_modified randomization_modified counted_execution_authorized
    ].freeze
    IMPACT_KEYS = %w[area classification disposition].freeze

    EXPECTED_TOP_LEVEL = {
      "schema_version" => "reserve-calibration-protocol-alignment-v1",
      "study_id" => "reserve-calibration-v1",
      "status" => "resolved-prospectively",
      "effective_stage" => "before-non-counted-pilot"
    }.freeze
    EXPECTED_ORIGINAL_REFERENCE = {
      "release" => "3.1.3",
      "commit" => "46b241ace8b30d9c9775d60ffba7d24b21903896",
      "annotated_tag_object" => "7645ce97240e0662774902be39e8eaa3c638c89b",
      "tag_verification" => "verified",
      "release_url" => "https://github.com/XRPLF/rippled/releases/tag/3.1.3"
    }.freeze
    EXPECTED_CANDIDATE_EXECUTION_TARGET = {
      "release" => "3.3.0",
      "commit" => "00a178fb92ca49521b937ae1a99d863765ea8a90",
      "annotated_tag_object" => "32a8a5d561d157aa54d7a90d50e4e765607692b1",
      "tag_verification" => "verified",
      "release_url" => "https://github.com/XRPLF/rippled/releases/tag/3.3.0"
    }.freeze
    EXPECTED_RESOLUTION = {
      "method" => "prospective-candidate-specific-amendment",
      "implementation_equivalence_claimed" => false,
      "cross_version_pooling_allowed" => false,
      "cross_version_generalization_allowed" => false,
      "original_study_modified" => false,
      "matrix_modified" => false,
      "metrics_modified" => false,
      "thresholds_modified" => false,
      "abort_rules_modified" => false,
      "randomization_modified" => false,
      "counted_execution_authorized" => false
    }.freeze
    EXPECTED_IMPACTS = [
      {
        "area" => "reserve-semantics",
        "classification" => "material-candidate-factor",
        "disposition" => "explicit-candidate-configuration-and-runtime-reserve-verification"
      },
      {
        "area" => "payment-accountroot-workload",
        "classification" => "candidate-validated-not-equivalence",
        "disposition" => "functional-smoke-and-non-counted-pilot-required"
      },
      {
        "area" => "api-v2-ledger-capture",
        "classification" => "material-candidate-factor",
        "disposition" => "fixed-api-version-and-live-pilot-validation-required"
      },
      {
        "area" => "storage-and-resource-behavior",
        "classification" => "material-candidate-factor",
        "disposition" => "candidate-only-measurement-no-cross-version-pooling"
      }
    ].freeze
    EXPECTED_REMAINING_GATES = %w[pilot-validation native-execution].freeze

    attr_reader :data

    def self.load(bytes, error_class: ProtocolAlignmentError)
      raise error_class, "invalid protocol alignment record" unless bytes.is_a?(String)

      stream = Psych.parse_stream(bytes)
      unless stream.is_a?(Psych::Nodes::Stream) && stream.children.length == 1
        raise error_class, "invalid protocol alignment record"
      end

      document = stream.children.fetch(0)
      unless document.is_a?(Psych::Nodes::Document) && document.children.length == 1 && document.root
        raise error_class, "invalid protocol alignment record"
      end

      reject_duplicate_mapping_keys!(document.root, error_class)
      class_loader = Psych::ClassLoader::Restricted.new([], [])
      scanner = Psych::ScalarScanner.new(class_loader)
      data = Psych::Visitors::NoAliasRuby.new(scanner, class_loader).accept(document)
      new(data, error_class: error_class)
    rescue Psych::Exception
      raise error_class, "invalid protocol alignment record"
    end

    def self.reject_duplicate_mapping_keys!(node, error_class)
      if node.is_a?(Psych::Nodes::Mapping)
        seen = {}
        node.children.each_slice(2) do |key_node, value_node|
          unless key_node.is_a?(Psych::Nodes::Scalar)
            raise error_class, "invalid protocol alignment record"
          end
          raise error_class, "invalid protocol alignment record" if seen.key?(key_node.value)

          seen[key_node.value] = true
          reject_duplicate_mapping_keys!(value_node, error_class)
        end
      elsif node.respond_to?(:children) && node.children
        node.children.each { |child| reject_duplicate_mapping_keys!(child, error_class) }
      end
    end
    private_class_method :reject_duplicate_mapping_keys!

    def initialize(data, error_class: ProtocolAlignmentError)
      @error_class = error_class
      validate!(data)
      @data = deep_freeze(copy(data))
    rescue ProtocolAlignmentError
      raise
    rescue StandardError
      reject!
    end

    private

    def validate!(value)
      exact_hash!(value, TOP_LEVEL_KEYS)
      EXPECTED_TOP_LEVEL.each do |key, expected|
        string!(value.fetch(key))
        reject! unless value.fetch(key) == expected
      end
      exact_reference!(value.fetch("original_reference"), EXPECTED_ORIGINAL_REFERENCE)
      exact_reference!(value.fetch("candidate_execution_target"), EXPECTED_CANDIDATE_EXECUTION_TARGET)
      exact_resolution!(value.fetch("resolution"))
      exact_impacts!(value.fetch("source_impact_assessment"))
      exact_gates!(value.fetch("remaining_gates"))
    end

    def exact_reference!(value, expected)
      exact_hash!(value, REFERENCE_KEYS)
      value.each_value { |nested| string!(nested) }
      reject! unless value == expected
    end

    def exact_resolution!(value)
      exact_hash!(value, RESOLUTION_KEYS)
      string!(value.fetch("method"))
      (RESOLUTION_KEYS - ["method"]).each { |key| boolean!(value.fetch(key)) }
      reject! unless value == EXPECTED_RESOLUTION
    end

    def exact_impacts!(value)
      array!(value)
      reject! unless value.length == EXPECTED_IMPACTS.length
      value.each do |impact|
        exact_hash!(impact, IMPACT_KEYS)
        impact.each_value { |nested| string!(nested) }
      end
      reject! unless value == EXPECTED_IMPACTS
    end

    def exact_gates!(value)
      array!(value)
      value.each { |gate| string!(gate) }
      reject! unless value == EXPECTED_REMAINING_GATES
    end

    def exact_hash!(value, keys)
      reject! unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == keys.sort
    end

    def array!(value)
      reject! unless value.is_a?(Array)
    end

    def string!(value)
      reject! unless value.is_a?(String)
    end

    def boolean!(value)
      reject! unless value.equal?(true) || value.equal?(false)
    end

    def copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, nested), result| result[key.dup] = copy(nested) }
      when Array
        value.map { |nested| copy(nested) }
      when String
        value.dup
      else
        value
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
      raise @error_class, "invalid protocol alignment record"
    end
  end
end
