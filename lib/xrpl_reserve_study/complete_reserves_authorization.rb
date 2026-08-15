# frozen_string_literal: true

require "yaml"

module XrplReserveStudy
  class CompleteReservesAuthorizationError < StudyError; end

  class CompleteReservesAuthorization
    PATH = File.expand_path("../../study/complete-reserves-authorization-v1.yml", __dir__)

    def initialize(path: PATH)
      @record = YAML.safe_load(File.binread(path), permitted_classes: [], aliases: false)
      valid = @record.is_a?(Hash) && @record.keys.sort == %w[authorization_scope authorized reason schema_version] &&
        @record["schema_version"] == "complete-reserves-authorization-v1" && @record["authorized"] == false &&
        @record["authorization_scope"] == "implementation-phase-only"
      raise CompleteReservesAuthorizationError, "invalid complete reserves authorization" unless valid
      @record.freeze
    rescue Psych::Exception, SystemCallError
      raise CompleteReservesAuthorizationError, "invalid complete reserves authorization"
    end

    def authorize!
      raise CompleteReservesAuthorizationError, "complete reserves execution remains disabled" unless @record.fetch("authorized")
    end
  end
end
