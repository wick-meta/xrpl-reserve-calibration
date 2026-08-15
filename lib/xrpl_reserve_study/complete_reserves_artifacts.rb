# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CompleteReservesArtifactsError < StudyError; end

  class CompleteReservesArtifacts
    SENSITIVE = /secret|seed|private[_-]?key|signature|signing|tx_blob|hostname|username|absolute[_-]?path|location|time[_-]?zone/i
    REQUIRED = %w[run_id status counted_run distribution_sha256 snapshot_id object_counts_by_class locked_xrp_drops released_xrp_drops owner_count_lifecycle].freeze

    def initialize
      @publisher = RuntimePublisher.new(error_class: CompleteReservesArtifactsError, failure_label: "complete reserves disposition")
    end

    def publish_disposition(result:, summary:)
      validate!(result, summary)
      bytes = { "result.json" => JSON.pretty_generate(result) + "\n", "summary.json" => JSON.pretty_generate(summary) + "\n" }
      bytes["SHA256SUMS"] = bytes.keys.sort.map { |name| "#{Digest::SHA256.hexdigest(bytes.fetch(name))}  #{name}\n" }.join
      output = File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "results", result.fetch("run_id"))
      @publisher.publish(output) { |staging| bytes.each { |name, content| staging.write(name, content) } }
      { "run_id" => result.fetch("run_id"), "output_dir" => output }.freeze
    end

    private

    def validate!(result, summary)
      raise CompleteReservesArtifactsError, "incomplete complete reserves disposition" unless result.is_a?(Hash) && REQUIRED.all? { |key| result.key?(key) } && %w[passed failed aborted].include?(result["status"]) && result["counted_run"] == false
      reject_sensitive!(result)
      reject_sensitive!(summary)
    end

    def reject_sensitive!(value)
      case value
      when Hash then value.each { |key, nested| raise CompleteReservesArtifactsError, "sensitive complete reserves content" if key.to_s.match?(SENSITIVE); reject_sensitive!(nested) }
      when Array then value.each { |nested| reject_sensitive!(nested) }
      when String then raise CompleteReservesArtifactsError, "sensitive complete reserves content" if value.match?(SENSITIVE)
      end
    end
  end
end
