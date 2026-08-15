# frozen_string_literal: true

module XrplReserveStudy
  class CompleteReservesMatrixError < StudyError; end

  class CompleteReservesMatrix
    def initialize(authorization: CompleteReservesAuthorization.new)
      @authorization = authorization
    end

    def call(secret_reader:)
      @authorization.authorize!
      raise CompleteReservesMatrixError, "matrix execution is unavailable in this implementation phase"
    rescue CompleteReservesAuthorizationError => e
      raise CompleteReservesMatrixError, e.message
    end
  end
end
