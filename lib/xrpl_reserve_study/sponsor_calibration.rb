# frozen_string_literal: true

require "psych"

module XrplReserveStudy
  module SponsorCalibration
    class ProtocolError < StudyError; end

    class Protocol
      TOP_LEVEL_KEYS = %w[
        schema_version candidate_release candidate_commit amendment
        counted_execution_authorized scenarios
      ].freeze
      SCENARIO_KEYS = %w[id sponsorship workload].freeze
      EXPECTED_IDS = %w[
        fee-only reserve-only combined object-mix failure-boundaries lifecycle
      ].freeze

      attr_reader :data

      def self.load(bytes, error_class: ProtocolError)
        raise error_class, "invalid Sponsor calibration protocol" unless bytes.is_a?(String)

        stream = Psych.parse_stream(bytes)
        raise error_class, "invalid Sponsor calibration protocol" unless stream.children.length == 1

        class_loader = Psych::ClassLoader::Restricted.new([], [])
        scanner = Psych::ScalarScanner.new(class_loader)
        document = stream.children.fetch(0)
        data = Psych::Visitors::NoAliasRuby.new(scanner, class_loader).accept(document.children.fetch(0))
        new(data, error_class: error_class)
      rescue Psych::Exception, KeyError, TypeError
        raise error_class, "invalid Sponsor calibration protocol"
      end

      def initialize(data, error_class: ProtocolError)
        @error_class = error_class
        validate!(data)
        @data = deep_freeze(Marshal.load(Marshal.dump(data)))
      rescue ProtocolError
        raise
      rescue StandardError
        reject!
      end

      def scenario_ids
        data.fetch("scenarios").map { |scenario| scenario.fetch("id") }
      end

      private

      def validate!(value)
        exact_hash!(value, TOP_LEVEL_KEYS)
        reject! unless value.fetch("schema_version") == "sponsor-calibration-v1"
        reject! unless value.fetch("candidate_release") == "3.3.0"
        reject! unless value.fetch("candidate_commit") == "00a178fb92ca49521b937ae1a99d863765ea8a90"
        reject! unless value.fetch("amendment") == "Sponsor"
        reject! unless value.fetch("counted_execution_authorized") == false
        scenarios = value.fetch("scenarios")
        reject! unless scenarios.is_a?(Array) && scenarios.length == EXPECTED_IDS.length
        scenarios.each do |scenario|
          exact_hash!(scenario, SCENARIO_KEYS)
          scenario.each_value { |item| reject! unless item.is_a?(String) && !item.empty? }
        end
        reject! unless scenarios.map { |scenario| scenario.fetch("id") } == EXPECTED_IDS
      rescue KeyError, TypeError
        reject!
      end

      def exact_hash!(value, keys)
        reject! unless value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array then value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end

      def reject!
        raise @error_class, "invalid Sponsor calibration protocol"
      end
    end

    class BoundaryError < StudyError; end

    module Transaction
      SPONSOR_FEE = 0x00000001
      SPONSOR_RESERVE = 0x00000002
      SPONSOR_CREATED_ACCOUNT = 0x00080000
      TEMPLATE_SCENARIOS = {
        "fee-only" => SPONSOR_FEE,
        "reserve-only" => SPONSOR_RESERVE,
        "combined" => SPONSOR_FEE | SPONSOR_RESERVE
      }.freeze

      module_function

      # Returns an unsigned, synthetic transaction shape for fixture validation.
      # Real keys and signatures are deliberately out of scope for this module.
      def template(scenario_id:, sponsor:, account:, destination:)
        flags = TEMPLATE_SCENARIOS.fetch(scenario_id) do
          raise BoundaryError, "scenario does not have a transaction template"
        end
        values = [sponsor, account, destination]
        raise BoundaryError, "invalid Sponsor transaction template" unless values.all? { |v| v.is_a?(String) && !v.empty? }

        validate!({
          "TransactionType" => "Payment", "Account" => account,
          "Destination" => destination, "Amount" => "1", "Fee" => "10",
          "Flags" => (scenario_id == "fee-only" ? 0 : SPONSOR_CREATED_ACCOUNT),
          "Sponsor" => sponsor,
          "SponsorFlags" => flags
        })
      end

      def with_signature(transaction, signing_pub_key:, txn_signature:)
        validate!(transaction)
        values = [signing_pub_key, txn_signature]
        raise BoundaryError, "invalid Sponsor signature fixture" unless values.all? { |v| v.is_a?(String) && !v.empty? }

        validate!(transaction.merge(
          "SponsorSignature" => {
            "SigningPubKey" => signing_pub_key, "TxnSignature" => txn_signature
          }
        ))
      end

      def validate!(transaction)
        reject! unless transaction.is_a?(Hash)
        signed = transaction.key?("SponsorSignature")
        expected_keys = %w[Account Amount Destination Fee Flags Sponsor SponsorFlags TransactionType]
        expected_keys += ["SponsorSignature"] if signed
        reject! unless transaction.keys.sort == expected_keys.sort
        reject! unless transaction["TransactionType"] == "Payment"
        reject! unless transaction.values_at("Account", "Destination", "Sponsor").all? do |value|
          value.is_a?(String) && !value.empty?
        end
        reject! unless transaction["Amount"].is_a?(String) && transaction["Amount"].match?(/\A[0-9]+\z/)
        reject! unless transaction["Fee"].is_a?(String) && transaction["Fee"].match?(/\A[0-9]+\z/)
        reject! unless transaction["Flags"].is_a?(Integer) && transaction["Flags"] >= 0
        sponsor_flags = transaction["SponsorFlags"]
        reject! unless TEMPLATE_SCENARIOS.values.include?(sponsor_flags)
        expected_flags = sponsor_flags == SPONSOR_FEE ? 0 : SPONSOR_CREATED_ACCOUNT
        reject! unless transaction["Flags"] == expected_flags
        if signed
          signature = transaction["SponsorSignature"]
          reject! unless signature.is_a?(Hash) && signature.keys.sort == %w[SigningPubKey TxnSignature]
          reject! unless signature.values.all? { |value| value.is_a?(String) && !value.empty? }
        end
        deep_freeze(Marshal.load(Marshal.dump(transaction)))
      rescue TypeError
        reject!
      end

      def reject!
        raise BoundaryError, "invalid Sponsor transaction fixture"
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array then value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end

    module Boundary
      AMENDMENT_ID = "BE1F90581635DBCEBFC4678C4B54FEDDC1A17B50FD02CFE765A4132A342126AC".freeze
      FEATURE_KEYS = %w[features].freeze
      OBSERVATION_KEYS = %w[
        scenario_id engine_result fee_drops sponsor_balance_drops sponsee_balance_drops
        sponsor_owner_count sponsee_owner_count sponsorship_entries
      ].freeze

      module_function

      def amendment_active?(result)
        return false unless result.is_a?(Hash) && result.keys == FEATURE_KEYS
        features = result.fetch("features")
        return false unless features.is_a?(Hash)

        feature = features[AMENDMENT_ID]
        feature.is_a?(Hash) && feature.keys.sort == %w[enabled name supported] &&
          feature["name"] == "Sponsor" && feature["supported"] == true && feature["enabled"] == true
      end

      def require_amendment!(result)
        raise BoundaryError, "Sponsor amendment is not active" unless amendment_active?(result)

        true
      end

      def validate_observation!(observation)
        reject! unless observation.is_a?(Hash) && observation.keys.sort == OBSERVATION_KEYS.sort
        reject! unless Protocol::EXPECTED_IDS.include?(observation.fetch("scenario_id"))
        reject! unless observation.fetch("engine_result") == "tesSUCCESS"
        %w[fee_drops sponsor_balance_drops sponsee_balance_drops].each do |key|
          value = observation.fetch(key)
          reject! unless value.is_a?(String) && value.match?(/\A[0-9]+\z/)
        end
        %w[sponsor_owner_count sponsee_owner_count sponsorship_entries].each do |key|
          value = observation.fetch(key)
          reject! unless value.is_a?(Integer) && value >= 0
        end
        Marshal.load(Marshal.dump(observation)).freeze
      rescue KeyError, TypeError
        reject!
      end

      def reject!
        raise BoundaryError, "invalid Sponsor transaction boundary observation"
      end
    end

    class Preflight
      def initialize(client:)
        @client = client
      end

      def verify!
        Boundary.require_amendment!(@client.call("feature", {}))
      rescue BoundaryError
        raise
      rescue StandardError
        raise BoundaryError, "Sponsor amendment preflight failed"
      end
    end
  end
end
