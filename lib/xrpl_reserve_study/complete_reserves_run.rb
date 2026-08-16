# frozen_string_literal: true

module XrplReserveStudy
  class CompleteReservesRunError < StudyError; end

  # Compatibility wrapper that permits only the final guarded executor. The
  # previous arbitrary executor plus caller-supplied snapshot path is retired.
  class CompleteReservesRun
    def initialize(executor:)
      unless defined?(CompleteReservesExecutor) && executor.instance_of?(CompleteReservesExecutor)
        raise CompleteReservesRunError, "guarded complete reserves executor is required"
      end
      @executor = executor
    end

    def call(item:, secret_reader:, resume_record: nil)
      @executor.run(item: item, secret_reader: secret_reader, resume_record: resume_record)
    rescue CompleteReservesExecutorError => error
      raise CompleteReservesRunError, error.message
    end
  end
end
