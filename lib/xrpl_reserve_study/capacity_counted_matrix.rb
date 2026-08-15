# frozen_string_literal: true

module XrplReserveStudy
  class CapacityCountedMatrixError < StudyError; end

  class CapacityCountedMatrix
    AUTHORIZATION_PATH = File.expand_path("../../study/counted-execution-authorization-v1.yml", __dir__)

    def initialize(authorization_loader: -> { CountedExecutionAuthorization.load(File.binread(AUTHORIZATION_PATH)) })
      @authorization_loader = authorization_loader
    end

    def call(secret_reader:)
      raise CapacityCountedMatrixError, "counted execution is not authorized" unless secret_reader.respond_to?(:call)

      authorization = @authorization_loader.call
      unless authorization.fetch("authorized") == true
        raise CapacityCountedMatrixError, "counted execution is not authorized"
      end

      raise CapacityCountedMatrixError, "counted matrix executor is not implemented"
    rescue CountedExecutionAuthorizationError
      raise CapacityCountedMatrixError, "counted execution is not authorized"
    end
  end
end
