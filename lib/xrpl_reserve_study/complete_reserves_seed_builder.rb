# frozen_string_literal: true

require "digest"

module XrplReserveStudy
  class CompleteReservesSeedBuilderError < StudyError; end

  class CompleteReservesSeedBuilder
    SENSITIVE_MEASUREMENT_KEY = /secret|seed|private|signature|endpoint|host|user|path|url/i
    REQUIRED_LIMITS = %w[max_batch_size max_retries deadline_seconds].freeze

    def initialize(client:, recipe_registry: OwnerObjectRecipeRegistry.new,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @client = client
      @recipe_registry = recipe_registry
      @clock = clock
    end

    def build(cell:, workload:, secret_reader:)
      require_private_client!
      prepared = prepare!(cell, workload)
      started = monotonic_time
      before = measurement("before")
      authority = secret_reader.call
      raise CompleteReservesSeedBuilderError, "missing signing authority" unless mutable_text?(authority)

      pool = SignerPool.new(profile_id: prepared.fetch(:profile_id), cell_id: prepared.fetch(:cell_id),
                            authority_reader: -> { authority.dup }, wallet_propose_adapter: @client)
      records = []
      addresses, attempted = fund_accounts!(prepared, pool, authority, started, records)
      attempted += create_objects!(prepared, pool, addresses, started, records)
      finality = records.last.fetch("finality")
      counts = @client.ledger_counts(finality: finality)
      enforce_deadline!(prepared.fetch(:limits), started)
      verify_final_counts!(counts, prepared)
      after = measurement("after")
      enforce_deadline!(prepared.fetch(:limits), started)
      elapsed = monotonic_time - started
      enforce_deadline!(prepared.fetch(:limits), started)
      raise CompleteReservesSeedBuilderError, "complete reserves seed duration is invalid" unless finite_number?(elapsed) && elapsed >= 0

      result = {
        "schema_version" => "complete-reserves-seed-state-v2", "profile_id" => prepared.fetch(:profile_id),
        "cell_id" => prepared.fetch(:cell_id), "counted_run" => false, "elapsed_seconds" => elapsed,
        "attempted_transactions" => attempted, "validated_transactions" => records.length,
        "burned_fee_drops" => records.sum { |record| record.fetch("finality").fetch("fee_drops") },
        "locked_xrp_drops" => counts.fetch("locked_xrp_drops"), "released_xrp_drops" => counts.fetch("released_xrp_drops"),
        "finality" => { "validated" => records.length, "last_ledger_index" => finality.fetch("ledger_index"),
                         "last_ledger_hash" => finality.fetch("ledger_hash") },
        "classified_ledger_evidence" => counts.slice("ledger_index", "ledger_hash", "network_id", "classifier_version", "account_roots", "class_counts"),
        "resource_snapshots" => [before, after]
      }
      deep_freeze(result)
    rescue IsolatedTransactionClientError, SignerPoolError, OwnerObjectRecipeRegistryError => error
      raise CompleteReservesSeedBuilderError, error.message
    ensure
      wipe!(authority)
    end

    private

    def require_private_client!
      unless @client.is_a?(IsolatedTransactionClient) && @client.isolated?
        raise CompleteReservesSeedBuilderError, "isolated transaction client is required"
      end
    end

    def prepare!(cell, workload)
      raise CompleteReservesSeedBuilderError, "invalid complete reserves seed cell" unless cell.is_a?(Hash) && workload.is_a?(Hash)
      accounts, objects = workload.values_at("accounts", "objects")
      raise CompleteReservesSeedBuilderError, "invalid complete reserves workload" unless accounts.is_a?(Array) && objects.is_a?(Array)
      validate_accounts!(accounts)
      unless cell["account_root_target"] == accounts.length && cell["owned_object_target"] == objects.length
        raise CompleteReservesSeedBuilderError, "workload does not match complete reserves cell"
      end
      controllers = accounts.sort_by { |entry| entry.fetch("ordinal") }
      allocations, object_counts, normalized_objects = validate_objects!(objects, controllers)
      recipes = object_counts.keys.to_h do |kind|
        recipe = @recipe_registry.fetch(kind)
        raise CompleteReservesSeedBuilderError, "unsupported candidate owner object recipe" if recipe == :unsupported_candidate_feature
        [kind, recipe]
      end
      { profile_id: required_text!(cell["profile_id"]), cell_id: required_text!(cell["cell_id"] || cell["run_id"]),
        accounts: controllers, objects: normalized_objects, allocations: allocations, object_counts: object_counts, recipes: recipes,
        limits: limits!(cell), base_reserve_drops: drops!(cell, "base_reserve_drops", "base_reserve_xrp"),
        owner_reserve_drops: drops!(cell, "owner_reserve_drops", "owner_reserve_xrp"),
        fee_headroom_drops_per_step: positive_integer!(cell["fee_headroom_drops_per_step"], "positive fee headroom is required") }
    rescue KeyError, TypeError
      raise CompleteReservesSeedBuilderError, "invalid complete reserves workload"
    end

    def validate_accounts!(accounts)
      valid = accounts.all? { |entry| entry.is_a?(Hash) && entry["ordinal"].is_a?(Integer) && entry["ordinal"].positive? && required_text(entry["account_id"]) }
      raise CompleteReservesSeedBuilderError, "invalid complete reserves accounts" unless valid && accounts.map { |entry| entry["ordinal"] }.uniq.length == accounts.length && accounts.map { |entry| entry["account_id"] }.uniq.length == accounts.length
    end

    def validate_objects!(objects, controllers)
      ordinals = controllers.map { |entry| entry.fetch("ordinal") }
      allocations = Hash.new(0)
      counts = Hash.new(0)
      normalized = objects.map do |object|
        valid = object.is_a?(Hash) && object["ordinal"].is_a?(Integer) && object["ordinal"].positive? && required_text(object["object_type"]) && required_text(object["owner"])
        raise CompleteReservesSeedBuilderError, "invalid complete reserves owner object" unless valid
        controller = object["controller_ordinal"] || deterministic_controller(object.fetch("owner"), ordinals)
        raise CompleteReservesSeedBuilderError, "invalid complete reserves owner controller" unless ordinals.include?(controller)
        allocations[controller] += 1
        counts[object.fetch("object_type")] += 1
        object.merge("controller_ordinal" => controller).freeze
      end
      [allocations.freeze, counts.sort.to_h.freeze, normalized.freeze]
    end

    def deterministic_controller(owner, ordinals)
      ordinals.fetch(Digest::SHA256.hexdigest(owner)[0, 16].to_i(16) % ordinals.length)
    end

    def limits!(cell)
      value = cell["execution_limits"]
      valid = value.is_a?(Hash) && value.keys.sort == REQUIRED_LIMITS.sort && value["max_batch_size"].is_a?(Integer) && value["max_batch_size"].positive? &&
        value["max_retries"].is_a?(Integer) && value["max_retries"] >= 0 && finite_number?(value["deadline_seconds"]) && value["deadline_seconds"].positive?
      raise CompleteReservesSeedBuilderError, "approved complete reserves execution limits are required" unless valid
      value.freeze
    end

    def drops!(cell, drops_key, xrp_key)
      value = cell[drops_key] || (Float(cell.fetch(xrp_key)) * 1_000_000).round
      raise CompleteReservesSeedBuilderError, "invalid complete reserves reserve" unless value.is_a?(Integer) && value.positive?
      value
    rescue ArgumentError, TypeError, KeyError
      raise CompleteReservesSeedBuilderError, "invalid complete reserves reserve"
    end

    def positive_integer!(value, message)
      raise CompleteReservesSeedBuilderError, message unless value.is_a?(Integer) && value.positive?
      value
    end

    def fund_accounts!(prepared, pool, authority, started, records)
      addresses = {}
      attempted = 0
      prepared.fetch(:accounts).each_slice(prepared.fetch(:limits).fetch("max_batch_size")) do |batch|
        batch.each do |account|
          pool.with_signer(role: "account_root", ordinal: account.fetch("ordinal")) do |signer|
            addresses[account.fetch("ordinal")] = signer.account
            object_steps = prepared.fetch(:objects).select { |object| object.fetch("controller_ordinal") == account.fetch("ordinal") }.sum { |object| prepared.fetch(:recipes).fetch(object.fetch("object_type")).creation_steps.length }
            amount = prepared.fetch(:base_reserve_drops) + prepared.fetch(:allocations).fetch(account.fetch("ordinal"), 0) * prepared.fetch(:owner_reserve_drops) + object_steps * prepared.fetch(:fee_headroom_drops_per_step)
            finalized, used = finalize_submission(prepared.fetch(:limits), started) { @client.fund_account(account: signer.account, amount_drops: amount, root_secret: authority) }
            records.concat(finalized)
            attempted += used
          end
        end
      end
      [addresses, attempted]
    end

    def create_objects!(prepared, pool, addresses, started, records)
      attempted = 0
      prepared.fetch(:objects).each_slice(prepared.fetch(:limits).fetch("max_batch_size")) do |batch|
        batch.each do |object|
          recipe = prepared.fetch(:recipes).fetch(object.fetch("object_type"))
          recipe.required_amendments.each { |amendment| raise CompleteReservesSeedBuilderError, "required candidate amendment is not active" unless @client.amendment_active?(amendment: amendment) }
          pool.with_signer(role: "account_root", ordinal: object.fetch("controller_ordinal")) do |signer|
            raise CompleteReservesSeedBuilderError, "deterministic runtime signer changed" unless addresses.fetch(object.fetch("controller_ordinal")) == signer.account
            finalized, used = finalize_submission(prepared.fetch(:limits), started) { @client.submit_recipe(recipe: recipe, owner: signer.account, signer: signer) }
            unless finalized.all? { |record| record.fetch("finality").fetch("fee_drops") <= prepared.fetch(:fee_headroom_drops_per_step) }
              raise CompleteReservesSeedBuilderError, "observed recipe fee exceeds approved headroom"
            end
            records.concat(finalized)
            attempted += used
          end
        end
      end
      attempted
    end

    def finalize_submission(limits, started)
      submissions = 0
      result = begin
        begin
          enforce_deadline!(limits, started)
          submissions += 1
          yield
        rescue IsolatedTransactionClientError => error
          retry if submissions <= limits.fetch("max_retries") && before_deadline?(limits, started)
          raise error
        end
      end
      steps = result.key?("steps") ? result.fetch("steps") : [result]
      records = steps.map do |step|
        finality = poll_finality(step.fetch("hash"), limits, started)
        { "hash" => step.fetch("hash"), "finality" => finality }.freeze
      end
      [records, records.length + submissions - 1]
    end

    def poll_finality(hash, limits, started)
      polls = 0
      begin
        finality = @client.validated_transaction(hash: hash)
        enforce_deadline!(limits, started)
        finality
      rescue IsolatedTransactionClientError => error
        polls += 1
        retry if polls <= limits.fetch("max_retries") && before_deadline?(limits, started)
        raise error
      end
    end

    def verify_final_counts!(counts, prepared)
      valid = counts.is_a?(Hash) && counts["account_roots"] == prepared.fetch(:accounts).length && counts["class_counts"] == prepared.fetch(:object_counts) &&
        %w[locked_xrp_drops released_xrp_drops].all? { |key| counts[key].is_a?(Integer) && counts[key] >= 0 }
      raise CompleteReservesSeedBuilderError, "final ledger counts do not match workload" unless valid
    end

    def measurement(phase)
      { "phase" => phase, "metrics" => sanitize_measurement!(@client.resource_snapshot) }.freeze
    end

    def sanitize_measurement!(value)
      case value
      when Hash
        raise CompleteReservesSeedBuilderError, "resource snapshot is invalid" if value.empty? || !value.keys.all? { |key| key.is_a?(String) && !key.match?(SENSITIVE_MEASUREMENT_KEY) }
        value.keys.sort.to_h { |key| [key, sanitize_measurement!(value.fetch(key))] }.freeze
      when Array then value.map { |entry| sanitize_measurement!(entry) }.freeze
      when Integer then value
      when Float then raise CompleteReservesSeedBuilderError, "resource snapshot is invalid" unless value.finite?; value
      when TrueClass, FalseClass then value
      else raise CompleteReservesSeedBuilderError, "resource snapshot is invalid"
      end
    end

    def enforce_deadline!(limits, started); raise CompleteReservesSeedBuilderError, "complete reserves seed deadline exceeded" unless before_deadline?(limits, started); end
    def before_deadline?(limits, started); monotonic_time - started < limits.fetch("deadline_seconds"); end
    def monotonic_time; value = @clock.call; raise CompleteReservesSeedBuilderError, "complete reserves seed clock is invalid" unless finite_number?(value); value; end
    def finite_number?(value); value.is_a?(Integer) || (value.is_a?(Float) && value.finite?); end
    def required_text!(value); raise CompleteReservesSeedBuilderError, "invalid complete reserves seed cell" unless required_text(value); value; end
    def required_text(value); value.is_a?(String) && !value.empty? ? value : nil; end
    def mutable_text?(value); value.is_a?(String) && !value.empty? && !value.frozen?; end
    def wipe!(value); return unless value.is_a?(String) && !value.frozen?; value.bytesize.times { |index| value.setbyte(index, 0) }; value.clear; end
    def deep_freeze(value); (value.is_a?(Hash) ? value.each { |key, nested| deep_freeze(key); deep_freeze(nested) } : value.is_a?(Array) ? value.each { |entry| deep_freeze(entry) } : nil); value.freeze; end
  end
end
