# frozen_string_literal: true

require "digest"
require "yaml"

module XrplReserveStudy
  class CompleteReservesStudyError < StudyError; end

  class CompleteReservesStudy
    RUN_ORDER_SHA256 = "3ba9c46207777a3d3e4127a1abe1ddf01b78b176e175c2e2bc06509a4e729ca4"
    EXPECTED = {
      "schema_version" => "complete-reserves-study-v1",
      "study_id" => "complete-reserves-v1",
      "status" => "frozen-before-counted-execution",
      "base_reserve_options_xrp" => [1.0, 0.5, 0.25, 0.1],
      "owner_reserve_options_xrp" => [0.2, 0.1, 0.05, 0.02],
      "evidence_scales" => [1.0, 1.25, 1.5, 2.0],
      "combined_scales" => [1.5, 2.0],
      "repetitions" => 3,
      "warmup_seconds" => 300,
      "measurement_seconds" => 1800
    }.freeze

    attr_reader :data

    def initialize(path, source: nil)
      @data = YAML.safe_load(source || File.binread(path), permitted_classes: [], aliases: false)
      validate!
      deep_freeze(@data)
    rescue Psych::Exception, SystemCallError
      raise CompleteReservesStudyError, "invalid complete reserves study"
    end

    def plan(distribution:)
      accounts = positive_integer!(distribution, "account_roots")
      objects = positive_integer!(distribution, "owned_objects")
      runs = []
      append_runs(runs, "base", data.fetch("base_reserve_options_xrp"), [0.2], data.fetch("evidence_scales"), accounts, objects)
      append_runs(runs, "owner", [1.0], data.fetch("owner_reserve_options_xrp"), data.fetch("evidence_scales"), accounts, objects)
      append_runs(runs, "combined", [1.0, 0.1], [0.2, 0.02], data.fetch("combined_scales"), accounts, objects, corners: true)
      raise CompleteReservesStudyError, "invalid complete reserves study" unless runs.length == 120 && runs.map { |run| run.fetch("run_id") }.uniq.length == 120

      ordered = runs.sort_by { |run| Digest::SHA256.hexdigest("#{data.fetch('random_seed')}:#{run.fetch('run_id')}") }
      raise CompleteReservesStudyError, "invalid complete reserves study" unless
        Digest::SHA256.hexdigest(ordered.map { |run| run.fetch("run_id") }.join("\n")) == RUN_ORDER_SHA256
      deep_freeze(
        "study_id" => data.fetch("study_id"),
        "run_count" => ordered.length,
        "base_reserve_options_xrp" => data.fetch("base_reserve_options_xrp"),
        "owner_reserve_options_xrp" => data.fetch("owner_reserve_options_xrp"),
        "runs" => ordered
      )
    end

    private

    def validate!
      expected_keys = EXPECTED.keys + ["random_seed"]
      raise CompleteReservesStudyError, "invalid complete reserves study" unless data.is_a?(Hash) && data.keys.sort == expected_keys.sort
      EXPECTED.each { |key, value| raise CompleteReservesStudyError, "invalid complete reserves study" unless data.fetch(key) == value }
      raise CompleteReservesStudyError, "invalid complete reserves study" unless data.fetch("random_seed").is_a?(Integer) && data.fetch("random_seed").positive?
    end

    def append_runs(runs, program, bases, owners, scales, accounts, objects, corners: false)
      pairs = corners ? [[1.0, 0.2], [0.1, 0.2], [1.0, 0.02], [0.1, 0.02]] : bases.product(owners)
      pairs.each do |base, owner|
        scales.each do |scale|
          (1..data.fetch("repetitions")).each do |repetition|
            runs << {
              "run_id" => format("cr-%s-b%07d-o%07d-s%03d-r%02d", program, (base * 1_000_000).round, (owner * 1_000_000).round, (scale * 100).round, repetition),
              "program" => program,
              "base_reserve_xrp" => base,
              "owner_reserve_xrp" => owner,
              "scale" => scale,
              "repetition" => repetition,
              "account_root_target" => (accounts * scale).ceil,
              "owned_object_target" => (objects * scale).ceil
            }
          end
        end
      end
    end

    def positive_integer!(distribution, key)
      value = distribution.is_a?(Hash) ? distribution[key] : nil
      raise CompleteReservesStudyError, "invalid complete reserves study" unless value.is_a?(Integer) && value.positive?

      value
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
