# frozen_string_literal: true

require "psych"
require "digest"
require "json"

module XrplReserveStudy
  class CountedExecutionAuthorizationError < StudyError; end

  class CountedExecutionAuthorization
    REPOSITORY_ROOT = File.expand_path("../..", __dir__)
    REQUIRED_KEYS = %w[
      authorized candidate_image_digest candidate_release pilot_result_sha256
      run_order_sha256 schema_version study_sha256
    ].freeze
    SHA256 = /\A[0-9a-f]{64}\z/
    def self.load(bytes)
      raise CountedExecutionAuthorizationError, "invalid counted execution authorization" unless bytes.is_a?(String)

      document = Psych.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      valid = document.is_a?(Hash) && document.keys.sort == REQUIRED_KEYS.sort &&
        document["schema_version"] == "counted-execution-authorization-v1" && document["authorized"] == false &&
        document["candidate_release"] == "3.3.0" &&
        document["candidate_image_digest"] == "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70" &&
        %w[study_sha256 pilot_result_sha256 run_order_sha256].all? { |key| document[key].is_a?(String) && document[key].match?(SHA256) }
      valid &&= document["study_sha256"] == Digest::SHA256.file(File.join(REPOSITORY_ROOT, "study/reserve-calibration-v1.yml")).hexdigest
      valid &&= document["pilot_result_sha256"] == Digest::SHA256.file(File.join(REPOSITORY_ROOT, "evidence/capacity-pilots/native-330-run-31692384477/pilot-result.json")).hexdigest
      run_ids = Study.new(File.join(REPOSITORY_ROOT, "study/reserve-calibration-v1.yml")).plan.fetch("runs").map { |run| run.fetch("run_id") }
      valid &&= document["run_order_sha256"] == Digest::SHA256.hexdigest(JSON.generate(run_ids))
      raise CountedExecutionAuthorizationError, "invalid counted execution authorization" unless valid

      document.each { |key, value| key.freeze; value.freeze }
      document.freeze
    rescue CountedExecutionAuthorizationError
      raise
    rescue Psych::Exception, TypeError
      raise CountedExecutionAuthorizationError, "invalid counted execution authorization"
    end
  end
end
