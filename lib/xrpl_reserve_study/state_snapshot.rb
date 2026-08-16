# frozen_string_literal: true

module XrplReserveStudy
  class StateSnapshotError < StudyError; end

  # Compatibility boundary: callers must move to VerifiedStateSnapshot and
  # RunCloneManager. It deliberately refuses the former metadata-only API.
  class StateSnapshot
    def initialize(runtime: nil, runtime_root: RuntimePublisher::RUNTIME_ROOT)
      @runtime = runtime
      @runtime_root = runtime_root
    end

    def publish(identity:, seed_result: nil, build_result: nil)
      raise StateSnapshotError, "metadata-only state snapshots are not valid" if build_result || seed_result.nil?
      raise StateSnapshotError, "checkout runtime is required for verified state snapshots" unless @runtime

      VerifiedStateSnapshot.new(runtime: @runtime, runtime_root: @runtime_root).publish(
        identity: identity, seed_result: seed_result
      )
    rescue VerifiedStateSnapshotError => error
      raise StateSnapshotError, error.message
    end

    def verify!(snapshot)
      raise StateSnapshotError, "checkout runtime is required for verified state snapshots" unless @runtime

      VerifiedStateSnapshot.new(runtime: @runtime, runtime_root: @runtime_root).verify!(snapshot)
    rescue VerifiedStateSnapshotError => error
      raise StateSnapshotError, error.message
    end

    def clone_for(run:)
      raise StateSnapshotError, "metadata-only clones are not valid; use RunCloneManager"
    end
  end
end
