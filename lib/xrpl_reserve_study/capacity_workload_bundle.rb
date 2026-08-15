# frozen_string_literal: true

require "digest"
require "fiddle"
require "json"
require "rbconfig"

module XrplReserveStudy
  class CapacityWorkloadBundle
    MAX_INPUT_BYTES = 1_048_576
    MAX_RECORD_BYTES = 256
    WORKLOAD_FILES = %w[SHA256SUMS accounts.jsonl manifest.json].freeze
    CHECKSUM_FILES = %w[accounts.jsonl manifest.json].freeze
    SOURCE_ACCOUNT = WorkloadGenerator::SOURCE_ACCOUNT
    NETWORK_ID = WorkloadGenerator::NETWORK_ID
    FORBIDDEN_KEY = /secret|seed|private_key|signed|tx_blob/i

    def initialize(error_class:, locked_inputs: nil)
      @error_class = error_class
      @locked = locked_inputs || LockedCapacityInputs.new(error_class: error_class)
      @study = @locked.study
      @workload_generator = WorkloadGenerator.new(inputs: @locked)
    end

    def load(run:, workload_dir:, expected_generation_scope:, expected_record_count:)
      validate_policy!(run, expected_generation_scope, expected_record_count)
      maximums = { "accounts.jsonl" => [MAX_INPUT_BYTES, expected_record_count * MAX_RECORD_BYTES].max }
      workload = read_exact_directory(
        path: workload_dir, expected_names: WORKLOAD_FILES, label: "workload", maximums: maximums
      )
      sums = parse_sums!(workload.fetch("SHA256SUMS"))
      CHECKSUM_FILES.each do |name|
        reject!("workload checksum mismatch") unless
          secure_equal?(Digest::SHA256.hexdigest(workload.fetch(name)), sums.fetch(name))
      end
      manifest = parse_json!(workload.fetch("manifest.json"), "manifest")
      validate_manifest!(
        manifest, run, sums.fetch("accounts.jsonl"), expected_generation_scope, expected_record_count
      )
      parse_records!(workload.fetch("accounts.jsonl"), run, expected_record_count) do |record|
        yield record if block_given?
      end
      deep_freeze(
        "workload_sha256" => sums,
        "generation_scope" => manifest.fetch("generation_scope"),
        "generated_account_count" => manifest.fetch("generated_account_count"),
        "accounts_sha256" => manifest.fetch("accounts_sha256")
      )
    rescue @error_class
      raise
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError,
           RuntimePublisher::Native::UnsupportedPlatformError
      reject!("invalid capacity workload inputs")
    end

    def read_exact_directory(path:, expected_names:, label:, maximums: {})
      handles, names = open_runtime_path(path)
      directory = handles.last
      expanded = File.expand_path(String(path))
      stat = File.lstat(expanded)
      reject!("runtime directory binding changed during loading") unless
        stat.directory? && !stat.symlink? && [stat.dev, stat.ino] == directory.identity
      actual_names = descriptor_children(directory.io).sort
      reject!("runtime directory entries do not match the execution contract") unless
        actual_names == expected_names.sort
      bytes = expected_names.to_h do |name|
        [name, read_file(directory, name, maximums.fetch(name, MAX_INPUT_BYTES))]
      end
      verify_chain!(handles, names)
      rebound = File.lstat(expanded)
      reject!("runtime directory binding changed during loading") unless
        rebound.directory? && !rebound.symlink? && [rebound.dev, rebound.ino] == directory.identity
      bytes
    rescue @error_class
      raise
    rescue StandardError
      reject!("invalid capacity #{label} inputs")
    ensure
      handles&.reverse_each(&:close)
    end

    private

    def validate_policy!(run, scope, count)
      reject!("workload validation policy is invalid") unless run.is_a?(Hash)
      reject!("workload validation policy is invalid") unless %w[pilot full-plan].include?(scope)
      planned = run.fetch("account_count")
      reject!("workload validation policy is invalid") unless
        count.is_a?(Integer) && count.between?(1, planned)
      reject!("workload validation policy is invalid") if scope == "full-plan" && count != planned
    end

    def open_runtime_path(path)
      runtime_root = File.expand_path(RuntimePublisher::RUNTIME_ROOT)
      reject!("runtime root must not be a symlink") if File.symlink?(runtime_root)
      expanded = File.expand_path(String(path))
      prefix = "#{runtime_root}#{File::SEPARATOR}"
      reject!("execution input path must be a descendant of capacity/runtime") unless expanded.start_with?(prefix)
      relative = expanded.delete_prefix(prefix)
      reject!("execution input path is invalid") if relative.empty?

      repository = RuntimePublisher::DirectoryHandle.open(File.realpath(RuntimePublisher::REPOSITORY_ROOT))
      handles = [repository]
      names = %w[capacity runtime].concat(relative.split(File::SEPARATOR))
      names.each { |name| handles << handles.last.open_child(name, create: false) }
      [handles, names]
    rescue Exception
      handles&.reverse_each(&:close)
      raise
    end

    def verify_chain!(handles, names)
      current = handles.first
      reopened = []
      handles.drop(1).each_with_index do |expected, index|
        actual = current.open_child(names.fetch(index), create: false)
        reopened << actual
        reject!("execution input ancestry changed during loading") unless actual.identity == expected.identity
        current = actual
      end
    ensure
      reopened&.reverse_each(&:close)
    end

    def read_file(directory, name, maximum_bytes)
      file = RuntimePublisher::Native.open_read_at(directory.descriptor, name)
      before = file.stat
      reject!("execution input must be a regular file") unless before.file?
      reject!("execution input exceeds its byte limit") if before.size > maximum_bytes
      bytes = +""
      buffer = +""
      while file.read(64 * 1024, buffer)
        bytes << buffer
        reject!("execution input exceeds its byte limit") if bytes.bytesize > maximum_bytes
      end
      after = file.stat
      reject!("execution input changed during loading") unless
        [before.dev, before.ino, before.size, before.mtime] == [after.dev, after.ino, after.size, after.mtime]
      bytes
    ensure
      file&.close unless file&.closed?
    end

    def parse_sums!(bytes)
      lines = bytes.lines
      reject!("invalid workload SHA256SUMS") unless lines.length == 2 && lines.join == bytes
      sums = {}
      lines.each do |line|
        match = /\A([0-9a-f]{64})  (accounts\.jsonl|manifest\.json)\n\z/.match(line)
        reject!("invalid workload SHA256SUMS") unless match
        reject!("duplicate workload SHA256SUMS entry") if sums.key?(match[2])
        sums[match[2]] = match[1]
      end
      reject!("invalid workload SHA256SUMS order") unless sums.keys == CHECKSUM_FILES.sort
      sums
    end

    def validate_manifest!(manifest, run, accounts_sha256, scope, count)
      reject!("workload manifest must be an object") unless manifest.is_a?(Hash)
      reject_forbidden_unknown_keys!(manifest, allowed_manifest_keys)
      expected = {
        "schema_version" => "capacity-workload-v1",
        "study_id" => @study.data.fetch("study_id"),
        "study_sha256" => @locked.input_sha256.fetch("study/reserve-calibration-v1.yml"),
        "run_id" => run.fetch("run_id"),
        "workload_name" => @study.data.fetch("workload").fetch("name"),
        "generation_scope" => scope,
        "counted_run" => false,
        "base_reserve_xrp" => run.fetch("base_reserve_xrp"),
        "base_reserve_drops" => reserve_drops(run),
        "planned_account_count" => run.fetch("account_count"),
        "generated_account_count" => count,
        "repetition" => run.fetch("repetition"),
        "network_id" => NETWORK_ID,
        "source_account" => SOURCE_ACCOUNT,
        "destination_model" => "keyless-synthetic-account-id-v1",
        "private_keys_generated" => false,
        "signing_state" => "unsigned-intents",
        "account_id_derivation" => WorkloadGenerator::DERIVATION_DESCRIPTION,
        "accounts_path" => "accounts.jsonl",
        "accounts_sha256" => accounts_sha256
      }
      reject!("workload manifest does not match the planned run") unless manifest == expected
    end

    def parse_records!(bytes, run, expected_count)
      lines = bytes.lines
      reject!("workload record count does not match the pilot") unless
        bytes.end_with?("\n") && lines.length == expected_count && lines.join == bytes
      lines.each_with_index do |line, index|
        canonical = line.delete_suffix("\n")
        reject!("workload record must not be blank") if canonical.empty?
        record = parse_json!(canonical, "workload record")
        reject!("workload record must be a canonical JSON object") unless
          record.is_a?(Hash) && JSON.generate(record) == canonical
        reject_forbidden_unknown_keys!(record, intent_keys)
        ordinal = index + 1
        expected = {
          "ordinal" => ordinal,
          "transaction_type" => "Payment",
          "source_account" => SOURCE_ACCOUNT,
          "destination_account" => expected_destination(run.fetch("run_id"), ordinal),
          "amount_drops" => reserve_drops(run).to_s,
          "network_id" => NETWORK_ID
        }
        reject!("workload intent does not match the planned run") unless record == expected
        reject!("workload destination is not a valid unowned AccountID") unless
          valid_destination?(record["destination_account"])
        yield record if block_given?
      end
    end

    def valid_destination?(address)
      return false unless address.is_a?(String) &&
                          address.match?(/\Ar[#{Regexp.escape(WorkloadGenerator::BASE58_ALPHABET)}]{24,34}\z/)
      number = address.each_char.reduce(0) do |value, character|
        index = WorkloadGenerator::BASE58_ALPHABET.index(character)
        return false unless index
        (value * 58) + index
      end
      decoded = [number.to_s(16).rjust(50, "0")].pack("H*")
      return false unless decoded.bytesize == 25 && decoded.getbyte(0).zero?
      payload = decoded.byteslice(0, 21)
      checksum = Digest::SHA256.digest(Digest::SHA256.digest(payload)).byteslice(0, 4)
      secure_equal?(decoded.byteslice(21, 4), checksum) &&
        !WorkloadGenerator::RESERVED_ACCOUNT_IDS.include?(payload.byteslice(1, 20)) && address != SOURCE_ACCOUNT
    rescue StandardError
      false
    end

    def expected_destination(run_id, ordinal)
      @workload_generator.__send__(:derived_destination, run_id, ordinal)
    end

    def descriptor_children(directory_io)
      duplicate = directory_io.dup
      directory_pointer = fdopendir_function.call(duplicate.fileno)
      if directory_pointer.nil? || directory_pointer.to_i.zero?
        raise SystemCallError.new("fdopendir", Fiddle.last_error)
      end
      duplicate.autoclose = false
      names = []
      loop do
        Fiddle.last_error = 0
        entry_address = readdir_function.call(directory_pointer)
        if entry_address.nil? || entry_address.to_i.zero?
          error_number = Fiddle.last_error
          raise SystemCallError.new("readdir", error_number) unless error_number.zero?
          break
        end
        name = dirent_name(Fiddle::Pointer.new(entry_address))
        next if name == "." || name == ".."
        reject!("runtime directory contains too many entries") if names.length >= 32
        names << name
      end
      names
    ensure
      if directory_pointer && !directory_pointer.to_i.zero?
        result = closedir_function.call(directory_pointer)
        raise SystemCallError.new("closedir", Fiddle.last_error) if result == -1 && !$!
      else
        duplicate&.close unless duplicate&.closed?
      end
    end

    def dirent_name(pointer)
      record_length = pointer[16, 2].unpack1("S!")
      reject!("invalid descriptor directory entry") if record_length < dirent_name_offset + 1
      if darwin?
        name_length = pointer[18, 2].unpack1("S!")
        reject!("invalid descriptor directory entry") if name_length > record_length - dirent_name_offset
        pointer[dirent_name_offset, name_length]
      else
        bytes = pointer[dirent_name_offset, record_length - dirent_name_offset]
        terminator = bytes.index("\0")
        reject!("invalid descriptor directory entry") unless terminator
        bytes.byteslice(0, terminator)
      end
    end

    def dirent_name_offset
      darwin? ? 21 : 19
    end

    def darwin?
      RbConfig::CONFIG.fetch("host_os").match?(/darwin/i)
    end

    def fdopendir_function
      @fdopendir_function ||= native_function("fdopendir", [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
    end

    def readdir_function
      @readdir_function ||= native_function("readdir", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
    end

    def closedir_function
      @closedir_function ||= native_function("closedir", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    end

    def native_function(name, arguments, result)
      Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], arguments, result)
    rescue Fiddle::DLError
      raise RuntimePublisher::Native::UnsupportedPlatformError,
            "descriptor directory enumeration is unavailable on #{RUBY_PLATFORM}"
    end

    def reject_forbidden_unknown_keys!(value, allowed)
      value.each do |key, nested|
        if !allowed.include?(key) && String(key).match?(FORBIDDEN_KEY)
          reject!("forbidden secret or signed material in execution input")
        end
        reject_nested_forbidden!(nested)
      end
      reject!("object keys do not match the execution contract") unless value.keys.sort == allowed.sort
    end

    def reject_nested_forbidden!(value)
      case value
      when Hash
        value.each do |key, nested|
          reject!("forbidden secret or signed material in execution input") if String(key).match?(FORBIDDEN_KEY)
          reject_nested_forbidden!(nested)
        end
      when Array
        value.each { |nested| reject_nested_forbidden!(nested) }
      end
    end

    def allowed_manifest_keys
      %w[schema_version study_id study_sha256 run_id workload_name generation_scope counted_run
         base_reserve_xrp base_reserve_drops planned_account_count generated_account_count repetition
         network_id source_account destination_model private_keys_generated signing_state
         account_id_derivation accounts_path accounts_sha256]
    end

    def intent_keys
      %w[ordinal transaction_type source_account destination_account amount_drops network_id]
    end

    def parse_json!(bytes, label)
      JSON.parse(bytes)
    rescue JSON::ParserError
      reject!("invalid #{label} JSON")
    end

    def reserve_drops(run)
      (run.fetch("base_reserve_xrp") * 1_000_000).round
    end

    def secure_equal?(left, right)
      return false unless left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize
      left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!(message)
      raise @error_class, message
    end
  end
end
