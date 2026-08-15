# frozen_string_literal: true

require "json"
require "io/console"
require "open3"
require "time"

module XrplReserveStudy
  class CapacityFunctionalSmokeError < StudyError; end

  class CapacitySecretReader
    MAX_SECRET_BYTES = 128

    def self.read(input:, error:)
      bytes = if input.tty?
                error.print("Standalone secret: ")
                begin
                  input.noecho { input.gets }
                ensure
                  error.puts
                end
              else
                value = input.read(MAX_SECRET_BYTES + 1)
                invalid! unless input.eof?
                value
              end
      invalid! unless bytes.is_a?(String) && bytes.end_with?("\n")
      value = bytes.delete_suffix("\n")
      invalid! if value.empty? || value.bytesize > MAX_SECRET_BYTES || value.include?("\r") ||
        value.include?("\n") || value.include?("\0")
      value
    rescue CapacityFunctionalSmokeError
      raise
    rescue StandardError
      invalid!
    end

    def self.invalid!
      raise CapacityFunctionalSmokeError, "invalid standalone secret input"
    end
    private_class_method :invalid!
  end

  class CapacityFunctionalSmoke
    RECORD_KEYS = %w[
      schema_version study_id study_sha256 run_id config_sha256 workload_sha256 execution_scope
      counted_run pilot_complete status error_code base_reserve_xrp base_reserve_drops account_count
      repetition started_at finished_at teardown_status teardown_completed_at attempted_transactions
      validated_successes ledger_advancements preflight_validated_ledger_index
      final_validated_ledger_index final_validated_ledger_hash outcomes
    ].freeze
    REQUIRED_RECORD_KEYS = %w[
      schema_version execution_scope counted_run pilot_complete status started_at finished_at
      teardown_status teardown_completed_at attempted_transactions validated_successes
      ledger_advancements outcomes
    ].freeze
    PASSED_RECORD_KEYS = %w[
      study_id study_sha256 run_id config_sha256 workload_sha256 base_reserve_xrp base_reserve_drops
      account_count repetition preflight_validated_ledger_index final_validated_ledger_index
      final_validated_ledger_hash
    ].freeze
    OUTCOME_KEYS = %w[
      ordinal destination_account transaction_hash preliminary_engine_result final_transaction_result
      validated_ledger_index account_root_balance_drops
    ].freeze
    SHA256 = /\A[a-f0-9]{64}\z/
    TX_HASH = /\A[A-F0-9]{64}\z/
    RUN_ID = /\Ar[0-9]{7}-a[0-9]{9}-n[0-9]{2}\z/
    ACCOUNT = /\Ar[1-9A-HJ-NP-Za-km-z]{24,34}\z/
    ERROR_CODE = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    VERIFY_ATTEMPTS = 3
    VERIFY_RETRY_DELAY_SECONDS = 1

    class HarnessRunner
      TIMEOUT_SECONDS = 10
      MAX_OUTPUT_BYTES = 1_048_576
      CLEANUP_JOIN_SECONDS = 1.0

      def initialize(timeout_seconds: TIMEOUT_SECONDS, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @root = File.realpath(File.expand_path("../..", __dir__))
        @harness = File.join(@root, "bin", "capacity-harness")
        @timeout_seconds = Float(timeout_seconds)
        raise ArgumentError unless @timeout_seconds.positive?

        @monotonic_clock = monotonic_clock
      end

      def call(command, run_id)
        argv = [@harness, command]
        argv << run_id unless command == "reset"
        environment = { "PATH" => ENV.fetch("PATH") }
        environment["XRPL_CAPACITY_CONFIRM_RESET"] = "1" if command == "reset"
        run_child(environment, argv)
        true
      rescue CapacityFunctionalSmokeError
        raise
      rescue StandardError
        raise CapacityFunctionalSmokeError, "capacity harness action failed"
      end

      private

      def run_child(environment, argv)
        stdin = stdout = stderr = wait_thread = nil
        readers = []
        deadline = monotonic_time + @timeout_seconds
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          environment, *argv, chdir: @root, pgroup: true, unsetenv_others: true
        )
        stdin.close
        stdin = nil
        readers = [stdout, stderr].map do |stream|
          Thread.new do
            bytes = +""
            buffer = +""
            while stream.read(16_384, buffer)
              bytes << buffer
              raise CapacityFunctionalSmokeError, "capacity harness action failed" if bytes.bytesize > MAX_OUTPUT_BYTES
            end
            bytes
          rescue IOError, Errno::EBADF
            bytes
          end
        end
        unless join_within_deadline(wait_thread, deadline)
          raise CapacityFunctionalSmokeError, "capacity harness action failed"
        end
        outputs = read_outputs(readers, deadline)
        raise CapacityFunctionalSmokeError, "capacity harness action failed" unless wait_thread.value.success?
        outputs
      rescue CapacityFunctionalSmokeError
        terminate(wait_thread) if wait_thread
        raise
      ensure
        terminate(wait_thread) if wait_thread&.alive?
        stdin.close if stdin && !stdin.closed?
        stdout.close if stdout && !stdout.closed?
        stderr.close if stderr && !stderr.closed?
        readers.each { |reader| reader.join(CLEANUP_JOIN_SECONDS) }
      end

      def read_outputs(readers, deadline)
        readers.map do |reader|
          unless join_within_deadline(reader, deadline)
            raise CapacityFunctionalSmokeError, "capacity harness action failed"
          end
          reader.value
        end
      end

      def join_within_deadline(thread, deadline)
        remaining = deadline - monotonic_time
        remaining.positive? && thread.join(remaining)
      end

      def terminate(wait_thread)
        process_group = -wait_thread.pid
        grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLEANUP_JOIN_SECONDS
        Process.kill("TERM", process_group)
        wait_thread.join(CLEANUP_JOIN_SECONDS)
        remaining_grace = grace_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Kernel.sleep(remaining_grace) if remaining_grace.positive?
        Process.kill("KILL", process_group)
        wait_thread.join(CLEANUP_JOIN_SECONDS) if wait_thread.alive?
      rescue Errno::ESRCH
        wait_thread.join(CLEANUP_JOIN_SECONDS) if wait_thread&.alive?
      end

      def monotonic_time
        value = @monotonic_clock.call
        raise CapacityFunctionalSmokeError, "capacity harness action failed" unless value.is_a?(Numeric)

        value
      end
    end

    def initialize(inputs: CapacityExecutionInputs.new, engine: nil, publisher: nil,
                   harness_runner: HarnessRunner.new, sleeper: ->(seconds) { sleep(seconds) },
                   clock: -> { Time.now.utc })
      @inputs = inputs
      @engine = engine || CapacityExecutionEngine.new(client: CapacityRpcClient.new)
      @publisher = publisher || RuntimePublisher.new(
        error_class: CapacityFunctionalSmokeError,
        failure_label: "capacity functional smoke outcome"
      )
      @harness_runner = harness_runner
      @sleeper = sleeper
      @clock = clock
    end

    def run(run_id:, config_dir:, workload_dir:, output_dir:, secret_reader:)
      inputs = load_inputs(run_id, config_dir, workload_dir)
      validate_output_dir!(output_dir)
      record = nil
      operation_error = nil
      secret = nil

      begin
        @harness_runner.call("up-candidate", run_id)
        verify_candidate(run_id)
        secret = secret_reader.call
        record = @engine.execute(inputs: inputs, secret: secret)
      rescue CapacityExecutionError => error
        record = error.record
      rescue Exception => error
        operation_error = error
      ensure
        erase_secret!(secret)
      end

      reset_candidate(run_id)
      raise CapacityFunctionalSmokeError, "capacity functional smoke failed" if operation_error

      completed_record = deep_copy(record)
      completed_record["teardown_status"] = "passed"
      completed_record["teardown_completed_at"] = timestamp
      validate_execution_record!(completed_record)
      publish(output_dir, completed_record)
      deep_freeze(completed_record)
    end

    private

    def verify_candidate(run_id)
      VERIFY_ATTEMPTS.times do |attempt|
        begin
          @harness_runner.call("verify-candidate", run_id)
          return
        rescue CapacityFunctionalSmokeError
          raise if attempt == VERIFY_ATTEMPTS - 1

          @sleeper.call(VERIFY_RETRY_DELAY_SECONDS)
        end
      end
    end

    def load_inputs(run_id, config_dir, workload_dir)
      @inputs.load(run_id: run_id, config_dir: config_dir, workload_dir: workload_dir)
    rescue Exception
      raise CapacityFunctionalSmokeError, "capacity functional smoke failed"
    end

    def reset_candidate(run_id)
      @harness_runner.call("reset", run_id)
    rescue Exception
      raise CapacityFunctionalSmokeError, "capacity functional smoke reset failed"
    end

    def validate_output_dir!(output_dir)
      runtime_root = File.expand_path(RuntimePublisher::RUNTIME_ROOT)
      expanded = File.expand_path(String(output_dir))
      prefix = "#{runtime_root}#{File::SEPARATOR}"
      raise CapacityFunctionalSmokeError, "capacity functional smoke failed" unless expanded.start_with?(prefix)

      relative = expanded.delete_prefix(prefix)
      current = runtime_root
      components = relative.split(File::SEPARATOR)
      components.each_with_index do |component, index|
        current = File.join(current, component)
        stat = File.lstat(current)
        if index == components.length - 1
          raise CapacityFunctionalSmokeError, "capacity functional smoke failed"
        end
        raise CapacityFunctionalSmokeError, "capacity functional smoke failed" unless stat.directory? && !stat.symlink?
      rescue Errno::ENOENT
        break
      end
    rescue CapacityFunctionalSmokeError
      raise
    rescue StandardError
      raise CapacityFunctionalSmokeError, "capacity functional smoke failed"
    end

    def publish(output_dir, record)
      execution = JSON.pretty_generate(record) + "\n"
      @publisher.publish(output_dir) do |staging|
        staging.write("execution.json", execution)
        checksum = staging.sha256("execution.json")
        staging.write("SHA256SUMS", "#{checksum}  execution.json\n")
        record
      end
    rescue Exception
      raise CapacityFunctionalSmokeError, "capacity functional smoke publication failed"
    end

    def validate_execution_record!(record)
      invalid_record! unless record.is_a?(Hash) && record.keys.all? { |key| key.is_a?(String) }
      invalid_record! unless (record.keys - RECORD_KEYS).empty? && (REQUIRED_RECORD_KEYS - record.keys).empty?
      invalid_record! unless record["schema_version"] == "capacity-execution-v1"
      invalid_record! unless record["execution_scope"] == "functional-smoke"
      invalid_record! unless record["counted_run"] == false && record["pilot_complete"] == false
      invalid_record! unless %w[passed failed aborted].include?(record["status"])
      invalid_record! unless timestamp?(record["started_at"]) && timestamp?(record["finished_at"])
      invalid_record! unless record["teardown_status"] == "passed" && timestamp?(record["teardown_completed_at"])
      %w[attempted_transactions validated_successes ledger_advancements].each do |key|
        invalid_record! unless record[key].is_a?(Integer) && record[key].between?(0, 1)
      end
      validate_optional_record_fields!(record)
      validate_outcomes!(record["outcomes"])

      if record["status"] == "passed"
        invalid_record! unless (PASSED_RECORD_KEYS - record.keys).empty? && !record.key?("error_code")
        invalid_record! unless record["attempted_transactions"] == 1 && record["validated_successes"] == 1 &&
          record["ledger_advancements"] == 1 && record["outcomes"].length == 1
      else
        invalid_record! unless record["error_code"].is_a?(String) && record["error_code"].match?(ERROR_CODE)
        invalid_record! unless record["validated_successes"] == 0
      end
    end

    def validate_optional_record_fields!(record)
      invalid_record! if record.key?("study_id") && record["study_id"] != "reserve-calibration-v1"
      %w[study_sha256 config_sha256].each do |key|
        invalid_record! if record.key?(key) && !(record[key].is_a?(String) && record[key].match?(SHA256))
      end
      invalid_record! if record.key?("run_id") && !(record["run_id"].is_a?(String) && record["run_id"].match?(RUN_ID))
      if record.key?("workload_sha256")
        hashes = record["workload_sha256"]
        invalid_record! unless hashes.is_a?(Hash) && hashes.keys.all? { |key| key.is_a?(String) } &&
          hashes.keys.sort == %w[accounts.jsonl manifest.json] &&
          hashes.values.all? { |value| value.is_a?(String) && value.match?(SHA256) }
      end
      invalid_record! if record.key?("base_reserve_xrp") && ![1.0, 0.5, 0.25, 0.1].include?(record["base_reserve_xrp"])
      invalid_record! if record.key?("base_reserve_drops") && ![1_000_000, 500_000, 250_000, 100_000].include?(record["base_reserve_drops"])
      %w[account_count repetition preflight_validated_ledger_index final_validated_ledger_index].each do |key|
        invalid_record! if record.key?(key) && !(record[key].is_a?(Integer) && record[key] >= 1)
      end
      invalid_record! if record.key?("final_validated_ledger_hash") &&
        !(record["final_validated_ledger_hash"].is_a?(String) && record["final_validated_ledger_hash"].match?(TX_HASH))
    end

    def validate_outcomes!(outcomes)
      invalid_record! unless outcomes.is_a?(Array) && outcomes.length <= 1
      outcomes.each do |outcome|
        invalid_record! unless outcome.is_a?(Hash) && outcome.keys.all? { |key| key.is_a?(String) } &&
          outcome.keys.sort == OUTCOME_KEYS.sort
        invalid_record! unless outcome["ordinal"] == 1
        invalid_record! unless outcome["destination_account"].is_a?(String) && outcome["destination_account"].match?(ACCOUNT)
        invalid_record! unless outcome["transaction_hash"].is_a?(String) && outcome["transaction_hash"].match?(TX_HASH)
        invalid_record! unless outcome["preliminary_engine_result"] == "tesSUCCESS" && outcome["final_transaction_result"] == "tesSUCCESS"
        invalid_record! unless outcome["validated_ledger_index"].is_a?(Integer) && outcome["validated_ledger_index"] >= 1
        invalid_record! unless outcome["account_root_balance_drops"].is_a?(String) &&
          outcome["account_root_balance_drops"].match?(/\A(?:0|[1-9][0-9]*)\z/)
      end
    end

    def timestamp?(value)
      value.is_a?(String) && value.end_with?("Z") && Time.iso8601(value)
    rescue ArgumentError
      false
    end

    def invalid_record!
      raise CapacityFunctionalSmokeError, "capacity functional smoke record is invalid"
    end

    def erase_secret!(secret)
      return unless secret.is_a?(String) && !secret.frozen?
      secret.bytesize.times { |index| secret.setbyte(index, 0) }
      secret.clear
    end

    def timestamp
      value = @clock.call
      raise CapacityFunctionalSmokeError, "capacity functional smoke record is invalid" unless value.is_a?(Time)
      value.utc.iso8601(6)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    rescue StandardError
      raise CapacityFunctionalSmokeError, "capacity functional smoke record is invalid"
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
