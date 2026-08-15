# frozen_string_literal: true

require "digest"

module XrplReserveStudy
  class PopulationBuilderError < StudyError; end

  class PopulationBuilder
    MAX_INFLIGHT_PER_SOURCE = 10

    def initialize(client:)
      @client = client
    end

    def build(run:, secret_reader:)
      raise PopulationBuilderError, "isolated candidate network is required" unless @client.isolated?
      target = run.fetch("account_root_target")
      raise PopulationBuilderError, "invalid population target" unless target.is_a?(Integer) && target.positive?
      secret = secret_reader.call
      raise PopulationBuilderError, "missing signing authority" unless secret.is_a?(String) && !secret.empty?
      attempted = validated = 0
      sources = (target.to_f / MAX_INFLIGHT_PER_SOURCE).ceil
      (1..target).each do |ordinal|
        source = "source-#{((ordinal - 1) % sources) + 1}"
        response = @client.submit(source: source, intent: { "ordinal" => ordinal }, secret: secret)
        attempted += 1
        raise PopulationBuilderError, "transaction was not validated" unless @client.final?(hash: response.fetch("hash"))
        validated += 1
      end
      { "schema_version" => "population-build-result-v1", "run_id" => run.fetch("run_id"), "counted_run" => false,
        "attempted_transactions" => attempted, "validated_transactions" => validated,
        "source_count" => sources, "max_inflight_per_source" => MAX_INFLIGHT_PER_SOURCE,
        "source_build_sha256" => Digest::SHA256.hexdigest([run.fetch("run_id"), attempted, validated, sources].join("\0")) }.freeze
    ensure
      if secret.is_a?(String) && !secret.frozen?
        secret.bytesize.times { |index| secret.setbyte(index, 0) }
        secret.clear
      end
    end

    def calibrate(run:, secret_reader:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      started = clock.call
      result = build(run: run, secret_reader: secret_reader)
      elapsed = clock.call - started
      raise PopulationBuilderError, "invalid calibration duration" unless elapsed.positive?
      result.merge("calibration_only" => true, "construction_seconds" => elapsed,
                   "construction_transactions_per_second" => result.fetch("validated_transactions") / elapsed).freeze
    end
  end
end
