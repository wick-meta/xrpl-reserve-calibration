# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CompleteReservesExecutorError < StudyError; end

  class CompleteReservesPlanner
    PROFILE_SELECTORS = %w[calibrated-v1 full-v1].freeze

    def initialize(profile_path: CompleteReservesProfile::PATH)
      @profile_path = profile_path
      @profile = CompleteReservesProfile.new(profile_path)
      @profile_sha256 = Digest::SHA256.file(profile_path).hexdigest
      @security = SecurityWorkload.new
    rescue SystemCallError, CompleteReservesProfileError, SecurityWorkloadError
      reject!
    end

    def preflight(profile:)
      validate_selector!(profile)
      full = profile == "full-v1"
      {
        "schema_version" => "complete-reserves-preflight-v1",
        "profile" => profile,
        "profile_id" => full ? CompleteReservesExecutor::FULL_PROFILE : CompleteReservesExecutor::CALIBRATED_PROFILE,
        "profile_sha256" => @profile_sha256,
        "security_config_sha256" => @security.security_config_sha256,
        "network_scope" => "isolated-network-only",
        "cell_count" => full ? 120 : 3,
        "timed_floor_seconds" => full ? ProvisioningBenchmark::TIMED_FLOOR_SECONDS : 6_300,
        "provisioning_time_status" => "unbounded",
        "executor_available" => !full,
        "counted_run" => false,
        "execution_authorized" => false
      }.freeze
    end

    def profile(profile:, input:)
      validate_selector!(profile)
      validate_keys!(input, %w[distribution])
      cells = if profile == "calibrated-v1"
                @profile.calibrated_cells(distribution: input.fetch("distribution"))
              else
                @profile.full_matrix_cells(distribution: input.fetch("distribution"))
              end
      {
        "schema_version" => "complete-reserves-profile-output-v1", "profile" => profile,
        "profile_sha256" => @profile_sha256, "cells" => cells,
        "network_scope" => "isolated-network-only", "counted_run" => false,
        "execution_authorized" => false
      }.freeze
    rescue KeyError
      reject!
    end

    def benchmark(profile:, input:)
      require_full!(profile)
      validate_keys!(input, %w[distribution distribution_sha256 candidate_sha256 samples one_million_checkpoint])
      full = @profile.full_matrix_cells(distribution: input.fetch("distribution"))
      ProvisioningBenchmark.new(
        distribution: input.fetch("distribution"), distribution_sha256: input.fetch("distribution_sha256"),
        candidate_sha256: input.fetch("candidate_sha256"), profile_path: @profile_path
      ).estimate_full(
        profile: full, samples: input.fetch("samples"),
        one_million_checkpoint: input.fetch("one_million_checkpoint")
      )
    rescue KeyError, ProvisioningBenchmarkError
      reject!
    end

    def plan(profile:, input:)
      require_full!(profile)
      validate_keys!(input, %w[distribution distribution_sha256 candidate_sha256 benchmark available_resources resume_records])
      full = @profile.full_matrix_cells(distribution: input.fetch("distribution"))
      ProfileScheduler.new(
        distribution: input.fetch("distribution"), distribution_sha256: input.fetch("distribution_sha256"),
        candidate_sha256: input.fetch("candidate_sha256"), profile_path: @profile_path
      ).schedule(
        profile: full, benchmark: input.fetch("benchmark"),
        available_resources: input.fetch("available_resources"), resume_records: input.fetch("resume_records")
      )
    rescue KeyError, ProfileSchedulerError
      reject!
    end

    private

    def validate_selector!(profile)
      reject! unless PROFILE_SELECTORS.include?(profile)
    end

    def require_full!(profile)
      validate_selector!(profile)
      reject! unless profile == "full-v1"
    end

    def validate_keys!(input, expected)
      reject! unless input.is_a?(Hash) && input.keys.sort == expected.sort
    end

    def reject!
      raise CompleteReservesExecutorError, "invalid complete reserves planning input"
    end
  end

  # Executes only a hash-bound, non-counted calibration item against an
  # injected isolated-network runtime. The full profile remains a planning
  # artifact until its separate authorization contract is changed.
  class CompleteReservesExecutor
    PROFILE_PATH = CompleteReservesProfile::PATH
    SHA256 = /\A[0-9a-f]{64}\z/
    ITEM_KEYS = %w[
      schema_version run_id repetition profile_id profile_sha256 schedule_sha256 schedule_item_sha256
      security_config_sha256 distribution_sha256 candidate_sha256 network_scope account_root_target
      owned_object_target base_reserve_drops owner_reserve_drops fee_headroom_drops_per_step
      warmup_seconds measurement_seconds execution_limits status counted_run execution_authorized
      snapshot_id study_sha256 config_sha256 source_sha256 ledger_index ledger_hash
    ].freeze
    LIMIT_KEYS = %w[max_batch_size max_retries deadline_seconds].freeze
    PRIVATE_IDENTITY_KEYS = %w[
      schema_version network_scope network_id transport candidate_sha256
      peer_certificate_sha256 client_certificate_sha256
    ].freeze
    PRIVATE_IDENTITY_SCHEMA = "complete-reserves-private-identity-v1"
    CALIBRATED_PROFILE = "complete-reserves-calibrated-v1"
    FULL_PROFILE = "complete-reserves-full-matrix-v1"

    def initialize(snapshot_provider:, clone_manager:, runtime:, artifacts:,
                   authorization: CompleteReservesAuthorization.new,
                   security: SecurityWorkload.new,
                   recipe_registry: OwnerObjectRecipeRegistry.new,
                   profile_path: PROFILE_PATH)
      @snapshot_provider = snapshot_provider
      @clone_manager = clone_manager
      @runtime = runtime
      @artifacts = artifacts
      @authorization = authorization
      @security = security
      @recipe_registry = recipe_registry
      @profile_sha256 = Digest::SHA256.file(profile_path).hexdigest
      validate_dependencies!
    rescue SystemCallError
      reject!("complete reserves profile is unavailable")
    end

    def run(item:, secret_reader:, resume_record: nil)
      prepared = validate_item!(item)
      identity = validate_private_identity!
      validate_security_contract!
      return resume!(prepared, resume_record) if resume_record

      snapshot = @snapshot_provider.call(prepared)
      validate_snapshot_bindings!(prepared, snapshot, identity)
      clone_run = clone_run(prepared, snapshot)
      clone = @clone_manager.prepare(snapshot: snapshot, run: clone_run)
      @clone_manager.start(clone: clone, run: clone_run)
      started = true

      @runtime.warmup(seconds: prepared.fetch("warmup_seconds"), item: prepared)
      authority = secret_reader.call
      reject!("missing signing authority") unless mutable_text?(authority)

      metrics = execute_security_workloads(prepared, authority)
      evaluations = evaluate_security!(metrics)
      reject!("complete reserves security gates failed") unless evaluations.all? { |entry| entry.fetch("passed") }

      recovery = validate_recovery!(@runtime.recover!(item: prepared, ledger: snapshot.fetch("ledger")), snapshot.fetch("ledger"))
      recovery_confirmed = true
      reset = validate_reset!(@runtime.reset!(item: prepared, ledger: snapshot.fetch("ledger")), snapshot.fetch("ledger"))
      reset_confirmed = true

      result = execution_result(prepared, snapshot, metrics, evaluations, recovery, reset)
      resume = resume_record_for(prepared, result)
      publication = @artifacts.publish_execution_bundle(
        result: result, metrics: metrics, security_evaluations: evaluations, resume_record: resume
      )
      validate_publication!(publication, prepared)
      deep_freeze(result.merge(
        "result_artifact_sha256" => publication.fetch("result_artifact_sha256"),
        "resume_record" => publication.fetch("resume_record")
      ))
    rescue CompleteReservesExecutorError
      raise
    rescue CompleteReservesAuthorizationError, CompleteReservesProfileError, SecurityWorkloadError,
           OwnerObjectRecipeRegistryError, RunCloneManagerError, CompleteReservesArtifactsError => error
      reject!(error.message)
    rescue KeyError, TypeError, ArgumentError, RuntimeError => error
      reject!("complete reserves execution failed: #{error.message}")
    ensure
      wipe!(authority)
      if started && !reset_confirmed
        begin
          attempted_reset = @runtime.reset!(item: prepared, ledger: snapshot.fetch("ledger"))
          validate_reset!(attempted_reset, snapshot.fetch("ledger"))
        rescue StandardError
          # Publication has not occurred. The primary failure remains the
          # disposition while the one-time clone is left unusable.
        end
      end
    end

    private

    def validate_dependencies!
      valid = @snapshot_provider.respond_to?(:call) &&
              %i[prepare start].all? { |method| @clone_manager.respond_to?(method) } &&
              %i[private_network_identity warmup run_security_workload recover! reset!].all? { |method| @runtime.respond_to?(method) } &&
              %i[publish_execution_bundle verify_execution_resume].all? { |method| @artifacts.respond_to?(method) } &&
              @authorization.respond_to?(:authorize!) && @security.instance_of?(SecurityWorkload) &&
              @recipe_registry.instance_of?(OwnerObjectRecipeRegistry)
      reject!("invalid complete reserves execution dependency") unless valid
    end

    def validate_item!(item)
      reject!("invalid complete reserves execution item") unless item.is_a?(Hash) && item.keys.sort == ITEM_KEYS.sort
      reject!("full profile remains disabled") if item["profile_id"] == FULL_PROFILE
      valid = item["schema_version"] == "complete-reserves-calibration-item-v1" &&
              item["profile_id"] == CALIBRATED_PROFILE && item["profile_sha256"] == @profile_sha256 &&
              item["network_scope"] == "isolated-network-only" && item["status"] == "pending" &&
              text?(item["run_id"], /\Acal-a[0-9]{9}-o[0-9]{9}-r[0-9]{2}\z/) &&
              item["repetition"].is_a?(Integer) && item["repetition"].positive? &&
              %w[schedule_sha256 distribution_sha256 candidate_sha256 study_sha256 config_sha256 source_sha256 ledger_hash].all? { |key| sha?(item[key]) } &&
              item["snapshot_id"].is_a?(String) && item["snapshot_id"].match?(/\A[a-z0-9-]+\z/) &&
              positive_integer?(item["ledger_index"]) &&
              item["security_config_sha256"] == @security.security_config_sha256 &&
              item["schedule_item_sha256"] == canonical_sha256(item.reject { |key, _| key == "schedule_item_sha256" }) &&
              %w[account_root_target owned_object_target base_reserve_drops owner_reserve_drops fee_headroom_drops_per_step warmup_seconds measurement_seconds].all? { |key| positive_integer?(item[key]) } &&
              valid_limits?(item["execution_limits"]) && boolean?(item["counted_run"]) && boolean?(item["execution_authorized"])
      reject!("invalid complete reserves execution item") unless valid

      if item.fetch("counted_run") || item.fetch("execution_authorized")
        @authorization.authorize!
        reject!("counted execution requires explicit authorization") unless item.fetch("counted_run") && item.fetch("execution_authorized")
      end
      deep_freeze(deep_copy(item))
    end

    def validate_private_identity!
      identity = @runtime.private_network_identity
      valid = identity.is_a?(Hash) && identity.keys.sort == PRIVATE_IDENTITY_KEYS.sort &&
              identity["schema_version"] == PRIVATE_IDENTITY_SCHEMA &&
              identity["network_scope"] == "isolated-network-only" &&
              identity["network_id"].is_a?(String) && identity["network_id"].match?(/\Acandidate-[a-z0-9-]+\z/) &&
              identity["transport"] == "https-mtls-loopback" &&
              %w[candidate_sha256 peer_certificate_sha256 client_certificate_sha256].all? { |key| sha?(identity[key]) }
      reject!("verified isolated private-network identity is required") unless valid
      deep_freeze(deep_copy(identity))
    end

    def validate_security_contract!
      contract = @security.contract
      workloads = contract.fetch("workloads")
      valid = contract.fetch("network_scope") == "isolated-network-only" &&
              contract.fetch("counted_run") == false && contract.fetch("execution_authorized") == false &&
              workloads.map { |entry| entry.fetch("workload_id") } == SecurityWorkload::WORKLOADS.map { |entry| entry.fetch("workload_id") } &&
              workloads.all? { |entry| positive_integer?(entry["transaction_ceiling"]) } &&
              contract.fetch("gates") == SecurityWorkload::GATES
      reject!("complete reserves security ceilings are missing") unless valid
    rescue KeyError
      reject!("complete reserves security ceilings are missing")
    end

    def validate_snapshot_bindings!(item, snapshot, identity)
      valid = snapshot.is_a?(Hash) && snapshot["schema_version"] == "verified-state-snapshot-v1" &&
              snapshot["distribution_sha256"] == item["distribution_sha256"] &&
              snapshot["candidate_image_digest"] == item["candidate_sha256"] &&
              snapshot["snapshot_id"] == item["snapshot_id"] && snapshot["study_sha256"] == item["study_sha256"] &&
              snapshot["config_sha256"] == item["config_sha256"] && snapshot["source_sha256"] == item["source_sha256"] &&
              identity["candidate_sha256"] == item["candidate_sha256"] &&
              snapshot["snapshot_id"].is_a?(String) && snapshot["snapshot_id"].match?(/\A[a-z0-9-]+\z/) &&
              %w[study_sha256 config_sha256 source_sha256].all? { |key| sha?(snapshot[key]) } &&
              valid_ledger?(snapshot["ledger"], identity.fetch("network_id")) &&
              snapshot.dig("ledger", "ledger_index") == item["ledger_index"] && snapshot.dig("ledger", "ledger_hash") == item["ledger_hash"] &&
              snapshot.dig("ledger", "account_roots") == item["account_root_target"] &&
              snapshot.dig("ledger", "class_counts").values.sum == item["owned_object_target"] &&
              (snapshot.dig("ledger", "class_counts").keys - @recipe_registry.all.map(&:kind)).empty?
      reject!("stale or unverified complete reserves snapshot") unless valid
    end

    def valid_ledger?(ledger, network_id)
      ledger.is_a?(Hash) && ledger.keys.sort == %w[account_roots class_counts ledger_hash ledger_index network_id].sort &&
        ledger["network_id"] == network_id && positive_integer?(ledger["ledger_index"]) && sha?(ledger["ledger_hash"]) &&
        positive_integer?(ledger["account_roots"]) && ledger["class_counts"].is_a?(Hash) && ledger["class_counts"].any? &&
        ledger["class_counts"].all? { |kind, count| kind.is_a?(String) && positive_integer?(count) }
    end

    def clone_run(item, snapshot)
      {
        "run_id" => item.fetch("run_id"), "repetition" => item.fetch("repetition"),
        "candidate_image_digest" => snapshot.fetch("candidate_image_digest"),
        "study_sha256" => snapshot.fetch("study_sha256"),
        "distribution_sha256" => snapshot.fetch("distribution_sha256"),
        "config_sha256" => snapshot.fetch("config_sha256"),
        "source_sha256" => snapshot.fetch("source_sha256"), "ledger" => snapshot.fetch("ledger")
      }.freeze
    end

    def execute_security_workloads(item, authority)
      recipes = @recipe_registry.all
      records = @security.contract.fetch("workloads").map do |declaration|
        workload_id = declaration.fetch("workload_id")
        selected = %w[object-burst mixed churn].include?(workload_id) ? recipes : [].freeze
        record = @runtime.run_security_workload(
          workload_id: workload_id, item: item, recipes: selected,
          transaction_ceiling: declaration.fetch("transaction_ceiling"),
          measurement_seconds: item.fetch("measurement_seconds"), authority: authority
        )
        validate_metric_binding!(record, item, workload_id)
      end
      deep_freeze(records)
    end

    def validate_metric_binding!(record, item, workload_id)
      valid = record.is_a?(Hash) && record["workload_id"] == workload_id &&
              %w[profile_id profile_sha256 distribution_sha256 candidate_sha256].all? { |key| record[key] == item[key] }
      reject!("unbound complete reserves metrics") unless valid
      deep_freeze(deep_copy(record))
    end

    def evaluate_security!(metrics)
      baseline = metrics.find { |record| record.fetch("workload_id") == "baseline" }
      reject!("complete reserves baseline metrics are missing") unless baseline
      deep_freeze(metrics.reject { |record| record.fetch("workload_id") == "baseline" }.map do |observed|
        @security.evaluate(baseline: baseline, observed: observed)
      end)
    end

    def validate_recovery!(value, ledger)
      valid = value.is_a?(Hash) && value.keys.sort == %w[confirmed ledger seconds] && value["confirmed"] == true &&
              finite_nonnegative?(value["seconds"]) && value["ledger"] == ledger
      reject!("complete reserves recovery was not verified") unless valid
      deep_freeze(deep_copy(value))
    end

    def validate_reset!(value, ledger)
      valid = value.is_a?(Hash) && value.keys.sort == %w[confirmed ledger] && value["confirmed"] == true && value["ledger"] == ledger
      reject!("complete reserves reset was not verified") unless valid
      deep_freeze(deep_copy(value))
    end

    def execution_result(item, snapshot, metrics, evaluations, recovery, reset)
      deep_freeze(
        "schema_version" => "complete-reserves-execution-result-v1", "run_id" => item.fetch("run_id"),
        "status" => "passed", "profile_id" => item.fetch("profile_id"),
        "profile_sha256" => item.fetch("profile_sha256"), "schedule_sha256" => item.fetch("schedule_sha256"),
        "schedule_item_sha256" => item.fetch("schedule_item_sha256"),
        "security_config_sha256" => item.fetch("security_config_sha256"),
        "distribution_sha256" => item.fetch("distribution_sha256"), "candidate_sha256" => item.fetch("candidate_sha256"),
        "snapshot_id" => snapshot.fetch("snapshot_id"), "ledger" => snapshot.fetch("ledger"),
        "workload_artifact_sha256" => metrics.to_h { |record| [record.fetch("workload_id"), record.fetch("artifact_sha256")] },
        "security_sha256" => evaluations.to_h { |record| [record.fetch("workload_id"), record.fetch("security_sha256")] },
        "recovery_seconds" => recovery.fetch("seconds"), "recovery_confirmed" => recovery.fetch("confirmed"),
        "reset_confirmed" => reset.fetch("confirmed"), "network_scope" => "isolated-network-only",
        "counted_run" => false, "execution_authorized" => false
      )
    end

    def resume_record_for(item, result)
      {
        "schema_version" => "complete-reserves-resume-v1", "run_id" => item.fetch("run_id"),
        "schedule_item_sha256" => item.fetch("schedule_item_sha256"),
        "reset_confirmed" => result.fetch("reset_confirmed"),
        "recovery_confirmed" => result.fetch("recovery_confirmed")
      }.freeze
    end

    def validate_publication!(publication, item)
      valid = publication.is_a?(Hash) && publication.keys.sort == %w[result_artifact_sha256 resume_record] &&
              sha?(publication["result_artifact_sha256"]) && publication["resume_record"].is_a?(Hash) &&
              publication["resume_record"]["run_id"] == item["run_id"] &&
              publication["resume_record"]["schedule_item_sha256"] == item["schedule_item_sha256"] &&
              publication["resume_record"]["result_artifact_sha256"] == publication["result_artifact_sha256"] &&
              publication["resume_record"]["reset_confirmed"] == true && publication["resume_record"]["recovery_confirmed"] == true
      reject!("complete reserves artifact publication is invalid") unless valid
    end

    def resume!(item, record)
      valid = record.is_a?(Hash) && record["schema_version"] == "complete-reserves-resume-v1" &&
              record["run_id"] == item["run_id"] && record["schedule_item_sha256"] == item["schedule_item_sha256"] &&
              sha?(record["result_artifact_sha256"]) && record["reset_confirmed"] == true && record["recovery_confirmed"] == true
      reject!("invalid complete reserves resume record") unless valid
      result = @artifacts.verify_execution_resume(record: record, item: item)
      reject!("invalid complete reserves resume artifact") unless result.is_a?(Hash) && result["run_id"] == item["run_id"] && result["counted_run"] == false
      deep_freeze(deep_copy(result))
    end

    def valid_limits?(limits)
      limits.is_a?(Hash) && limits.keys.sort == LIMIT_KEYS.sort &&
        positive_integer?(limits["max_batch_size"]) && limits["max_retries"].is_a?(Integer) && limits["max_retries"] >= 0 &&
        finite_positive?(limits["deadline_seconds"])
    end

    def canonical_sha256(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def sha?(value); value.is_a?(String) && value.match?(SHA256); end
    def text?(value, pattern); value.is_a?(String) && value.match?(pattern); end
    def positive_integer?(value); value.is_a?(Integer) && value.positive?; end
    def boolean?(value); value == true || value == false; end
    def finite_positive?(value); (value.is_a?(Integer) && value.positive?) || (value.is_a?(Float) && value.finite? && value.positive?); end
    def finite_nonnegative?(value); (value.is_a?(Integer) && value >= 0) || (value.is_a?(Float) && value.finite? && value >= 0); end
    def mutable_text?(value); value.is_a?(String) && !value.empty? && !value.frozen?; end

    def wipe!(value)
      return unless value.is_a?(String) && !value.frozen?
      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end

    def deep_copy(value); Marshal.load(Marshal.dump(value)); end
    def deep_freeze(value); (value.is_a?(Hash) ? value.each { |key, nested| deep_freeze(key); deep_freeze(nested) } : value.is_a?(Array) ? value.each { |nested| deep_freeze(nested) } : nil); value.freeze; end
    def reject!(message); raise CompleteReservesExecutorError, message; end
  end
end
