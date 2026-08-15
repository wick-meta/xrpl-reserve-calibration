# frozen_string_literal: true

module XrplReserveStudy
  class CapacityExecutionInputError < StudyError; end

  class CapacityExecutionInputs
    CONFIG_FILES = %w[rippled.cfg].freeze

    def initialize(locked_inputs: nil)
      @locked = locked_inputs || LockedCapacityInputs.new(error_class: CapacityExecutionInputError)
      @study = @locked.study
      @renderer = CandidateConfigRenderer.new(inputs: @locked)
      @bundle = CapacityWorkloadBundle.new(error_class: CapacityExecutionInputError, locked_inputs: @locked)
    end

    def load(run_id:, config_dir:, workload_dir:)
      run = planned_run!(run_id)
      config = @bundle.read_exact_directory(
        path: config_dir, expected_names: CONFIG_FILES, label: "configuration"
      )
      expected_config = @renderer.expected(run_id: run_id)
      reject!("candidate configuration does not match the planned run") unless
        secure_equal?(config.fetch("rippled.cfg"), expected_config.fetch("config_bytes"))
      intent = nil
      workload = @bundle.load(
        run: run, workload_dir: workload_dir, expected_generation_scope: "pilot", expected_record_count: 1
      ) { |record| intent = record }
      deep_freeze(
        "run" => deep_copy(run),
        "config_sha256" => expected_config.fetch("sha256"),
        "workload_sha256" => workload.fetch("workload_sha256"),
        "intent" => intent
      )
    rescue CapacityExecutionInputError
      raise
    rescue StandardError
      raise CapacityExecutionInputError, "invalid capacity execution inputs"
    end

    private

    def planned_run!(run_id)
      run = @study.plan.fetch("runs").find { |candidate| candidate.fetch("run_id") == run_id }
      reject!("unknown planned run") unless run
      run
    end

    def secure_equal?(left, right)
      return false unless left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize
      left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
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

    def reject!(message)
      raise CapacityExecutionInputError, message
    end
  end
end
