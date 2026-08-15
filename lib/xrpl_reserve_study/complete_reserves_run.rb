# frozen_string_literal: true

module XrplReserveStudy
  class CompleteReservesRunError < StudyError; end

  class CompleteReservesRun
    def initialize(executor:, artifacts: nil)
      @executor = executor
      @artifacts = artifacts
    end

    def call(run:, snapshot:, secret_reader:)
      validate_snapshot!(run, snapshot)
      secret = secret_reader.call
      raise CompleteReservesRunError, "missing signing authority" unless secret.is_a?(String) && !secret.empty?
      executed = @executor.call(run: run, snapshot: snapshot, secret: secret)
      status = executed.is_a?(Hash) ? executed["status"] : nil
      raise CompleteReservesRunError, "invalid complete reserves execution" unless %w[passed failed aborted].include?(status)
      result = { "run_id" => run.fetch("run_id"), "status" => status, "counted_run" => false,
                 "snapshot_id" => snapshot["snapshot_id"], "distribution_sha256" => snapshot["distribution_sha256"],
                 "summary" => executed["summary"] }.freeze
      @artifacts.publish_disposition(result: result, summary: executed.fetch("summary")) if @artifacts && status != "aborted"
      result
    ensure
      if secret.is_a?(String) && !secret.frozen?
        secret.bytesize.times { |index| secret.setbyte(index, 0) }
        secret.clear
      end
    end

    private

    def validate_snapshot!(run, snapshot)
      valid = run.is_a?(Hash) && snapshot.is_a?(Hash) &&
        snapshot["base_reserve_drops"] == (run["base_reserve_xrp"] * 1_000_000).round &&
        snapshot["owner_reserve_drops"] == (run["owner_reserve_xrp"] * 1_000_000).round &&
        snapshot["scale"] == run["scale"]
      raise CompleteReservesRunError, "snapshot does not match complete reserves run" unless valid
    rescue TypeError, NoMethodError
      raise CompleteReservesRunError, "snapshot does not match complete reserves run"
    end
  end
end
