# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module XrplReserveStudy
  class StudyError < StandardError; end

  class Study
    REQUIRED_KEYS = %w[
      schema_version study_id status random_seed network reserve_options_xrp
      protocol_reference reference_base_reserve_xrp account_counts repetitions
      counted_run_policy workload metrics metric_definitions acceptance_thresholds abort_rules
    ].freeze

    attr_reader :path, :data

    def initialize(path, source: nil)
      @path = File.expand_path(path)
      @data = YAML.safe_load(source || File.read(@path), permitted_classes: [], aliases: false)
      validate!
    rescue Psych::Exception => e
      raise StudyError, "invalid study YAML: #{e.message}"
    end

    def validate!
      raise StudyError, "study root must be a mapping" unless data.is_a?(Hash)

      missing = REQUIRED_KEYS - data.keys
      raise StudyError, "missing keys: #{missing.join(', ')}" unless missing.empty?

      numeric_array!("reserve_options_xrp", positive: true)
      numeric_array!("account_counts", positive: true, integer: true)
      positive_integer!("repetitions")
      positive_integer!("random_seed")
      reference = data.fetch("reference_base_reserve_xrp")
      unless data.fetch("reserve_options_xrp").include?(reference)
        raise StudyError, "reference_base_reserve_xrp must be a reserve option"
      end
      missing_definitions = data.fetch("metrics") - data.fetch("metric_definitions").keys
      raise StudyError, "metrics missing definitions: #{missing_definitions.join(', ')}" unless missing_definitions.empty?
      unless data.dig("counted_run_policy", "retry_counted_run") == false
        raise StudyError, "counted runs must not be retried in place"
      end

      expected = data.fetch("reserve_options_xrp").length *
        data.fetch("account_counts").length * data.fetch("repetitions")
      raise StudyError, "study must define at least one run" unless expected.positive?

      self
    end

    def plan
      cells = data.fetch("reserve_options_xrp").product(data.fetch("account_counts"))
      runs = cells.flat_map do |reserve, count|
        (1..data.fetch("repetitions")).map do |repetition|
          {
            "run_id" => format("r%07d-a%09d-n%02d", (reserve * 1_000_000).round, count, repetition),
            "base_reserve_xrp" => reserve,
            "account_count" => count,
            "repetition" => repetition
          }
        end
      end

      randomized = runs.sort_by do |run|
        Digest::SHA256.hexdigest("#{data.fetch('random_seed')}:#{run.fetch('run_id')}")
      end

      {
        "study_id" => data.fetch("study_id"),
        "cell_count" => cells.length,
        "run_count" => runs.length,
        "random_seed" => data.fetch("random_seed"),
        "runs" => randomized
      }
    end

    def model(accounts:, owned_objects:, owner_reserve_xrp: 0.2)
      raise StudyError, "accounts must be a non-negative integer" unless non_negative_integer?(accounts)
      raise StudyError, "owned_objects must be a non-negative integer" unless non_negative_integer?(owned_objects)

      options = data.fetch("reserve_options_xrp").map do |base|
        account_component = accounts * base
        owner_component = owned_objects * owner_reserve_xrp
        {
          "base_reserve_xrp" => base,
          "account_component_xrp" => account_component,
          "owner_component_xrp" => owner_component,
          "total_locked_xrp" => account_component + owner_component
        }
      end

      current = options.find do |row|
        row.fetch("base_reserve_xrp") == data.fetch("reference_base_reserve_xrp")
      end
      options.each do |row|
        row["delta_from_reference_xrp"] = row.fetch("total_locked_xrp") - current.fetch("total_locked_xrp")
      end

      {
        "study_id" => data.fetch("study_id"),
        "inputs" => {
          "accounts" => accounts,
          "owned_objects" => owned_objects,
          "owner_reserve_xrp" => owner_reserve_xrp,
          "reference_base_reserve_xrp" => current.fetch("base_reserve_xrp")
        },
        "scenarios" => options
      }
    end

    private

    def numeric_array!(key, positive:, integer: false)
      value = data.fetch(key)
      valid = value.is_a?(Array) && !value.empty? && value.all? do |item|
        item.is_a?(Numeric) && (!positive || item.positive?) && (!integer || item.is_a?(Integer))
      end
      raise StudyError, "#{key} must be a non-empty numeric array" unless valid
      raise StudyError, "#{key} values must be unique" unless value.uniq.length == value.length
    end

    def positive_integer!(key)
      value = data.fetch(key)
      raise StudyError, "#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?
    end

    def non_negative_integer?(value)
      value.is_a?(Integer) && !value.negative?
    end
  end
end
