# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class StateSnapshotError < StudyError; end

  class StateSnapshot
    ROOT = File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "snapshots")
    CLONE_ROOT = File.join(RuntimePublisher::RUNTIME_ROOT, "complete-reserves", "clones")
    REQUIRED_IDENTITY = %w[snapshot_id candidate_image_digest study_sha256 distribution_sha256 base_reserve_drops owner_reserve_drops scale expected_account_roots expected_owned_objects database_sha256].freeze
    SHA_KEYS = %w[candidate_image_digest study_sha256 distribution_sha256 database_sha256].freeze

    def initialize
      @publisher = RuntimePublisher.new(error_class: StateSnapshotError, failure_label: "state snapshot")
      @published = nil
    end

    def publish(identity:, build_result:)
      validate_identity!(identity)
      validate_build!(build_result)
      reject_sensitive!(identity)
      reject_sensitive!(build_result)
      output = File.join(ROOT, identity.fetch("snapshot_id"))
      record = identity.merge("schema_version" => "state-snapshot-v1", "source_build_sha256" => build_result.fetch("source_build_sha256"),
                              "attempted_transactions" => build_result.fetch("attempted_transactions"), "validated_transactions" => build_result.fetch("validated_transactions"))
      @publisher.publish(output) do |staging|
        staging.write("snapshot.json", JSON.pretty_generate(record) + "\n")
        { "snapshot.json" => staging.sha256("snapshot.json") }
      end
      @published = record.merge("path" => output, "sha256" => Digest::SHA256.file(File.join(output, "snapshot.json")).hexdigest).freeze
    end

    def clone_for(run:)
      raise StateSnapshotError, "no verified snapshot is available" unless @published
      run_id = run.is_a?(Hash) ? run["run_id"] : nil
      raise StateSnapshotError, "invalid clone run" unless run_id.is_a?(String) && run_id.match?(/\A[a-z0-9-]+\z/)
      destination = File.join(CLONE_ROOT, run_id)
      bytes = File.binread(File.join(@published.fetch("path"), "snapshot.json"))
      @publisher.publish(destination) { |staging| staging.write("snapshot.json", bytes); { "snapshot.json" => staging.sha256("snapshot.json") } }
      { "run_id" => run_id, "snapshot_id" => @published.fetch("snapshot_id"), "path" => destination,
        "snapshot_sha256" => Digest::SHA256.file(File.join(destination, "snapshot.json")).hexdigest }.freeze
    end

    private

    def validate_identity!(value)
      raise StateSnapshotError, "invalid snapshot identity" unless value.is_a?(Hash) && value.keys.sort == REQUIRED_IDENTITY.sort
      raise StateSnapshotError, "invalid snapshot identifier" unless value["snapshot_id"].is_a?(String) && value["snapshot_id"].match?(/\A[a-z0-9-]+\z/)
      SHA_KEYS.each { |key| raise StateSnapshotError, "invalid snapshot hash" unless value[key].is_a?(String) && value[key].match?(/\A[a-f0-9]{64}\z/) }
      %w[base_reserve_drops owner_reserve_drops expected_account_roots expected_owned_objects].each { |key| raise StateSnapshotError, "invalid snapshot count" unless value[key].is_a?(Integer) && value[key].positive? }
      raise StateSnapshotError, "invalid snapshot scale" unless value["scale"].is_a?(Numeric) && value["scale"].positive?
    end

    def validate_build!(value)
      valid = value.is_a?(Hash) && value["attempted_transactions"].is_a?(Integer) && value["attempted_transactions"].positive? &&
        value["validated_transactions"] == value["attempted_transactions"] && value["source_build_sha256"].is_a?(String) && value["source_build_sha256"].match?(/\A[a-f0-9]{64}\z/)
      raise StateSnapshotError, "invalid verified build result" unless valid
    end

    def reject_sensitive!(value)
      case value
      when Hash then value.each { |key, nested| raise StateSnapshotError, "sensitive snapshot content" if key.to_s.match?(/secret|seed|private.?key|master.?key/i); reject_sensitive!(nested) }
      when Array then value.each { |nested| reject_sensitive!(nested) }
      when String then raise StateSnapshotError, "sensitive snapshot content" if value.match?(/\As[1-9A-HJ-NP-Za-km-z]{20,}\z/)
      end
    end
  end
end
