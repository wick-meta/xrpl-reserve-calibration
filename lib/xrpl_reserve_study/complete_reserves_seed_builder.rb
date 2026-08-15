# frozen_string_literal: true

module XrplReserveStudy
  class CompleteReservesSeedBuilderError < StudyError; end

  class CompleteReservesSeedBuilder
    DEFAULT_LIMITS = { "max_batch_size" => 100, "max_retries" => 0, "deadline_seconds" => 300 }.freeze
    SENSITIVE_MEASUREMENT_KEY = /secret|seed|private|signature|endpoint|host|user|path|url/i

    def initialize(client:, recipe_registry: OwnerObjectRecipeRegistry.new,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @client = client
      @recipe_registry = recipe_registry
      @clock = clock
    end

    def build(cell:, workload:, secret_reader:)
      prepared = prepare!(cell, workload)
      raise CompleteReservesSeedBuilderError, "isolated candidate network is required" unless @client.respond_to?(:isolated?) && @client.isolated?

      started = monotonic_time
      before = measurement("before")
      authority = secret_reader.call
      raise CompleteReservesSeedBuilderError, "missing signing authority" unless mutable_text?(authority)

      attempts = validated = fees = 0
      finalities = []
      addresses = {}
      pool = SignerPool.new(
        profile_id: prepared.fetch(:profile_id), cell_id: prepared.fetch(:cell_id),
        authority_reader: -> { authority.dup }, wallet_propose_adapter: @client
      )

      prepared.fetch(:accounts).each_slice(prepared.fetch(:limits).fetch("max_batch_size")) do |batch|
        batch.each do |account|
          pool.with_signer(role: "account_root", ordinal: account.fetch("ordinal")) do |signer|
            addresses[account.fetch("account_id")] = signer.account
            finality, used = submit_with_finality(prepared.fetch(:limits), started) do
              @client.fund_account(
                account: signer.account, amount_drops: prepared.fetch(:funding_drops), root_secret: authority
              )
            end
            attempts += used
            validated += 1
            fees += finality.fetch("fee_drops")
            finalities << finality
          end
        end
      end

      prepared.fetch(:objects).each_slice(prepared.fetch(:limits).fetch("max_batch_size")) do |batch|
        batch.each do |object|
          recipe = prepared.fetch(:recipes).fetch(object.fetch("object_type"))
          ensure_required_amendments!(recipe)
          owner_ordinal = prepared.fetch(:owner_ordinals).fetch(object.fetch("owner"))
          pool.with_signer(role: "account_root", ordinal: owner_ordinal) do |signer|
            unless addresses.fetch(object.fetch("owner")) == signer.account
              raise CompleteReservesSeedBuilderError, "deterministic runtime signer changed"
            end
            finality, used = submit_with_finality(prepared.fetch(:limits), started) do
              @client.submit_recipe(recipe: recipe, owner: signer.account, signer: signer)
            end
            attempts += used
            validated += 1
            fees += finality.fetch("fee_drops")
            finalities << finality
          end
        end
      end

      final_counts = @client.ledger_counts
      verify_final_counts!(final_counts, prepared)
      after = measurement("after")
      result = {
        "schema_version" => "complete-reserves-seed-state-v1",
        "profile_id" => prepared.fetch(:profile_id), "cell_id" => prepared.fetch(:cell_id), "counted_run" => false,
        "validated_account_roots" => prepared.fetch(:accounts).length,
        "validated_owner_objects" => prepared.fetch(:object_counts),
        "attempted_transactions" => attempts, "validated_transactions" => validated,
        "burned_fee_drops" => fees, "locked_xrp_drops" => final_counts.fetch("locked_xrp_drops"),
        "released_xrp_drops" => final_counts.fetch("released_xrp_drops"),
        "finality" => { "validated" => finalities.length, "last_ledger_index" => finalities.last.fetch("ledger_index") },
        "resource_snapshots" => [before, after]
      }
      deep_freeze(result)
    rescue IsolatedTransactionClientError, SignerPoolError, OwnerObjectRecipeRegistryError => error
      raise CompleteReservesSeedBuilderError, error.message
    ensure
      wipe!(authority)
    end

    private

    def prepare!(cell, workload)
      raise CompleteReservesSeedBuilderError, "invalid complete reserves seed cell" unless cell.is_a?(Hash) && workload.is_a?(Hash)
      profile_id = required_text(cell["profile_id"])
      cell_id = required_text(cell["cell_id"] || cell["run_id"])
      accounts = workload["accounts"]
      objects = workload["objects"]
      raise CompleteReservesSeedBuilderError, "invalid complete reserves workload" unless accounts.is_a?(Array) && objects.is_a?(Array)
      validate_targets!(cell, accounts, objects)
      validate_accounts!(accounts)
      owner_ordinals = accounts.to_h { |account| [account.fetch("account_id"), account.fetch("ordinal")] }
      object_counts = validate_objects!(objects, owner_ordinals)
      recipes = object_counts.keys.to_h do |kind|
        recipe = @recipe_registry.fetch(kind)
        raise CompleteReservesSeedBuilderError, "unsupported candidate owner object recipe" if recipe == :unsupported_candidate_feature
        [kind, recipe]
      end
      {
        profile_id: profile_id, cell_id: cell_id, accounts: accounts, objects: objects, owner_ordinals: owner_ordinals,
        object_counts: object_counts, recipes: recipes, limits: limits!(cell, workload), funding_drops: funding_drops!(cell)
      }
    rescue KeyError, TypeError
      raise CompleteReservesSeedBuilderError, "invalid complete reserves workload"
    end

    def validate_targets!(cell, accounts, objects)
      unless cell["account_root_target"] == accounts.length && cell["owned_object_target"] == objects.length
        raise CompleteReservesSeedBuilderError, "workload does not match complete reserves cell"
      end
    end

    def validate_accounts!(accounts)
      valid = accounts.all? do |account|
        account.is_a?(Hash) && account["ordinal"].is_a?(Integer) && account["ordinal"].positive? &&
          required_text(account["account_id"])
      end
      identifiers = accounts.map { |account| account["account_id"] }
      ordinals = accounts.map { |account| account["ordinal"] }
      unless valid && identifiers.uniq.length == identifiers.length && ordinals.uniq.length == ordinals.length
        raise CompleteReservesSeedBuilderError, "invalid complete reserves accounts"
      end
    end

    def validate_objects!(objects, owner_ordinals)
      counts = Hash.new(0)
      objects.each do |object|
        unless object.is_a?(Hash) && object["ordinal"].is_a?(Integer) && object["ordinal"].positive? &&
               required_text(object["object_type"]) && owner_ordinals.key?(object["owner"])
          raise CompleteReservesSeedBuilderError, "invalid complete reserves owner object"
        end
        counts[object.fetch("object_type")] += 1
      end
      counts.sort.to_h.freeze
    end

    def limits!(cell, workload)
      source = cell["execution_limits"] || workload["execution_limits"] || DEFAULT_LIMITS
      raise CompleteReservesSeedBuilderError, "invalid complete reserves execution limits" unless source.is_a?(Hash)
      value = DEFAULT_LIMITS.merge(source)
      valid = value.keys.sort == DEFAULT_LIMITS.keys.sort && value["max_batch_size"].is_a?(Integer) && value["max_batch_size"].positive? &&
        value["max_retries"].is_a?(Integer) && value["max_retries"] >= 0 && value["deadline_seconds"].is_a?(Numeric) && value["deadline_seconds"].positive?
      raise CompleteReservesSeedBuilderError, "invalid complete reserves execution limits" unless valid

      value.freeze
    end

    def funding_drops!(cell)
      value = cell["base_reserve_drops"] || (Float(cell.fetch("base_reserve_xrp")) * 1_000_000).round
      raise CompleteReservesSeedBuilderError, "invalid account funding reserve" unless value.is_a?(Integer) && value.positive?

      value
    rescue ArgumentError, TypeError, KeyError
      raise CompleteReservesSeedBuilderError, "invalid account funding reserve"
    end

    def ensure_required_amendments!(recipe)
      recipe.required_amendments.each do |amendment|
        raise CompleteReservesSeedBuilderError, "required candidate amendment is not active" unless @client.amendment_active?(amendment: amendment)
      end
    end

    def submit_with_finality(limits, started)
      attempts = 0
      begin
        enforce_deadline!(limits, started)
        submitted = yield
        attempts += 1
        return [@client.validated_transaction(hash: submitted.fetch("hash")), attempts]
      rescue IsolatedTransactionClientError => error
        retry if attempts <= limits.fetch("max_retries") && before_deadline?(limits, started)
        raise error
      end
    end

    def verify_final_counts!(counts, prepared)
      valid = counts.is_a?(Hash) && counts["account_roots"] == prepared.fetch(:accounts).length &&
        normalized_object_counts(counts["owner_objects"]) == prepared.fetch(:object_counts) &&
        %w[locked_xrp_drops released_xrp_drops].all? { |key| counts[key].is_a?(Integer) && counts[key] >= 0 }
      raise CompleteReservesSeedBuilderError, "final ledger counts do not match workload" unless valid
    end

    def normalized_object_counts(value)
      return nil unless value.is_a?(Hash) && value.all? { |key, count| key.is_a?(String) && count.is_a?(Integer) && count >= 0 }

      value.reject { |_, count| count.zero? }.sort.to_h
    end

    def measurement(phase)
      snapshot = sanitize_measurement!(@client.resource_snapshot)
      { "phase" => phase, "metrics" => snapshot }.freeze
    end

    def sanitize_measurement!(value)
      case value
      when Hash
        raise CompleteReservesSeedBuilderError, "resource snapshot is invalid" if value.empty?
        raise CompleteReservesSeedBuilderError, "resource snapshot contains sensitive metadata" unless value.keys.all? { |key| key.is_a?(String) && !key.match?(SENSITIVE_MEASUREMENT_KEY) }
        value.keys.sort.to_h { |key| [key, sanitize_measurement!(value.fetch(key))] }.freeze
      when Array
        value.map { |entry| sanitize_measurement!(entry) }.freeze
      when Numeric, TrueClass, FalseClass
        value
      else
        raise CompleteReservesSeedBuilderError, "resource snapshot is invalid"
      end
    end

    def enforce_deadline!(limits, started)
      raise CompleteReservesSeedBuilderError, "complete reserves seed deadline exceeded" unless before_deadline?(limits, started)
    end

    def before_deadline?(limits, started)
      monotonic_time - started < limits.fetch("deadline_seconds")
    end

    def monotonic_time
      value = @clock.call
      raise CompleteReservesSeedBuilderError, "complete reserves seed clock is invalid" unless value.is_a?(Numeric)

      value
    end

    def required_text(value)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    def mutable_text?(value)
      value.is_a?(String) && !value.empty? && !value.frozen?
    end

    def wipe!(value)
      return unless value.is_a?(String) && !value.frozen?

      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end
  end
end
