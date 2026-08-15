# frozen_string_literal: true

module XrplReserveStudy
  class CompleteReservesMatrixError < StudyError; end

  class CompleteReservesMatrix
    EXECUTION_UNAVAILABLE = "matrix execution is unavailable in this implementation phase"

    def initialize(authorization: CompleteReservesAuthorization.new)
      @authorization = authorization
    end

    def call(secret_reader:)
      @authorization.authorize!
      raise CompleteReservesMatrixError, EXECUTION_UNAVAILABLE
    rescue CompleteReservesAuthorizationError => e
      raise CompleteReservesMatrixError, e.message
    end
  end
end
