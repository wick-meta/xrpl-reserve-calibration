# frozen_string_literal: true

require "digest"
require "json"
require_relative "runtime_publisher"

module XrplReserveStudy
  class LockedCapacityInputs
    class DuplicateRejectingHash < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate candidate input lock key" if key?(key)

        super
      end
    end
    private_constant :DuplicateRejectingHash

    REPOSITORY_ROOT = File.expand_path("../..", __dir__)
    COMMITTED_STUDY_PATH = File.join(REPOSITORY_ROOT, "study", "reserve-calibration-v1.yml")
    PROTOCOL_ALIGNMENT_PATH = File.join(REPOSITORY_ROOT, "study", "protocol-alignment-v1.yml")
    PILOT_PROTOCOL_PATH = File.join(REPOSITORY_ROOT, "capacity", "pilot-protocol-v1.yml")
    CANONICAL_CONFIG_PATH = File.join(REPOSITORY_ROOT, "capacity", "config", "rippled.cfg")
    INPUT_LOCK_PATH = File.join(REPOSITORY_ROOT, "capacity", "candidate-inputs.lock.json")
    INPUT_LOCK_RELATIVE_PATH = "capacity/candidate-inputs.lock.json"
    INPUT_PATHS = {
      "study/reserve-calibration-v1.yml" => COMMITTED_STUDY_PATH,
      "capacity/config/rippled.cfg" => CANONICAL_CONFIG_PATH,
      "study/protocol-alignment-v1.yml" => PROTOCOL_ALIGNMENT_PATH,
      "capacity/pilot-protocol-v1.yml" => PILOT_PROTOCOL_PATH
    }.freeze
    SOURCE_PATHS = INPUT_PATHS.merge(INPUT_LOCK_RELATIVE_PATH => INPUT_LOCK_PATH).freeze
    MAX_INPUT_BYTES = 1_048_576

    attr_reader :input_sha256, :pilot_protocol, :protocol_alignment, :study, :verified_inputs

    def initialize(error_class: StudyError, sources: nil)
      @error_class = error_class
      @sources = validate_sources(sources)
      @verified_inputs, @input_sha256 = load_verified_inputs
      @study = Study.new(
        COMMITTED_STUDY_PATH,
        source: @verified_inputs.fetch("study/reserve-calibration-v1.yml")
      )
      @protocol_alignment = ProtocolAlignment.load(
        @verified_inputs.fetch("study/protocol-alignment-v1.yml"), error_class: @error_class
      )
      @pilot_protocol = CapacityPilotProtocol.load(
        @verified_inputs.fetch("capacity/pilot-protocol-v1.yml"), error_class: @error_class
      )
    end

    private

    def validate_sources(sources)
      return nil if sources.nil?

      expected = [INPUT_LOCK_RELATIVE_PATH] + INPUT_PATHS.keys
      unless sources.is_a?(Hash) && sources.keys.sort == expected.sort &&
             sources.all? do |path, bytes|
               path.is_a?(String) && bytes.is_a?(String) && bytes.bytesize <= MAX_INPUT_BYTES
             end
        raise @error_class, "candidate input sources must contain exactly the required inputs"
      end
      sources.each_with_object({}) do |(path, bytes), captured|
        captured[path.dup.freeze] = bytes.dup.freeze
      end.freeze
    end

    def load_verified_inputs
      lock = JSON.parse(
        source_bytes(INPUT_LOCK_RELATIVE_PATH, INPUT_LOCK_PATH), object_class: DuplicateRejectingHash
      )
      unless lock.keys == %w[schema_version inputs] && lock["schema_version"].instance_of?(Integer) &&
             lock["schema_version"] == 1
        raise @error_class, "candidate input lock schema must be 1"
      end

      locked_inputs = lock.fetch("inputs")
      unless locked_inputs.is_a?(Hash) && locked_inputs.keys.sort == INPUT_PATHS.keys.sort
        raise @error_class, "candidate input lock must contain exactly the required inputs"
      end

      verified_inputs = {}
      input_sha256 = {}
      INPUT_PATHS.each do |relative_path, absolute_path|
        descriptor = locked_inputs.fetch(relative_path)
        unless descriptor.is_a?(Hash) && descriptor.keys == ["sha256"]
          raise @error_class, "candidate input lock descriptor must contain exactly SHA-256"
        end
        expected_sha256 = descriptor.fetch("sha256")
        unless expected_sha256.is_a?(String) && expected_sha256.match?(/\A[0-9a-f]{64}\z/)
          raise @error_class, "invalid locked SHA-256 for #{relative_path}"
        end

        bytes = source_bytes(relative_path, absolute_path)
        actual_sha256 = Digest::SHA256.hexdigest(bytes)
        unless actual_sha256 == expected_sha256
          raise @error_class,
                "input SHA-256 mismatch for #{relative_path}: expected #{expected_sha256}, got #{actual_sha256}"
        end

        verified_inputs[relative_path] = bytes
        input_sha256[relative_path] = actual_sha256
      end

      [verified_inputs.freeze, input_sha256.freeze]
    rescue JSON::ParserError, KeyError, TypeError => e
      raise @error_class, "invalid candidate input lock: #{e.message}"
    rescue SystemCallError => e
      raise @error_class, "could not read candidate inputs: #{e.message}"
    end

    def source_bytes(relative_path, absolute_path)
      return @sources.fetch(relative_path) if @sources

      read_repository_file(relative_path, absolute_path)
    end

    def read_repository_file(relative_path, absolute_path)
      reject_repository_path!(relative_path, absolute_path)
      repository = RuntimePublisher::DirectoryHandle.open(File.realpath(REPOSITORY_ROOT))
      components = relative_path.split(File::SEPARATOR)
      directories = [repository]
      components[0...-1].each { |name| directories << directories.last.open_child(name, create: false) }
      file = RuntimePublisher::Native.open_read_at(directories.last.descriptor, components.last)
      before = file.stat
      raise @error_class, "candidate input is not a regular file" unless before.file?
      raise @error_class, "candidate input exceeds its byte limit" if before.size > MAX_INPUT_BYTES

      bytes = +""
      buffer = +""
      while file.read(64 * 1024, buffer)
        bytes << buffer
        raise @error_class, "candidate input exceeds its byte limit" if bytes.bytesize > MAX_INPUT_BYTES
      end
      after = file.stat
      unless [before.dev, before.ino, before.size, before.mtime] == [after.dev, after.ino, after.size, after.mtime]
        raise @error_class, "candidate input changed during loading"
      end
      bytes
    ensure
      file&.close unless file&.closed?
      directories&.reverse_each(&:close)
    end

    def reject_repository_path!(relative_path, absolute_path)
      expected = SOURCE_PATHS.fetch(relative_path)
      unless expected == absolute_path && File.expand_path(absolute_path) == expected &&
             relative_path.split(File::SEPARATOR).all? do |component|
               component.is_a?(String) && !component.empty? && component != "." && component != ".." &&
                 !component.include?(File::SEPARATOR) && !component.include?("\0")
             end
        raise @error_class, "invalid candidate input path"
      end
    end
  end
end
