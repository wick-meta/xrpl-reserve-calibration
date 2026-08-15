# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CapacityCountedArtifactsError < StudyError; end

  class CapacityCountedArtifacts
    RUN_ID = /\Ar[0-9]{7}-a[0-9]{9}-n[0-9]{2}\z/
    FILES = %w[SHA256SUMS metrics-summary.json result.json samples.jsonl transactions.jsonl].freeze
    SENSITIVE = /secret|seed|private[_-]?key|signature|signing|tx_blob|hostname|username|absolute[_-]?path|location|time[_-]?zone/i

    def initialize(runtime_root: RuntimePublisher::RUNTIME_ROOT)
      @runtime_root = File.expand_path(runtime_root)
      @publisher = RuntimePublisher.new(error_class: CapacityCountedArtifactsError, failure_label: "counted disposition")
    end

    def publish_disposition(run_id:, result:, samples:, transactions:, summary:)
      reject! unless run_id.is_a?(String) && run_id.match?(RUN_ID)
      reject! unless result.is_a?(Hash) && result["counted_run"] == true && result["status"] == "passed"
      reject_sensitive!(result)
      reject_sensitive!(summary)
      reject! unless samples.is_a?(String) && transactions.is_a?(String)
      reject! if samples.match?(SENSITIVE) || transactions.match?(SENSITIVE)

      bytes = {
        "result.json" => "#{JSON.pretty_generate(result)}\n",
        "samples.jsonl" => samples,
        "transactions.jsonl" => transactions,
        "metrics-summary.json" => "#{JSON.pretty_generate(summary)}\n"
      }
      bytes["SHA256SUMS"] = bytes.keys.sort.map { |name| "#{Digest::SHA256.hexdigest(bytes.fetch(name))}  #{name}\n" }.join
      output_dir = File.join(@runtime_root, "counted-matrix", run_id)
      @publisher.publish(output_dir) { |staging| FILES.each { |name| staging.write(name, bytes.fetch(name)) } }
      deep_freeze("run_id" => run_id.dup, "output_dir" => output_dir)
    rescue CapacityCountedArtifactsError
      raise
    rescue StandardError
      reject!
    end

    private

    def reject_sensitive!(value)
      case value
      when Hash
        value.each { |key, nested| reject! if key.to_s.match?(SENSITIVE); reject_sensitive!(nested) }
      when Array then value.each { |nested| reject_sensitive!(nested) }
      when String then reject! if value.match?(SENSITIVE)
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise CapacityCountedArtifactsError, "invalid counted disposition"
    end
  end
end
