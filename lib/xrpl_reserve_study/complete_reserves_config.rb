# frozen_string_literal: true

require "digest"

module XrplReserveStudy
  class CompleteReservesConfigError < StudyError; end

  class CompleteReservesConfig
    CONFIG_PATH = File.expand_path("../../capacity/config/rippled.cfg", __dir__)
    ASSIGNMENTS = {
      "base_reserve_xrp" => /^([ \t]*account_reserve[ \t]*=[ \t]*)(\d+)([ \t]*(?:\r?\n|\z))/,
      "owner_reserve_xrp" => /^([ \t]*owner_reserve[ \t]*=[ \t]*)(\d+)([ \t]*(?:\r?\n|\z))/
    }.freeze

    def initialize(canonical_config: nil)
      @canonical = canonical_config || File.binread(CONFIG_PATH)
      @publisher = RuntimePublisher.new(error_class: CompleteReservesConfigError, failure_label: "complete reserves config")
    end

    def render(run:, output_dir:)
      validate_run!(run)
      rendered = @canonical
      ASSIGNMENTS.each do |field, pattern|
        raise CompleteReservesConfigError, "canonical configuration must contain exactly one #{field} assignment" unless rendered.scan(pattern).length == 1
        rendered = rendered.sub(pattern) { "#{Regexp.last_match(1)}#{drops(run.fetch(field))}#{Regexp.last_match(3)}" }
      end
      checksums = @publisher.publish(output_dir) do |staging|
        staging.write("rippled.cfg", rendered)
        { "rippled.cfg" => staging.sha256("rippled.cfg") }
      end
      { "run_id" => run.fetch("run_id"), "base_reserve_drops" => drops(run.fetch("base_reserve_xrp")),
        "owner_reserve_drops" => drops(run.fetch("owner_reserve_xrp")), "changed_assignment_count" => 2,
        "sha256" => checksums.fetch("rippled.cfg") }.freeze
    end

    private

    def drops(value)
      (value * 1_000_000).round
    end

    def validate_run!(run)
      valid = run.is_a?(Hash) && run.fetch("run_id").is_a?(String) &&
        ["base_reserve_xrp", "owner_reserve_xrp"].all? { |key| run[key].is_a?(Numeric) && run[key].positive? }
      raise CompleteReservesConfigError, "invalid complete reserves run" unless valid
    rescue KeyError
      raise CompleteReservesConfigError, "invalid complete reserves run"
    end
  end
end
