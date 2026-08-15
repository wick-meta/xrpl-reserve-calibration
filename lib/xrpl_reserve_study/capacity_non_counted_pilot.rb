# frozen_string_literal: true

require "digest"
require "json"
require "time"

module XrplReserveStudy
  class CapacityNonCountedPilotError < StudyError
    attr_reader :code, :progress

    def initialize(code, progress = {})
      @code = code
      @progress = progress
      super("capacity non-counted pilot failed (#{code})")
    end
  end

  class CapacityNonCountedPilot
    RUN_ID = "r0500000-a000010000-n01"
    PILOT_ACCOUNTS = 3
    VERIFY_ATTEMPTS = 3
    VERIFY_RETRY_SECONDS = 1
    OUTPUT_FILES = %w[
      pilot-result.json transactions.jsonl samples.jsonl metrics-summary.json SHA256SUMS
    ].freeze
    CHECKSUM_FILES = OUTPUT_FILES.first(4).freeze
    EMPTY_PROGRESS = {
      "sample_count" => 0, "validated_transaction_count" => 0,
      "completed_record_count" => 0, "post_warmup_sample" => nil,
      "measurement_samples" => [], "transaction_records" => []
    }.freeze

    def initialize(input_loader: nil, harness_runner: CapacityFunctionalSmoke::HarnessRunner.new,
                   sampler_factory: nil, reducer: CapacityMetrics::Reducer.new,
                   artifact_validator: nil, publisher: nil,
                   sleeper: ->(seconds) { sleep(seconds) },
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @input_loader = input_loader || InputLoader.new
      @harness_runner = harness_runner
      @sampler_factory = sampler_factory || SamplerFactory.new
      @reducer = reducer
      @artifact_validator = artifact_validator || ArtifactValidator.new
      @publisher = publisher || RuntimePublisher.new(
        error_class: CapacityNonCountedPilotError,
        failure_label: "non-counted pilot artifacts"
      )
      @sleeper = sleeper
      @monotonic_clock = monotonic_clock
    end

    def run(run_id:, config_dir:, workload_dir:, manifest_dir:, output_dir:, secret_reader:)
      validate_output_dir!(run_id, output_dir)
      snapshot = @input_loader.load(
        run_id: run_id, config_dir: config_dir, workload_dir: workload_dir,
        manifest_dir: manifest_dir
      )
      sampler = @sampler_factory.call(snapshot)
      start_attempted = false
      reset_confirmed = false
      authority = nil
      sampling = recovery = summary = nil
      operation_error = nil
      stage = "candidate-start"

      begin
        start_attempted = true
        @harness_runner.call("up-candidate", run_id)
        stage = "candidate-verify"
        verify_candidate(run_id)
        stage = "input-revalidate"
        @input_loader.revalidate(snapshot)
        stage = "sampling"
        authority = secret_reader.call
        sampling = sampler.run(authority: authority)
        terminal_code = sampling_terminal_code(sampling)
        reject!(terminal_code, progress_from(sampling)) if terminal_code

        final_sample = sampling.fetch("measurement_samples").last
        expected_ledger = deep_freeze(
          "validated_ledger_index" => final_sample.fetch("validated_ledger_index"),
          "validated_ledger_hash" => final_sample.fetch("validated_ledger_hash").dup
        )
        restart_started = monotonic_time
        stage = "restart-candidate"
        @harness_runner.call("restart-candidate", run_id)
        stage = "recovery"
        begin
          recovery = sampler.recover(
            restart_started_monotonic: restart_started, expected_ledger: expected_ledger
          )
        rescue CapacityPilotSamplerError => error
          reject!(sampler_error_code(error.code), progress_with_stage(sampling, stage, error.code))
        rescue Interrupt
          reject!("interrupted", progress_with_stage(sampling, stage))
        rescue Exception
          reject!("runtime-error", progress_with_stage(sampling, stage))
        end
        stage = "metrics-reduction"
        summary = @reducer.summarize(
          post_warmup: sampling.fetch("post_warmup_sample"),
          measurement_samples: sampling.fetch("measurement_samples"),
          attempted_transactions: PILOT_ACCOUNTS,
          validated_successes: sampling.fetch("validated_transaction_count"),
          restart_started_seconds: restart_started,
          tracking_resumed_seconds: restart_started + recovery.fetch("recovery_seconds")
        )
      rescue CapacityNonCountedPilotError => error
        operation_error = error
      rescue CapacityPilotSamplerError => error
        operation_error = controlled_error(
          sampler_error_code(error.code), progress_with_stage(error.progress, stage, error.code)
        )
      rescue Interrupt
        operation_error = controlled_error("interrupted", progress_with_stage(sampling, stage))
      rescue Exception
        operation_error = controlled_error("runtime-error", progress_with_stage(sampling, stage))
      ensure
        erase_string!(authority)
        if start_attempted
          begin
            @harness_runner.call("reset", run_id)
            reset_confirmed = true
          rescue Exception
            operation_error = controlled_error("reset-failure", progress_from(sampling))
          end
        end
      end

      raise operation_error if operation_error
      reject!("reset-failure", progress_from(sampling)) unless reset_confirmed
      begin
        @input_loader.revalidate(snapshot)
      rescue Exception
        reject!("binding-failure", progress_from(sampling))
      end

      artifacts = build_artifacts(snapshot, sampling, recovery, summary)
      begin
        @artifact_validator.validate_artifacts!(
          snapshot: snapshot, sampling: sampling, recovery: recovery,
          summary: summary, result: artifacts.fetch("result"),
          bytes: artifacts.fetch("bytes")
        )
      rescue Exception
        reject!("validation-failure", progress_from(sampling))
      end
      begin
        publish(output_dir, artifacts.fetch("bytes"))
      rescue Exception
        reject!("publication-failure", progress_from(sampling))
      end
      deep_freeze(deep_copy(artifacts.fetch("result")))
    rescue CapacityNonCountedPilotError
      raise
    rescue Exception
      reject!("input-failure", EMPTY_PROGRESS)
    ensure
      erase_string!(authority)
    end

    private

    def validate_output_dir!(run_id, output_dir)
      expected = File.join(
        RuntimePublisher::RUNTIME_ROOT, RUN_ID, "execution", "non-counted-pilot-000000003"
      )
      valid = run_id.instance_of?(String) && run_id.eql?(RUN_ID) &&
        output_dir.instance_of?(String) && File.expand_path(output_dir).eql?(expected) &&
        !File.exist?(expected) && !File.symlink?(expected)
      reject!("input-failure", EMPTY_PROGRESS) unless valid
    rescue CapacityNonCountedPilotError
      raise
    rescue Exception
      reject!("input-failure", EMPTY_PROGRESS)
    end

    def verify_candidate(run_id)
      VERIFY_ATTEMPTS.times do |attempt|
        begin
          @harness_runner.call("verify-candidate", run_id)
          return
        rescue Interrupt
          raise
        rescue Exception
          raise if attempt == VERIFY_ATTEMPTS - 1
          @sleeper.call(VERIFY_RETRY_SECONDS)
        end
      end
    end

    def sampling_terminal_code(sampling)
      status = sampling.fetch("status")
      return nil if status.eql?("completed")

      case status
      when "abort-rule-breach" then "abort-rule-breach"
      when "interrupted" then "interrupted"
      when "runtime-error" then "runtime-error"
      when "incomplete" then "incomplete"
      else "runtime-error"
      end
    rescue KeyError, NoMethodError, TypeError
      "runtime-error"
    end

    def sampler_error_code(code)
      case code
      when "abort-rule-breach" then "abort-rule-breach"
      when "interrupted" then "interrupted"
      when "incomplete", "incomplete-sampling" then "incomplete"
      else "runtime-error"
      end
    end

    def build_artifacts(snapshot, sampling, recovery, summary)
      transactions = jsonl(sampling.fetch("transaction_records"))
      samples = jsonl([sampling.fetch("post_warmup_sample")] + sampling.fetch("measurement_samples"))
      metrics_summary = "#{JSON.pretty_generate(summary)}\n"
      hashes = {
        "transactions.jsonl" => Digest::SHA256.hexdigest(transactions),
        "samples.jsonl" => Digest::SHA256.hexdigest(samples),
        "metrics-summary.json" => Digest::SHA256.hexdigest(metrics_summary)
      }
      thresholds_passed = summary.fetch("thresholds_passed").equal?(true)
      result = {
        "schema_version" => "capacity-pilot-result-v1",
        "pilot_scope" => "non-counted-pilot",
        "candidate_specific" => true,
        "status" => thresholds_passed ? "passed" : "failed",
        "disposition_code" => thresholds_passed ? "success" : "threshold-failure",
        "pilot_complete" => thresholds_passed,
        "counted_execution_authorized" => false,
        "native_execution_established" => false,
        "source_commit" => snapshot.fetch("source_commit"),
        "run_id" => RUN_ID,
        "protocol_sha256" => snapshot.fetch("protocol_sha256"),
        "manifest_sha256" => snapshot.fetch("manifest_sha256"),
        "transactions_sha256" => hashes.fetch("transactions.jsonl"),
        "samples_sha256" => hashes.fetch("samples.jsonl"),
        "metrics_summary_sha256" => hashes.fetch("metrics-summary.json"),
        "sample_count" => sampling.fetch("sample_count"),
        "transaction_count" => sampling.fetch("validated_transaction_count"),
        "thresholds_passed" => thresholds_passed,
        "abort_rule_breached" => false,
        "controlled_restart_recovered" => recovery.fetch("recovered").equal?(true),
        "reset_confirmed" => true,
        "bindings_validated" => true
      }
      pilot_result = "#{JSON.pretty_generate(result)}\n"
      bytes = {
        "pilot-result.json" => pilot_result,
        "transactions.jsonl" => transactions,
        "samples.jsonl" => samples,
        "metrics-summary.json" => metrics_summary
      }
      sums = CHECKSUM_FILES.map do |name|
        "#{Digest::SHA256.hexdigest(bytes.fetch(name))}  #{name}\n"
      end.join
      bytes["SHA256SUMS"] = sums
      { "result" => result, "bytes" => bytes }
    rescue JSON::GeneratorError, KeyError, TypeError
      reject!("validation-failure", progress_from(sampling))
    end

    def publish(output_dir, bytes)
      @publisher.publish(output_dir) do |staging|
        OUTPUT_FILES.each { |name| staging.write(name, bytes.fetch(name)) }
        CHECKSUM_FILES.each do |name|
          reject!("publication-failure", EMPTY_PROGRESS) unless
            staging.sha256(name) == Digest::SHA256.hexdigest(bytes.fetch(name))
        end
        true
      end
    end

    def jsonl(records)
      records.map { |record| "#{JSON.generate(record)}\n" }.join
    end

    def progress_from(sampling)
      return EMPTY_PROGRESS unless sampling.is_a?(Hash)
      deep_freeze(
        "sample_count" => sampling.fetch("sample_count", 0),
        "validated_transaction_count" => sampling.fetch("validated_transaction_count", 0),
        "completed_record_count" => sampling.fetch("completed_record_count", 0),
        "post_warmup_sample" => deep_copy(sampling["post_warmup_sample"]),
        "measurement_samples" => deep_copy(sampling.fetch("measurement_samples", [])),
        "transaction_records" => deep_copy(sampling.fetch("transaction_records", []))
      )
    rescue StandardError
      EMPTY_PROGRESS
    end

    def progress_with_stage(progress, stage, sampling_code = nil)
      allowed = %w[
        advance-deadline-missed aggregate-size-limit incomplete-sampling interrupted
        invalid-advance-target invalid-cancellation-signal invalid-deadline invalid-ledger-advancement
        invalid-metric-sample invalid-recovery-start invalid-sampler-configuration
        invalid-transaction-execution-record invalid-validated-ledger ledger-advancement-runtime-error
        metric-sample-size-limit recovery-runtime-error recovery-timeout sample-ledger-binding-mismatch
        sampling-runtime-error
      ]
      stages = %w[
        candidate-start candidate-verify input-revalidate sampling restart-candidate recovery metrics-reduction
      ]
      base = deep_copy(progress_from(progress))
      base["pilot_failure_stage"] = stage.dup if stage.instance_of?(String) && stages.include?(stage)
      if sampling_code.instance_of?(String) && allowed.include?(sampling_code)
        base["sampling_error_code"] = sampling_code.dup
      end
      mismatches = progress["sample_progression_mismatches"] if progress.is_a?(Hash)
      allowed_mismatches = %w[ledger-index ledger-hash elapsed cpu ledger-state database]
      if mismatches.instance_of?(Array) && mismatches.all? { |value| value.instance_of?(String) && allowed_mismatches.include?(value) }
        base["sample_progression_mismatches"] = mismatches.dup
      end

      deep_freeze(base)
    rescue StandardError
      EMPTY_PROGRESS
    end

    def controlled_error(code, progress)
      CapacityNonCountedPilotError.new(code, deep_freeze(deep_copy(progress || EMPTY_PROGRESS)))
    rescue StandardError
      CapacityNonCountedPilotError.new(code, EMPTY_PROGRESS)
    end

    def reject!(code, progress)
      raise controlled_error(code, progress)
    end

    def monotonic_time
      value = @monotonic_clock.call
      raise TypeError unless (value.instance_of?(Integer) || value.instance_of?(Float)) && value.finite? && value >= 0
      value
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

    class ClosedSchemaValidator
      def valid?(schema, value, root = schema)
        schema = resolve(root, schema.fetch("$ref")) if schema.key?("$ref")
        return false if schema["allOf"] && !schema.fetch("allOf").all? { |entry| valid?(entry, value, root) }
        return false if schema["oneOf"] && schema.fetch("oneOf").count { |entry| valid?(entry, value, root) } != 1
        return false if schema.key?("const") && !exact_equal?(value, schema.fetch("const"))
        return false if schema.key?("enum") && !schema.fetch("enum").any? { |entry| exact_equal?(value, entry) }
        return false unless valid_type?(schema["type"], value)
        return false if value.is_a?(Numeric) && schema.key?("minimum") && value < schema.fetch("minimum")
        return false if value.is_a?(Numeric) && schema.key?("maximum") && value > schema.fetch("maximum")
        return false if value.is_a?(Numeric) && schema.key?("exclusiveMinimum") && value <= schema.fetch("exclusiveMinimum")
        if value.instance_of?(String)
          return false if schema["pattern"] && !pattern?(schema.fetch("pattern"), value)
          return false if schema["format"] == "date-time" && !date_time?(value)
        end
        if value.instance_of?(Hash)
          return false unless value.keys.all? { |key| key.instance_of?(String) }
          required = schema.fetch("required", [])
          return false unless (required - value.keys).empty?
          properties = schema.fetch("properties", {})
          return false if schema["additionalProperties"] == false && !(value.keys - properties.keys).empty?
          return false unless value.all? do |key, nested|
            !properties.key?(key) || valid?(properties.fetch(key), nested, root)
          end
        end
        if value.instance_of?(Array)
          return false if schema["items"] && !value.all? { |nested| valid?(schema.fetch("items"), nested, root) }
          return false if schema["uniqueItems"] && value.uniq.length != value.length
        end
        true
      rescue ArgumentError, KeyError, TypeError, RegexpError
        false
      end

      private

      def resolve(root, reference)
        reference.delete_prefix("#/").split("/").reduce(root) { |value, key| value.fetch(key) }
      end

      def valid_type?(type, value)
        return true unless type
        case type
        when "object" then value.instance_of?(Hash)
        when "array" then value.instance_of?(Array)
        when "string" then value.instance_of?(String)
        when "integer" then value.instance_of?(Integer)
        when "number" then (value.instance_of?(Integer) || value.instance_of?(Float)) && value.finite?
        when "boolean" then value.equal?(true) || value.equal?(false)
        else false
        end
      rescue NoMethodError
        false
      end

      def pattern?(pattern, value)
        source = pattern.start_with?("^") ? "\\A#{pattern.delete_prefix('^')}" : pattern
        Regexp.new(source).match?(value)
      end

      def date_time?(value)
        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end

      def exact_equal?(actual, expected)
        return false unless actual.instance_of?(expected.class)
        case expected
        when Hash
          actual.keys == expected.keys && expected.all? { |key, nested| exact_equal?(actual.fetch(key), nested) }
        when Array
          actual.length == expected.length && expected.each_index.all? do |index|
            exact_equal?(actual.fetch(index), expected.fetch(index))
          end
        else
          actual.eql?(expected)
        end
      end
    end

    class InputLoader
      class InputError < StudyError; end
      class DuplicateRejectingHash < Hash
        def []=(key, value)
          raise JSON::ParserError, "duplicate JSON key" if key?(key)
          super
        end
      end
      private_constant :InputError, :DuplicateRejectingHash

      MANIFEST_FILES = %w[SHA256SUMS run-manifest.json].freeze
      SCHEMA_PATHS = %w[
        schemas/capacity-run-manifest-v1.schema.json
        schemas/capacity-pilot-execution-v1.schema.json
        schemas/capacity-pilot-result-v1.schema.json
        schemas/capacity-metric-sample-v1.schema.json
        schemas/capacity-metrics-summary-v1.schema.json
      ].freeze

      def initialize(source_control: CapacityRunManifest::SourceControl.new,
                     environment_probe: CapacityEnvironmentProbe.new,
                     schema_validator: ClosedSchemaValidator.new)
        @source_control = source_control
        @environment_probe = environment_probe
        @schema_validator = schema_validator
      end

      def load(run_id:, config_dir:, workload_dir:, manifest_dir:)
        validate_fixed_paths!(run_id, config_dir, workload_dir, manifest_dir)
        source_commit = @source_control.clean_head
        source_paths = (CapacityRunManifest::SOURCE_PATHS + SCHEMA_PATHS).uniq
        source_blobs = source_paths.to_h do |path|
          bytes = @source_control.tracked_blob(commit: source_commit, path: path)
          reject! unless bytes.instance_of?(String) && bytes.bytesize <= LockedCapacityInputs::MAX_INPUT_BYTES
          [path, bytes.dup.freeze]
        end
        locked_sources = CapacityRunManifest::INPUT_SOURCE_PATHS.to_h do |path|
          [path, source_blobs.fetch(path)]
        end
        locked = LockedCapacityInputs.new(error_class: InputError, sources: locked_sources)
        run_inputs = CapacityRunInputs.new(locked_inputs: locked).load(
          run_id: run_id, config_dir: config_dir, workload_dir: workload_dir,
          expected_pilot_accounts: PILOT_ACCOUNTS
        )
        intents = []
        bundle = CapacityWorkloadBundle.new(error_class: InputError, locked_inputs: locked)
        bundle.load(
          run: run_inputs.fetch("run"), workload_dir: workload_dir,
          expected_generation_scope: "pilot", expected_record_count: PILOT_ACCOUNTS
        ) { |record| intents << deep_copy(record) }
        manifest_files = bundle.read_exact_directory(
          path: manifest_dir, expected_names: MANIFEST_FILES, label: "pilot manifest"
        )
        manifest_sha256 = validate_manifest_checksum!(manifest_files)
        manifest = parse_canonical_object!(manifest_files.fetch("run-manifest.json"))
        schemas = SCHEMA_PATHS.to_h do |path|
          [File.basename(path), parse_object!(source_blobs.fetch(path))]
        end
        reject! unless @schema_validator.valid?(
          schemas.fetch("capacity-run-manifest-v1.schema.json"), manifest
        )
        environment = @environment_probe.capture
        validate_bindings!(
          manifest, source_commit, source_blobs, locked, run_inputs, environment,
          manifest_sha256
        )
        reject! unless @source_control.clean_head == source_commit
        pilot_bundle = deep_freeze(
          "run" => deep_copy(run_inputs.fetch("run")), "intents" => intents
        )
        fingerprint = fingerprint(
          source_commit, source_blobs, manifest_sha256, environment, run_inputs, pilot_bundle
        )
        deep_freeze(
          "source_commit" => source_commit.dup,
          "manifest_sha256" => manifest_sha256,
          "protocol_sha256" => locked.input_sha256.fetch("capacity/pilot-protocol-v1.yml"),
          "binding_fingerprint" => fingerprint,
          "pilot_bundle" => pilot_bundle,
          "manifest" => manifest,
          "schemas" => schemas,
          "paths" => {
            "config_dir" => File.expand_path(config_dir),
            "workload_dir" => File.expand_path(workload_dir),
            "manifest_dir" => File.expand_path(manifest_dir)
          }
        )
      rescue CapacityNonCountedPilotError
        raise
      rescue Exception
        raise CapacityNonCountedPilotError.new("input-failure", EMPTY_PROGRESS)
      end

      def revalidate(snapshot)
        reject! unless snapshot.instance_of?(Hash) && snapshot.frozen?
        paths = snapshot.fetch("paths")
        current = load(
          run_id: RUN_ID, config_dir: paths.fetch("config_dir"),
          workload_dir: paths.fetch("workload_dir"), manifest_dir: paths.fetch("manifest_dir")
        )
        reject! unless secure_equal?(
          current.fetch("binding_fingerprint"), snapshot.fetch("binding_fingerprint")
        )
        true
      rescue CapacityNonCountedPilotError
        raise
      rescue Exception
        raise CapacityNonCountedPilotError.new("input-failure", EMPTY_PROGRESS)
      end

      private

      def validate_fixed_paths!(run_id, config_dir, workload_dir, manifest_dir)
        reject! unless run_id.instance_of?(String) && run_id.eql?(RUN_ID)
        runtime = File.join(RuntimePublisher::RUNTIME_ROOT, RUN_ID)
        expected = {
          config_dir => File.join(runtime, "config"),
          workload_dir => File.join(runtime, "workload", "pilot-000000003"),
          manifest_dir => File.join(runtime, "manifests", "non-counted-pilot-000000003")
        }
        reject! unless expected.all? do |actual, fixed|
          actual.instance_of?(String) && File.expand_path(actual).eql?(File.expand_path(fixed))
        end
      end

      def validate_manifest_checksum!(files)
        line = files.fetch("SHA256SUMS")
        match = /\A([0-9a-f]{64})  run-manifest\.json\n\z/.match(line)
        reject! unless match
        digest = Digest::SHA256.hexdigest(files.fetch("run-manifest.json"))
        reject! unless secure_equal?(digest, match[1])
        digest
      end

      def parse_canonical_object!(bytes)
        parsed = parse_object!(bytes)
        reject! unless "#{JSON.pretty_generate(parsed)}\n" == bytes
        parsed
      end

      def parse_object!(bytes)
        value = JSON.parse(bytes, object_class: DuplicateRejectingHash)
        reject! unless value.instance_of?(DuplicateRejectingHash) || value.instance_of?(Hash)
        deep_plain_copy(value)
      rescue JSON::ParserError
        reject!
      end

      def validate_bindings!(manifest, source_commit, sources, locked, inputs, environment, manifest_sha256)
        study = locked.study
        study_data = study.data
        run = inputs.fetch("run")
        run_order_index = study.plan.fetch("runs").index do |planned|
          planned.fetch("run_id").eql?(run.fetch("run_id"))
        end
        reject! unless run_order_index
        expected_pilot = deep_copy(locked.pilot_protocol.data).merge(
          CapacityRunManifest::PILOT_PROTOCOL_PATHS.to_h do |name, path|
            [name, Digest::SHA256.hexdigest(sources.fetch(path))]
          end
        )
        alignment = locked.protocol_alignment.data
        resolution = alignment.fetch("resolution")
        expected_alignment = {
          "status" => alignment.fetch("status"),
          "method" => resolution.fetch("method"),
          "alignment_sha256" => Digest::SHA256.hexdigest(
            sources.fetch("study/protocol-alignment-v1.yml")
          ),
          "implementation_equivalence_claimed" => resolution.fetch("implementation_equivalence_claimed"),
          "cross_version_pooling_allowed" => resolution.fetch("cross_version_pooling_allowed"),
          "cross_version_generalization_allowed" => resolution.fetch("cross_version_generalization_allowed"),
          "counted_execution_authorized" => resolution.fetch("counted_execution_authorized"),
          "remaining_gates" => deep_copy(alignment.fetch("remaining_gates"))
        }
        expected_inputs = {
          "config_sha256" => inputs.fetch("config_sha256"),
          "accounts_sha256" => inputs.fetch("accounts_sha256"),
          "workload_manifest_sha256" => inputs.fetch("workload_sha256").fetch("manifest.json")
        }
        expected_candidate = {
          "build_version" => "3.3.0",
          "image_digest" => CapacityEnvironmentProbe::IMAGE_DIGEST,
          "network_id" => WorkloadGenerator::NETWORK_ID,
          "memory_limit_bytes" => CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES,
          "allocated_logical_cpus" => CapacityMetrics::Reducer::ALLOCATED_LOGICAL_CPUS
        }
        expected_protocol_reference = {
          "implementation_release" => study_data.fetch("protocol_reference").fetch("implementation_release"),
          "implementation_commit" => study_data.fetch("protocol_reference").fetch("implementation_commit")
        }
        expected_metric_protocol = {
          "version" => "capacity-metrics-protocol-v1",
          "document_sha256" => Digest::SHA256.hexdigest(sources.fetch("docs/metrics-protocol-v1.md")),
          "sample_schema_sha256" => Digest::SHA256.hexdigest(
            sources.fetch("schemas/capacity-metric-sample-v1.schema.json")
          ),
          "summary_schema_sha256" => Digest::SHA256.hexdigest(
            sources.fetch("schemas/capacity-metrics-summary-v1.schema.json")
          )
        }
        valid = manifest.fetch("source_commit").eql?(source_commit) &&
          manifest.fetch("study_id").eql?(study_data.fetch("study_id")) &&
          manifest.fetch("study_sha256").eql?(locked.input_sha256.fetch("study/reserve-calibration-v1.yml")) &&
          manifest.fetch("run_id").eql?(RUN_ID) &&
          manifest.fetch("run_order_index").eql?(run_order_index + 1) &&
          manifest.fetch("base_reserve_xrp").eql?(run.fetch("base_reserve_xrp")) &&
          manifest.fetch("base_reserve_drops").eql?((run.fetch("base_reserve_xrp") * 1_000_000).round) &&
          manifest.fetch("planned_account_count").eql?(run.fetch("account_count")) &&
          manifest.fetch("generated_account_count").eql?(PILOT_ACCOUNTS) &&
          manifest.fetch("repetition").eql?(run.fetch("repetition")) &&
          manifest.fetch("network_id").eql?(WorkloadGenerator::NETWORK_ID) &&
          manifest.fetch("workload_name").eql?(study_data.fetch("workload").fetch("name")) &&
          manifest.fetch("warmup_seconds").eql?(study_data.fetch("workload").fetch("warmup_seconds")) &&
          manifest.fetch("measurement_seconds").eql?(study_data.fetch("workload").fetch("measurement_seconds")) &&
          manifest.fetch("inputs").eql?(expected_inputs) && manifest.fetch("pilot_protocol").eql?(expected_pilot) &&
          manifest.fetch("candidate_runtime").eql?(expected_candidate) &&
          manifest.fetch("preregistered_protocol_reference").eql?(expected_protocol_reference) &&
          manifest.fetch("protocol_alignment").eql?(expected_alignment) &&
          manifest.fetch("metric_protocol").eql?(expected_metric_protocol) &&
          manifest.fetch("metric_names").eql?(study_data.fetch("metrics")) &&
          manifest.fetch("acceptance_thresholds").eql?(study_data.fetch("acceptance_thresholds")) &&
          manifest.fetch("abort_rules").eql?(study_data.fetch("abort_rules")) &&
          manifest.fetch("environment").eql?(environment) && manifest_sha256.match?(/\A[0-9a-f]{64}\z/) &&
          manifest.fetch("pilot_complete").equal?(false) &&
          manifest.fetch("counted_run").equal?(false)
        reject! unless valid
        eligible = environment.fetch("host_architecture").eql?(environment.fetch("candidate_image_architecture"))
        reject! unless environment.fetch("native_architecture_eligible").equal?(eligible)
      rescue KeyError, TypeError
        reject!
      end

      def fingerprint(source_commit, sources, manifest_sha256, environment, inputs, pilot_bundle)
        graph = {
          "source_commit" => source_commit,
          "source_sha256" => sources.to_h { |path, bytes| [path, Digest::SHA256.hexdigest(bytes)] },
          "manifest_sha256" => manifest_sha256,
          "environment" => environment,
          "inputs" => {
            "config_sha256" => inputs.fetch("config_sha256"),
            "workload_sha256" => inputs.fetch("workload_sha256")
          },
          "pilot_bundle" => pilot_bundle
        }
        Digest::SHA256.hexdigest(JSON.generate(canonical(graph)))
      end

      def canonical(value)
        case value
        when Hash then value.to_h { |key, nested| [key, canonical(nested)] }.sort.to_h
        when Array then value.map { |nested| canonical(nested) }
        else value
        end
      end

      def secure_equal?(left, right)
        return false unless left.instance_of?(String) && right.instance_of?(String) && left.bytesize == right.bytesize
        left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
      end

      def deep_plain_copy(value)
        case value
        when Hash then value.to_h { |key, nested| [String(key), deep_plain_copy(nested)] }
        when Array then value.map { |nested| deep_plain_copy(nested) }
        else value
        end
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

      def reject!
        raise InputError, "invalid non-counted pilot inputs"
      end
    end

    class SamplerFactory
      class CandidateLedgerBoundary
        LEDGER_KEYS = %w[validated_ledger_index validated_ledger_hash].freeze
        HASH = /\A[A-F0-9]{64}\z/

        def initialize(client:, expected_reserve:)
          @client = client
          @expected_reserve = expected_reserve
        end

        def advance(previous_ledger:)
          reject! unless valid_ledger?(previous_ledger)
          index = previous_ledger.fetch("validated_ledger_index")
          advancement = @client.call("ledger_accept")
          reject! unless advancement.instance_of?(Hash) &&
            advancement.fetch("ledger_current_index").instance_of?(Integer) &&
            advancement.fetch("ledger_current_index") == index + 2
          response = @client.call(
            "ledger", { "ledger_index" => "validated", "transactions" => false, "expand" => false }
          )
          ledger = extract_ledger(response)
          reject! unless ledger.fetch("validated_ledger_index") == index + 1 &&
            !ledger.fetch("validated_ledger_hash").eql?(previous_ledger.fetch("validated_ledger_hash"))
          ledger
        rescue CapacityNonCountedPilotError
          raise
        rescue Interrupt
          raise
        rescue Exception
          reject!
        end

        def validated_ledger
          response = @client.call("server_info")
          info = response["info"] if response.instance_of?(Hash)
          ledger = info["validated_ledger"] if info.instance_of?(Hash)
          valid = info.instance_of?(Hash) && info["build_version"].eql?("3.3.0") &&
            info["network_id"].instance_of?(Integer) && info["network_id"] == 21_338 &&
            info["peers"].instance_of?(Integer) && info["peers"].zero? &&
            info["validation_quorum"].instance_of?(Integer) && info["validation_quorum"].zero? &&
            ledger.instance_of?(Hash) && ledger["seq"].instance_of?(Integer) && ledger["seq"].between?(1, 4_294_967_295) &&
            ledger["hash"].instance_of?(String) && ledger["hash"].match?(HASH) &&
            ledger["reserve_base_xrp"].instance_of?(Float) && ledger["reserve_base_xrp"].eql?(@expected_reserve)
          return nil unless valid
          deep_freeze(
            "validated_ledger_index" => ledger.fetch("seq"),
            "validated_ledger_hash" => ledger.fetch("hash").dup
          )
        rescue Interrupt
          raise
        rescue Exception
          nil
        end

        private

        def extract_ledger(response)
          nested = response["ledger"] if response.instance_of?(Hash)
          valid = response.instance_of?(Hash) &&
            (response.keys - %w[ledger ledger_hash ledger_index status validated]).empty? &&
            (!response.key?("status") || response["status"].eql?("success")) &&
            response["validated"].equal?(true) && response["ledger_index"].instance_of?(Integer) &&
            response["ledger_index"].between?(1, 4_294_967_295) &&
            response["ledger_hash"].instance_of?(String) && response["ledger_hash"].match?(HASH) &&
            nested.instance_of?(Hash) && nested["ledger_index"].eql?(response["ledger_index"]) &&
            nested["ledger_hash"].eql?(response["ledger_hash"])
          reject! unless valid
          deep_freeze(
            "validated_ledger_index" => response.fetch("ledger_index"),
            "validated_ledger_hash" => response.fetch("ledger_hash").dup
          )
        end

        def valid_ledger?(value)
          value.instance_of?(Hash) && value.frozen? && value.keys == LEDGER_KEYS &&
            value.fetch("validated_ledger_index").instance_of?(Integer) &&
            value.fetch("validated_ledger_index").between?(1, 4_294_967_295) &&
            value.fetch("validated_ledger_hash").instance_of?(String) &&
            value.fetch("validated_ledger_hash").match?(HASH)
        rescue KeyError
          false
        end

        def reject!
          raise CapacityNonCountedPilotError.new("ledger-boundary-failure", EMPTY_PROGRESS)
        end

        def deep_freeze(value)
          value.each { |key, nested| key.freeze; nested.freeze }
          value.freeze
        end
      end

      def initialize(client_factory: -> { CapacityRpcClient.new })
        @client_factory = client_factory
      end

      def call(snapshot)
        bundle = snapshot.fetch("pilot_bundle")
        run = bundle.fetch("run")
        reject! unless snapshot.instance_of?(Hash) && snapshot.frozen? && bundle.frozen? &&
          run.fetch("run_id").eql?(RUN_ID) && run.fetch("base_reserve_xrp").instance_of?(Float)
        client = @client_factory.call
        boundary = CandidateLedgerBoundary.new(
          client: client, expected_reserve: run.fetch("base_reserve_xrp")
        )
        engine = CapacityPilotExecutionEngine.new(client: client, pilot_bundle: bundle)
        collector = CapacityMetricSnapshotCollector.new(client: client)
        CapacityPilotSampler.new(
          collector: collector, ledger_advancer: boundary,
          transaction_engine: engine, recovery_probe: boundary
        )
      rescue CapacityNonCountedPilotError
        raise
      rescue Exception
        reject!
      end

      private

      def reject!
        raise CapacityNonCountedPilotError.new("sampler-configuration-failure", EMPTY_PROGRESS)
      end
    end

    class ArtifactValidator
      MAX_ARTIFACT_BYTES = 2_097_152
      RECOVERY_LEDGER_KEYS = %w[validated_ledger_index validated_ledger_hash].freeze
      RECOVERY_LEDGER_HASH = /\A[A-F0-9]{64}\z/
      SENSITIVE_KEY = /secret|seed|private[_-]?key|signed[_-]?blob|signature|signing|tx_blob|hostname|username|absolute[_-]?path|location|time[_-]?zone/i
      LOCAL_VALUE = %r{(?:\A|["'\s])/(?:Users|home|private|var/folders)/|(?:\A|["'\s])[A-Za-z]:\\}

      def initialize(schema_validator: ClosedSchemaValidator.new)
        @schema_validator = schema_validator
      end

      def validate_artifacts!(snapshot:, sampling:, recovery:, summary:, result:, bytes:)
        reject! unless snapshot.instance_of?(Hash) && sampling.instance_of?(Hash) &&
          recovery.instance_of?(Hash) && summary.instance_of?(Hash) && result.instance_of?(Hash) &&
          bytes.instance_of?(Hash) && bytes.keys == OUTPUT_FILES
        reject! if bytes.values.sum(&:bytesize) > MAX_ARTIFACT_BYTES
        parsed_result = parse_canonical_json!(bytes.fetch("pilot-result.json"), result)
        parsed_summary = parse_canonical_json!(bytes.fetch("metrics-summary.json"), summary)
        transactions = parse_canonical_jsonl!(bytes.fetch("transactions.jsonl"))
        samples = parse_canonical_jsonl!(bytes.fetch("samples.jsonl"))
        schemas = snapshot.fetch("schemas")
        validate_sampling!(snapshot, sampling, recovery, transactions, samples)
        reject! unless parsed_summary.eql?(summary) && parsed_result.eql?(result)
        reject! unless transactions.all? do |record|
          @schema_validator.valid?(schemas.fetch("capacity-pilot-execution-v1.schema.json"), record)
        end
        reject! unless samples.all? do |sample|
          @schema_validator.valid?(schemas.fetch("capacity-metric-sample-v1.schema.json"), sample)
        end
        reject! unless @schema_validator.valid?(
          schemas.fetch("capacity-metrics-summary-v1.schema.json"), summary
        )
        reject! unless @schema_validator.valid?(
          schemas.fetch("capacity-pilot-result-v1.schema.json"), result
        )
        validate_result_bindings!(snapshot, sampling, recovery, summary, result, bytes)
        bytes.each_value { |value| reject! if value.match?(LOCAL_VALUE) }
        reject_sensitive!(result)
        reject_sensitive!(summary)
        transactions.each { |record| reject_sensitive!(record) }
        samples.each { |sample| reject_sensitive!(sample) }
        true
      rescue CapacityNonCountedPilotError
        raise
      rescue Exception
        reject!
      end

      private

      def validate_sampling!(snapshot, sampling, recovery, transactions, samples)
        valid = sampling.fetch("status").eql?("completed") && sampling.fetch("sample_count").eql?(901) &&
          sampling.fetch("validated_transaction_count").eql?(3) && sampling.fetch("completed_record_count").eql?(3) &&
          sampling.fetch("abort_rule_breaches").eql?([]) && transactions.eql?(sampling.fetch("transaction_records")) &&
          samples.eql?([sampling.fetch("post_warmup_sample")] + sampling.fetch("measurement_samples")) &&
          samples.length == 901 && transactions.length == 3 &&
          recovery.fetch("recovered").equal?(true) && recovery.fetch("recovery_seconds").is_a?(Numeric) &&
          recovery.fetch("recovery_seconds").finite? && recovery.fetch("recovery_seconds").between?(0, 300)
        reject! unless valid
        samples.each_with_index do |sample, index|
          expected_phase = index.zero? ? "post-warmup" : "measurement"
          reject! unless sample.fetch("phase").eql?(expected_phase) && sample.fetch("sample_sequence").eql?(index)
          next if index.zero?
          previous = samples.fetch(index - 1)
          reject! unless sample.fetch("validated_ledger_index") == previous.fetch("validated_ledger_index") + 1 &&
            !sample.fetch("validated_ledger_hash").eql?(previous.fetch("validated_ledger_hash"))
        end
        reject! unless valid_recovery_ledger?(recovery.fetch("validated_ledger"))
        schedule = [[1, 1], [2, 450], [3, 900]]
        schedule.each_with_index do |(ordinal, sequence), index|
          record = transactions.fetch(index)
          intent = snapshot.dig("pilot_bundle", "intents", index)
          reject! unless record.fetch("ordinal").eql?(ordinal) &&
            record.fetch("measurement_sample_sequence").eql?(sequence) &&
            record.fetch("destination_account").eql?(intent.fetch("destination_account")) &&
            record.fetch("validated_ledger_index").eql?(samples.fetch(sequence).fetch("validated_ledger_index")) &&
            record.fetch("validated_ledger_hash").eql?(samples.fetch(sequence).fetch("validated_ledger_hash"))
        end
      end

      def validate_result_bindings!(snapshot, sampling, recovery, summary, result, bytes)
        expected = {
          "source_commit" => snapshot.fetch("source_commit"),
          "protocol_sha256" => snapshot.fetch("protocol_sha256"),
          "manifest_sha256" => snapshot.fetch("manifest_sha256"),
          "transactions_sha256" => Digest::SHA256.hexdigest(bytes.fetch("transactions.jsonl")),
          "samples_sha256" => Digest::SHA256.hexdigest(bytes.fetch("samples.jsonl")),
          "metrics_summary_sha256" => Digest::SHA256.hexdigest(bytes.fetch("metrics-summary.json")),
          "sample_count" => sampling.fetch("sample_count"),
          "transaction_count" => sampling.fetch("validated_transaction_count"),
          "thresholds_passed" => summary.fetch("thresholds_passed"),
          "controlled_restart_recovered" => recovery.fetch("recovered")
        }
        reject! unless expected.all? { |key, value| result.fetch(key).eql?(value) }
        reject! unless summary.fetch("abort_rule_breaches").eql?([]) && result.fetch("abort_rule_breached").equal?(false)
        passed = summary.fetch("thresholds_passed").equal?(true)
        reject! unless result.fetch("status").eql?(passed ? "passed" : "failed") &&
          result.fetch("disposition_code").eql?(passed ? "success" : "threshold-failure") &&
          result.fetch("pilot_complete").equal?(passed) && result.fetch("reset_confirmed").equal?(true) &&
          result.fetch("bindings_validated").equal?(true) &&
          result.fetch("counted_execution_authorized").equal?(false) &&
          result.fetch("native_execution_established").equal?(false)
        sums = CHECKSUM_FILES.map do |name|
          "#{Digest::SHA256.hexdigest(bytes.fetch(name))}  #{name}\n"
        end.join
        reject! unless bytes.fetch("SHA256SUMS").eql?(sums)
      end

      def valid_recovery_ledger?(ledger)
        ledger.instance_of?(Hash) && ledger.keys == RECOVERY_LEDGER_KEYS &&
          ledger["validated_ledger_index"].instance_of?(Integer) &&
          ledger["validated_ledger_index"].between?(1, 4_294_967_295) &&
          ledger["validated_ledger_hash"].instance_of?(String) &&
          ledger["validated_ledger_hash"].match?(RECOVERY_LEDGER_HASH)
      end

      def parse_canonical_json!(value, expected)
        reject! unless value.instance_of?(String) && value.end_with?("\n")
        parsed = JSON.parse(value)
        reject! unless "#{JSON.pretty_generate(parsed)}\n".eql?(value) && parsed.eql?(expected)
        parsed
      end

      def parse_canonical_jsonl!(value)
        reject! unless value.instance_of?(String) && value.end_with?("\n")
        value.lines.map do |line|
          canonical = line.delete_suffix("\n")
          parsed = JSON.parse(canonical)
          reject! unless parsed.instance_of?(Hash) && JSON.generate(parsed).eql?(canonical)
          parsed
        end
      end

      def reject_sensitive!(value)
        case value
        when Hash
          value.each do |key, nested|
            reject! if key.to_s.match?(SENSITIVE_KEY)
            reject_sensitive!(nested)
          end
        when Array
          value.each { |nested| reject_sensitive!(nested) }
        when String
          reject! if value.match?(LOCAL_VALUE)
        end
      end

      def reject!
        raise CapacityNonCountedPilotError.new("validation-failure", EMPTY_PROGRESS)
      end
    end
  end
end
