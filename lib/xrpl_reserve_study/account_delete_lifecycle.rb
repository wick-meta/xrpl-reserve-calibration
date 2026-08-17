# frozen_string_literal: true

module XrplReserveStudy
  class AccountDeleteLifecycleError < StudyError; end

  class AccountDeleteLifecycle
    WORKLOAD_ID = "account-delete-lifecycle"
    NETWORK_SCOPE = "isolated-network-only"
    SPECIAL_FEE_RULE = "one-owner-reserve-increment"
    MAX_OWNED_OBJECTS = 1_000
    SUCCESS_RESULT = "tesSUCCESS"
    FAILURE_RESULTS = %w[
      tecHAS_OBLIGATIONS tefTOO_BIG tecTOO_SOON tecNO_DST
      tecDST_TAG_NEEDED tecNO_PERMISSION
    ].freeze
    REQUIRED_KEYS = %w[
      network_scope counted_run execution_authorized account_delete_result
      account_deleted fee_drops fee_burned_drops reserve_increment_drops
      base_reserve_drops owner_count_before owner_count_after
      deletion_blockers_before cleanup_finality sequence validated_ledger_index
      balance_before_drops balance_transferred_drops ledger_growth_bytes
      database_growth_bytes close_time_seconds finality_seconds
      reset_confirmed recovery_confirmed
    ].freeze

    class << self
      def plan
        deep_freeze(
          "schema_version" => "account-delete-lifecycle-v1",
          "workload_id" => WORKLOAD_ID,
          "network_scope" => NETWORK_SCOPE,
          "counted_run" => false,
          "execution_authorized" => false,
          "special_fee_rule" => SPECIAL_FEE_RULE,
          "max_owned_objects" => MAX_OWNED_OBJECTS,
          "steps" => %w[populate observe cleanup attempt_account_delete recover reset publish],
          "metrics" => %w[
            fee_drops fee_burned_drops reserve_increment_drops base_reserve_drops
            owner_count_before owner_count_after deletion_blockers_before
            balance_before_drops balance_transferred_drops ledger_growth_bytes
            database_growth_bytes close_time_seconds finality_seconds
            cleanup_finality reset_confirmed recovery_confirmed
          ]
        )
      end

      def validate_observation(observation)
        reject! unless observation.is_a?(Hash) && observation.keys.sort == REQUIRED_KEYS.sort
        reject! unless observation["network_scope"] == NETWORK_SCOPE
        reject! unless observation["counted_run"] == false && observation["execution_authorized"] == false
        reject! unless observation["account_delete_result"] == SUCCESS_RESULT || FAILURE_RESULTS.include?(observation["account_delete_result"])
        reject! unless [true, false].include?(observation["account_deleted"])
        integer_keys = %w[fee_drops fee_burned_drops reserve_increment_drops base_reserve_drops owner_count_before owner_count_after sequence validated_ledger_index balance_before_drops balance_transferred_drops]
        integer_keys.each { |key| reject! unless observation[key].is_a?(Integer) && observation[key] >= 0 }
        reject! unless observation["fee_drops"] >= observation["reserve_increment_drops"]
        reject! unless observation["fee_burned_drops"] == observation["fee_drops"]
        reject! unless observation["owner_count_before"] <= MAX_OWNED_OBJECTS
        reject! unless observation["owner_count_after"] <= MAX_OWNED_OBJECTS
        reject! unless observation["validated_ledger_index"] >= observation["sequence"] + 255
        reject! unless observation["deletion_blockers_before"].is_a?(Array)
        reject! unless [true, false].include?(observation["cleanup_finality"])
        reject! unless observation["balance_transferred_drops"] <= observation["balance_before_drops"] - observation["fee_drops"]
        %w[ledger_growth_bytes database_growth_bytes close_time_seconds finality_seconds].each do |key|
          reject! unless observation[key].is_a?(Numeric) && observation[key].finite?
        end
        %w[reset_confirmed recovery_confirmed].each { |key| reject! unless [true, false].include?(observation[key]) }

        if observation["account_deleted"]
          reject! unless observation["account_delete_result"] == SUCCESS_RESULT
          reject! unless observation["deletion_blockers_before"].empty?
          reject! unless observation["owner_count_after"] == 0
          reject! unless observation["cleanup_finality"]
        else
          reject! if observation["account_delete_result"] == SUCCESS_RESULT
        end

        result = observation.merge(
          "schema_version" => "account-delete-observation-v1",
          "workload_id" => WORKLOAD_ID,
          "special_fee_minimum_drops" => observation["reserve_increment_drops"],
          "owner_reserve_before_drops" => observation["owner_count_before"] * observation["reserve_increment_drops"],
          "owner_reserve_after_drops" => observation["owner_count_after"] * observation["reserve_increment_drops"],
          "base_reserve_before_drops" => observation["base_reserve_drops"],
          "base_reserve_after_drops" => observation["base_reserve_drops"],
          "network_scope" => NETWORK_SCOPE,
          "counted_run" => false,
          "execution_authorized" => false
        )
        deep_freeze(result)
      rescue KeyError, TypeError
        reject!
      end

      private

      def reject!
        raise AccountDeleteLifecycleError, "invalid AccountDelete lifecycle observation"
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
