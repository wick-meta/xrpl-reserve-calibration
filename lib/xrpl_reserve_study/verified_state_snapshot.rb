# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "securerandom"

module XrplReserveStudy
  class VerifiedStateSnapshotError < StudyError; end

  # Captures a stopped, checkout-local database as an image whose content and
  # post-restart ledger identity are both independently checkable.
  class VerifiedStateSnapshot
    ROOT_COMPONENTS = %w[complete-reserves snapshots].freeze
    IDENTITY_KEYS = %w[snapshot_id candidate_image_digest study_sha256 distribution_sha256 config_sha256 source_sha256].freeze
    BINDING_KEYS = IDENTITY_KEYS.drop(1).freeze
    LEDGER_KEYS = %w[network_id ledger_index ledger_hash account_roots class_counts].freeze
    SHA_KEYS = %w[candidate_image_digest study_sha256 distribution_sha256 config_sha256 source_sha256 ledger_hash].freeze
    FORBIDDEN_KEY = /secret|seed|private.?key|master.?key|endpoint|host|user|path|url/i
    FORBIDDEN_TEXT = /(?:\A[rs][1-9A-HJ-NP-Za-km-z]{20,}\z|https?:\/\/|\b(?:mainnet|testnet|localhost)\b|(?:secret|seed|private.?key|master.?key|endpoint|host|user|path)\s*[=:])/i
    LOCAL_IDENTITY = /machine|operator|location|hostname|host|user|path|endpoint|secret|seed|private.?key|master.?key/i
    CANDIDATE_STATE_DIRECTORIES = %w[nudb].freeze
    CANDIDATE_NUDB_FILES = %w[nudb/nudb.dat nudb/nudb.key].freeze
    SCRUBBED_RUNTIME_CACHES = %w[peerfinder.sqlite].freeze
    NUDB_VERSION = 2
    NUDB_APPNUM = 1
    NUDB_KEY_SIZE = 32
    NUDB_BLOCK_SIZE = 4096
    NUDB_LOAD_FACTOR = 32_768
    NUDB_DAT_HEADER_SIZE = 92
    NUDB_KEY_HEADER_SIZE = 104
    BINARY_IDENTITY_ASSIGNMENT = /(?:machine(?:[_ -]?id)?|operator|location|hostname|host|user|path|endpoint|secret|seed|private[_ -]?key|master[_ -]?key)\s*[=:]/in
    IDENTITY_TOKENS = [
      "machine", "machine_id", "machine-id", "operator", "location", "hostname", "host", "user", "path",
      "endpoint", "secret", "seed", "private_key", "private-key", "private key", "master_key", "master-key", "master key"
    ].freeze
    IDENTITY_ENCODINGS = [Encoding::UTF_8, Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].freeze
    ENCODED_NUL_IDENTITY_SEQUENCES = IDENTITY_TOKENS.flat_map do |token|
      IDENTITY_ENCODINGS.flat_map do |encoding|
        encoded_token = token.encode(encoding).b
        encoded_nul = "\0".encode(encoding).b
        [encoded_token + encoded_nul, encoded_nul + encoded_token]
      end
    end.uniq.freeze
    SEED_RESULT_KEYS = %w[schema_version profile_id cell_id counted_run elapsed_seconds attempted_transactions validated_transactions burned_fee_drops locked_xrp_drops released_xrp_drops finality classified_ledger_evidence resource_snapshots].freeze

    def initialize(runtime:, runtime_root: RuntimePublisher::RUNTIME_ROOT)
      @runtime = runtime
      @runtime_root = File.expand_path(runtime_root)
    end

    def publish(identity:, seed_result:)
      stopped = restarted = published = success = false
      prepared_identity = validate_identity!(identity)
      expected_ledger = ledger_from_seed!(seed_result)
      source = checkout_state_path!
      source_ancestry = ancestor_identities!(source)
      destination = File.join(snapshot_root, prepared_identity.fetch("snapshot_id"))
      raise VerifiedStateSnapshotError, "snapshot destination already exists" if File.exist?(destination) || File.symlink?(destination)

      require_runtime!(:stop_checkout!)
      @runtime.stop_checkout!
      stopped = true
      source_manifest = safe_manifest!(source)
      temporary = "#{destination}.tmp-#{SecureRandom.hex(12)}"
      copy_image!(source, temporary, source_manifest)
      record = prepared_identity.merge(
        "schema_version" => "verified-state-snapshot-v1", "ledger" => expected_ledger,
        "files" => source_manifest
      )
      write_record!(temporary, record)
      ensure_ancestors_unchanged!(source, source_ancestry)
      publish_directory!(temporary, destination)
      published = true
      require_runtime!(:start_readonly!)
      @runtime.start_readonly!
      restarted = true
      actual_ledger = validate_ledger!(@runtime.ledger_identity)
      raise VerifiedStateSnapshotError, "restart ledger identity does not match seed state" unless actual_ledger == expected_ledger

      success = true
      public_record(record, destination)
    rescue VerifiedStateSnapshotError
      raise
    rescue SystemCallError, IOError, JSON::ParserError => error
      raise VerifiedStateSnapshotError, "could not capture verified state snapshot: #{error.message}"
    ensure
      if stopped && !restarted
        begin
          @runtime.start_readonly!
        rescue StandardError
          # The capture failure remains primary; callers can observe the adapter's restart failure separately.
        end
      end
      remove_published_image!(destination) if published && !success
      FileUtils.rm_rf(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def verify!(snapshot)
      public = validate_snapshot_record!(snapshot)
      with_bound_snapshot(public) do |snapshot_handle|
        after_snapshot_bind!
        stored = JSON.parse(read_bound_file!(snapshot_handle, "snapshot.json"))
        expected = public.reject { |key, _| %w[path directory_binding].include?(key) }
        raise VerifiedStateSnapshotError, "snapshot record does not match image" unless stored == expected
        state_handle = snapshot_handle.open_child("state", create: false)
        begin
          actual = bound_manifest!(state_handle, public.fetch("files"))
        ensure
          state_handle.close
        end
        begin
          resolved = safe_manifest!(File.join(public.fetch("path"), "state"))
        rescue VerifiedStateSnapshotError
          raise VerifiedStateSnapshotError, "snapshot state manifest does not match image"
        end
        raise VerifiedStateSnapshotError, "snapshot state manifest does not match image" unless actual == public.fetch("files") && resolved == public.fetch("files")
        unless directory_binding!(public.fetch("path")) == public.fetch("directory_binding")
          raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory"
        end
      end
      true
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, JSON::ParserError
      raise VerifiedStateSnapshotError, "snapshot image is incomplete"
    end

    private

    def validate_identity!(identity)
      valid = identity.is_a?(Hash) && identity.keys.sort == IDENTITY_KEYS.sort &&
        identity["snapshot_id"].is_a?(String) && identity["snapshot_id"].match?(/\A[a-z0-9-]+\z/) &&
        BINDING_KEYS.all? { |key| sha?(identity[key]) }
      raise VerifiedStateSnapshotError, "invalid verified snapshot identity" unless valid
      reject_sensitive!(identity)
      identity.sort.to_h.freeze
    end

    def ledger_from_seed!(seed_result)
      valid = seed_result.is_a?(Hash) && seed_result.keys.all? { |key| SEED_RESULT_KEYS.include?(key) } &&
        seed_result["schema_version"] == "complete-reserves-seed-state-v2" &&
        seed_result["counted_run"] == false
      raise VerifiedStateSnapshotError, "invalid complete reserves seed result" unless valid
      reject_sensitive!(seed_result)
      validate_ledger!(seed_result["classified_ledger_evidence"])
    end

    def validate_ledger!(ledger)
      valid = ledger.is_a?(Hash) && ledger.keys.sort == LEDGER_KEYS.sort &&
        ledger["network_id"].is_a?(String) && ledger["network_id"].match?(/\Acandidate-[a-z0-9-]+\z/) &&
        ledger["ledger_index"].is_a?(Integer) && ledger["ledger_index"].positive? && sha?(ledger["ledger_hash"]) &&
        ledger["account_roots"].is_a?(Integer) && ledger["account_roots"].positive? &&
        ledger["class_counts"].is_a?(Hash) && ledger["class_counts"].any? &&
        ledger["class_counts"].all? { |key, count| key.is_a?(String) && key.match?(/\A[a-z0-9_]+\z/) && count.is_a?(Integer) && count.positive? }
      raise VerifiedStateSnapshotError, "invalid verified ledger identity" unless valid
      ledger.sort.to_h.freeze
    end

    def checkout_state_path!
      require_runtime!(:state_path)
      path = @runtime.state_path
      valid = path.is_a?(String) && File.directory?(path) && !File.symlink?(path) && within_runtime?(path)
      raise VerifiedStateSnapshotError, "checkout runtime state must be a real directory within runtime" unless valid
      path
    end

    def safe_manifest!(root)
      root_stat = File.lstat(root)
      raise VerifiedStateSnapshotError, "runtime state is incomplete" unless root_stat.directory?
      entries = []
      admitted = {}
      Find.find(root) do |path|
        next if path == root
        relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
        stat = File.lstat(path)
        if stat.directory?
          unless CANDIDATE_STATE_DIRECTORIES.include?(relative)
            raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy"
          end
          next
        elsif stat.file?
          reject_state_name!(relative)
          bytes = File.binread(path)
          if SCRUBBED_RUNTIME_CACHES.include?(relative)
            validate_sqlite_cache!(bytes)
            next
          end
          reject_state_bytes!(bytes, name: relative)
          admitted[relative] = bytes
          entries << { "name" => relative, "bytes" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest }
        else
          raise VerifiedStateSnapshotError, "runtime state contains symlink or device"
        end
      end
      validate_candidate_state_image!(admitted)
      raise VerifiedStateSnapshotError, "runtime state is incomplete" if entries.empty?
      entries.sort_by { |entry| entry.fetch("name") }.freeze
    end

    def copy_image!(source, temporary, expected)
      FileUtils.mkdir_p(File.join(temporary, "state"), mode: 0o700)
      expected.each do |entry|
        source_path = File.join(source, entry.fetch("name"))
        destination_path = File.join(temporary, "state", entry.fetch("name"))
        FileUtils.mkdir_p(File.dirname(destination_path), mode: 0o700)
        FileUtils.copy_file(source_path, destination_path, true)
      end
      copied = safe_manifest!(File.join(temporary, "state"))
      raise VerifiedStateSnapshotError, "runtime state changed during copy" unless copied == expected
    end

    def write_record!(directory, record)
      reject_sensitive!(record)
      File.binwrite(File.join(directory, "snapshot.json"), JSON.generate(record.sort.to_h) + "\n")
    end

    def publish_directory!(temporary, destination)
      raise VerifiedStateSnapshotError, "snapshot destination already exists" if File.exist?(destination) || File.symlink?(destination)
      parent = File.dirname(destination)
      FileUtils.mkdir_p(parent, mode: 0o700)
      raise VerifiedStateSnapshotError, "snapshot ancestor is a symlink" if symlinked_ancestor?(parent)
      parent_handle = RuntimePublisher::DirectoryHandle.open(parent)
      staging = parent_handle.open_child(File.basename(temporary), create: false)
      staging.close
      parent_handle.rename_noreplace(File.basename(temporary), File.basename(destination))
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise VerifiedStateSnapshotError, "snapshot destination already exists"
    ensure
      parent_handle&.close
    end

    def remove_published_image!(destination)
      return unless destination && destination == File.join(snapshot_root, File.basename(destination)) &&
                    File.directory?(destination) && !File.symlink?(destination)

      FileUtils.remove_entry_secure(destination, true)
    rescue StandardError => error
      raise VerifiedStateSnapshotError, "could not remove failed state snapshot: #{error.message}"
    end

    def validate_snapshot_record!(snapshot)
      valid = snapshot.is_a?(Hash) && snapshot.keys.sort == (IDENTITY_KEYS + %w[schema_version ledger files path directory_binding]).sort &&
        snapshot["schema_version"] == "verified-state-snapshot-v1" && snapshot["path"].is_a?(String) &&
        snapshot["path"] == File.join(snapshot_root, snapshot["snapshot_id"])
      raise VerifiedStateSnapshotError, "invalid verified snapshot record" unless valid
      validate_identity!(snapshot.slice(*IDENTITY_KEYS))
      validate_ledger!(snapshot["ledger"])
      validate_manifest!(snapshot["files"])
      validate_directory_binding!(snapshot["directory_binding"])
      unless directory_binding!(snapshot.fetch("path")) == snapshot.fetch("directory_binding")
        raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory"
      end
      reject_sensitive!(snapshot.reject { |key, _| key == "path" })
      snapshot
    end

    def validate_manifest!(files)
      valid = files.is_a?(Array) && files.any? && files == files.sort_by { |entry| entry["name"] } &&
        files.all? { |entry| entry.is_a?(Hash) && entry.keys.sort == %w[bytes name sha256] && entry["name"].is_a?(String) && safe_relative?(entry["name"]) && entry["bytes"].is_a?(Integer) && entry["bytes"] >= 0 && sha?(entry["sha256"]) }
      raise VerifiedStateSnapshotError, "invalid snapshot state manifest" unless valid
    end

    def public_record(record, path)
      record.merge("path" => path, "directory_binding" => directory_binding!(path)).freeze
    end

    def snapshot_root
      File.join(@runtime_root, *ROOT_COMPONENTS)
    end

    def within_runtime?(path)
      expanded = File.expand_path(path)
      expanded.start_with?("#{@runtime_root}#{File::SEPARATOR}") && !symlinked_ancestor?(expanded)
    end

    def symlinked_ancestor?(path)
      current = File.expand_path(path)
      loop do
        return true if File.symlink?(current)
        parent = File.dirname(current)
        return false if parent == current || current == @runtime_root
        current = parent
      end
    end

    def ancestor_identities!(path)
      ancestors = []
      current = File.expand_path(path)
      loop do
        stat = File.lstat(current)
        raise VerifiedStateSnapshotError, "runtime state ancestor changed during capture" if stat.symlink?
        ancestors << [current, stat.dev, stat.ino]
        break if current == @runtime_root
        parent = File.dirname(current)
        raise VerifiedStateSnapshotError, "runtime state ancestor changed during capture" if parent == current
        current = parent
      end
      ancestors.freeze
    rescue Errno::ENOENT
      raise VerifiedStateSnapshotError, "runtime state ancestor changed during capture"
    end

    def ensure_ancestors_unchanged!(path, expected)
      actual = ancestor_identities!(path)
      raise VerifiedStateSnapshotError, "runtime state ancestor changed during capture" unless actual == expected
    end

    def reject_state_name!(name)
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless safe_relative?(name)
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" if name.match?(LOCAL_IDENTITY)
    end

    def reject_sensitive!(value)
      case value
      when Hash
        value.each do |key, nested|
          next if key.to_s == "name" && nested.is_a?(String) && safe_relative?(nested)
          raise VerifiedStateSnapshotError, "sensitive snapshot content" if key.to_s.match?(FORBIDDEN_KEY)
          reject_sensitive!(nested)
        end
      when Array then value.each { |nested| reject_sensitive!(nested) }
      when String then raise VerifiedStateSnapshotError, "sensitive snapshot content" if value.match?(FORBIDDEN_TEXT)
      end
    end

    def require_runtime!(method)
      raise VerifiedStateSnapshotError, "checkout runtime adapter is invalid" unless @runtime.respond_to?(method)
    end

    def safe_relative?(value)
      value.match?(/\A[^\/\0]+(?:\/[^\/\0]+)*\z/) && !value.split(File::SEPARATOR).include?("..")
    end

    def sha?(value)
      value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
    end

    def directory_binding!(path)
      binding = []
      current = path
      loop do
        stat = File.lstat(current)
        raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory" unless stat.directory?
        binding << [stat.dev, stat.ino]
        break if current == @runtime_root
        parent = File.dirname(current)
        raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory" if parent == current
        current = parent
      end
      binding.freeze
    rescue Errno::ENOENT, Errno::ELOOP
      raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory"
    end

    def validate_directory_binding!(value)
      valid = value.is_a?(Array) && value.length == ROOT_COMPONENTS.length + 2 &&
        value.all? { |entry| entry.is_a?(Array) && entry.length == 2 && entry.all? { |number| number.is_a?(Integer) && number >= 0 } }
      raise VerifiedStateSnapshotError, "invalid snapshot directory binding" unless valid
    end

    def reject_state_bytes!(bytes, name:)
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless bytes.is_a?(String) && !bytes.empty?
      reject_binary_identity!(bytes)
      case name
      when "nudb/nudb.dat" then parse_nudb_dat!(bytes)
      when "nudb/nudb.key" then parse_nudb_key!(bytes)
      else raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy"
      end
    end

    def validate_candidate_state_image!(files)
      unless files.keys.sort == CANDIDATE_NUDB_FILES
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy"
      end
      dat = parse_nudb_dat!(files.fetch("nudb/nudb.dat"))
      key = parse_nudb_key!(files.fetch("nudb/nudb.key"))
      unless dat.values_at(:version, :uid, :appnum, :key_size) == key.values_at(:version, :uid, :appnum, :key_size)
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy"
      end
      validate_nudb_data_records!(files.fetch("nudb/nudb.dat"), dat.fetch(:key_size))
      validate_nudb_buckets!(files.fetch("nudb/nudb.key"), files.fetch("nudb/nudb.dat"), key)
    end

    def parse_nudb_dat!(bytes)
      valid = bytes.bytesize >= NUDB_DAT_HEADER_SIZE && bytes.byteslice(0, 8) == "nudb.dat" &&
        bytes.byteslice(8, 2).unpack1("n") == NUDB_VERSION && bytes.byteslice(18, 8).unpack1("Q>") == NUDB_APPNUM &&
        bytes.byteslice(26, 2).unpack1("n") == NUDB_KEY_SIZE && zero_bytes?(bytes.byteslice(28, 64))
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless valid
      { version: NUDB_VERSION, uid: bytes.byteslice(10, 8).unpack1("Q>"), appnum: NUDB_APPNUM, key_size: NUDB_KEY_SIZE }
    end

    def parse_nudb_key!(bytes)
      valid = bytes.bytesize >= (NUDB_BLOCK_SIZE * 2) && bytes.bytesize.modulo(NUDB_BLOCK_SIZE).zero? &&
        bytes.byteslice(0, 8) == "nudb.key" && bytes.byteslice(8, 2).unpack1("n") == NUDB_VERSION &&
        bytes.byteslice(18, 8).unpack1("Q>") == NUDB_APPNUM && bytes.byteslice(26, 2).unpack1("n") == NUDB_KEY_SIZE &&
        bytes.byteslice(44, 2).unpack1("n") == NUDB_BLOCK_SIZE && bytes.byteslice(46, 2).unpack1("n") == NUDB_LOAD_FACTOR &&
        !zero_bytes?(bytes.byteslice(28, 8)) && !zero_bytes?(bytes.byteslice(36, 8)) && zero_bytes?(bytes.byteslice(48, 56))
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless valid
      { version: NUDB_VERSION, uid: bytes.byteslice(10, 8).unpack1("Q>"), appnum: NUDB_APPNUM,
        key_size: NUDB_KEY_SIZE, block_size: NUDB_BLOCK_SIZE }
    end

    def validate_nudb_data_records!(bytes, key_size)
      offset = NUDB_DAT_HEADER_SIZE
      while offset < bytes.bytesize
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" if bytes.bytesize - offset < 6
        size = uint48(bytes.byteslice(offset, 6))
        offset += 6
        if size.positive?
          offset += key_size + size
        else
          raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" if bytes.bytesize - offset < 2
          spill_size = bytes.byteslice(offset, 2).unpack1("n")
          offset += 2 + spill_size
        end
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" if offset > bytes.bytesize
      end
    end

    def validate_nudb_buckets!(key_bytes, dat_bytes, key)
      capacity = (key.fetch(:block_size) - 8) / 18
      (key.fetch(:block_size)...key_bytes.bytesize).step(key.fetch(:block_size)) do |offset|
        bucket = key_bytes.byteslice(offset, key.fetch(:block_size))
        count = bucket.byteslice(0, 2).unpack1("n")
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" if count > capacity
        count.times do |index|
          item = bucket.byteslice(8 + (index * 18), 18)
          data_offset = uint48(item.byteslice(0, 6))
          data_size = uint48(item.byteslice(6, 6))
          valid = data_offset >= NUDB_DAT_HEADER_SIZE && data_size.positive? &&
            data_offset + 6 + key.fetch(:key_size) + data_size <= dat_bytes.bytesize
          raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless valid
        end
      end
    end

    def validate_sqlite_cache!(bytes)
      reject_binary_identity!(bytes)
      page_size = bytes.bytesize >= 100 ? bytes.byteslice(16, 2).unpack1("n") : 0
      page_size = 65_536 if page_size == 1
      page_count = bytes.bytesize >= 32 ? bytes.byteslice(28, 4).unpack1("N") : 0
      schema_format = bytes.bytesize >= 48 ? bytes.byteslice(44, 4).unpack1("N") : 0
      encoding = bytes.bytesize >= 60 ? bytes.byteslice(56, 4).unpack1("N") : 0
      valid = bytes.bytesize >= 512 && bytes.byteslice(0, 16) == "SQLite format 3\0" &&
        page_size.between?(512, 65_536) && (page_size & (page_size - 1)).zero? && bytes.bytesize.modulo(page_size).zero? &&
        [1, 2].include?(bytes.getbyte(18)) && [1, 2].include?(bytes.getbyte(19)) &&
        bytes.getbyte(21) == 64 && bytes.getbyte(22) == 32 && bytes.getbyte(23) == 32 &&
        page_count == bytes.bytesize / page_size && schema_format.between?(1, 4) && encoding.between?(1, 3) &&
        [2, 5, 10, 13].include?(bytes.getbyte(100))
      raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy" unless valid
    end

    def reject_binary_identity!(bytes)
      lowered = bytes.downcase
      collapsed = lowered.delete("\0")
      nul_delimited_identity = ENCODED_NUL_IDENTITY_SEQUENCES.any? { |sequence| lowered.include?(sequence) }
      if lowered.match?(BINARY_IDENTITY_ASSIGNMENT) || collapsed.match?(BINARY_IDENTITY_ASSIGNMENT) || nul_delimited_identity
        raise VerifiedStateSnapshotError, "runtime state violates strict artifact policy"
      end
    end

    def zero_bytes?(bytes)
      bytes && bytes.each_byte.all?(&:zero?)
    end

    def uint48(bytes)
      bytes.each_byte.reduce(0) { |value, byte| (value << 8) | byte }
    end

    def with_bound_snapshot(snapshot)
      root = RuntimePublisher::DirectoryHandle.open(@runtime_root)
      handles = [root]
      %w[complete-reserves snapshots].each { |name| handles << handles.last.open_child(name, create: false) }
      handles << handles.last.open_child(snapshot.fetch("snapshot_id"), create: false)
      actual = handles.reverse.map(&:identity)
      raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory" unless actual == snapshot.fetch("directory_binding")
      yield handles.last
    rescue RuntimePublisher::Native::UnsupportedPlatformError, SystemCallError, ArgumentError
      raise VerifiedStateSnapshotError, "snapshot root or ancestor is not the published directory"
    ensure
      handles&.reverse_each(&:close)
    end

    def after_snapshot_bind!; end

    def read_bound_file!(directory, name)
      file = RuntimePublisher::Native.open_read_at(directory.descriptor, name)
      begin
        bytes = file.read
        raise VerifiedStateSnapshotError, "snapshot record is not a regular file" unless bytes.is_a?(String)
        bytes
      ensure
        file.close unless file.closed?
      end
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR
      raise VerifiedStateSnapshotError, "snapshot record is not a regular file"
    end

    def bound_manifest!(directory, expected)
      admitted = {}
      manifest = expected.map do |entry|
        components = entry.fetch("name").split(File::SEPARATOR)
        parent = directory
        opened = []
        components[0...-1].each do |component|
          child = parent.open_child(component, create: false)
          opened << child
          parent = child
        end
        bytes = read_bound_file!(parent, components.last)
        reject_state_name!(entry.fetch("name"))
        reject_state_bytes!(bytes, name: entry.fetch("name"))
        admitted[entry.fetch("name")] = bytes
        { "name" => entry.fetch("name"), "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
      ensure
        opened&.reverse_each(&:close)
      end.sort_by { |entry| entry.fetch("name") }
      validate_candidate_state_image!(admitted)
      manifest
    rescue Errno::ELOOP, Errno::ENOTDIR
      raise VerifiedStateSnapshotError, "runtime state contains symlink or device"
    end
  end
end
