# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module XrplReserveStudy
  class RunCloneManagerError < StudyError; end

  class RunCloneManager
    BINDING_KEYS = %w[candidate_image_digest study_sha256 distribution_sha256 config_sha256 source_sha256 ledger].freeze

    def initialize(verifier:, runtime:, runtime_root: RuntimePublisher::RUNTIME_ROOT)
      @verifier = verifier
      @runtime = runtime
      @runtime_root = File.expand_path(runtime_root)
    end

    def prepare(snapshot:, run:)
      @verifier.verify!(snapshot)
      clone_ancestry = ensure_clone_root!
      bindings = bindings!(snapshot, run)
      destination = File.join(clone_root, clone_name(snapshot, run))
      raise RunCloneManagerError, "clone destination already exists" if File.exist?(destination) || File.symlink?(destination)

      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      temporary = "#{destination}.tmp-#{Process.pid}-#{rand(1_000_000)}"
      FileUtils.mkdir_p(File.join(temporary, "state"), mode: 0o700)
      copy_state!(File.join(snapshot.fetch("path"), "state"), File.join(temporary, "state"), snapshot.fetch("files"))
      files = manifest!(File.join(temporary, "state"))
      record = {
        "schema_version" => "complete-reserves-run-clone-v1", "snapshot_id" => snapshot.fetch("snapshot_id"),
        "run_id" => run.fetch("run_id"), "repetition" => run.fetch("repetition"), "bindings" => bindings,
        "snapshot_sha256" => snapshot_digest(snapshot), "files" => files
      }
      File.binwrite(File.join(temporary, "clone.json"), JSON.generate(record) + "\n")
      raise RunCloneManagerError, "clone root changed during preparation" unless clone_ancestry == ensure_clone_root!
      publish_clone_directory!(temporary, destination)
      record.merge("path" => destination, "snapshot" => snapshot).freeze
    rescue RunCloneManagerError
      raise
    rescue StandardError => error
      raise RunCloneManagerError, "could not prepare run clone: #{error.message}"
    ensure
      FileUtils.rm_rf(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def start(clone:, run:)
      record = verify_clone!(clone)
      @verifier.verify!(clone.fetch("snapshot"))
      raise RunCloneManagerError, "clone does not match verified snapshot" unless
        record.fetch("snapshot_sha256") == snapshot_digest(clone.fetch("snapshot"))
      expected = run_bindings!(run)
      raise RunCloneManagerError, "run does not match clone bindings" unless record.fetch("bindings") == expected &&
        record.fetch("run_id") == run.fetch("run_id") && record.fetch("repetition") == run.fetch("repetition")
      raise RunCloneManagerError, "checkout clone runtime adapter is invalid" unless @runtime.respond_to?(:start_clone!)
      consume_clone!(clone.fetch("path"))
      @runtime.start_clone!(path: clone.fetch("path"), run: run)
    rescue RunCloneManagerError
      raise
    rescue StandardError => error
      raise RunCloneManagerError, "could not start run clone: #{error.message}"
    end

    private

    def bindings!(snapshot, run)
      run_bindings!(run)
      values = BINDING_KEYS.to_h { |key| [key, snapshot.fetch(key)] }
      raise RunCloneManagerError, "run does not match clone bindings" unless values.all? { |key, value| run[key] == value }
      values
    rescue KeyError
      raise RunCloneManagerError, "run does not match clone bindings"
    end

    def run_bindings!(run)
      valid = run.is_a?(Hash) && run["run_id"].is_a?(String) && run["run_id"].match?(/\A[a-z0-9-]+\z/) &&
        run["repetition"].is_a?(Integer) && run["repetition"].positive? && BINDING_KEYS.all? { |key| run.key?(key) }
      raise RunCloneManagerError, "invalid complete reserves clone run" unless valid
      BINDING_KEYS.to_h { |key| [key, run.fetch(key)] }
    end

    def verify_clone!(clone)
      valid = clone.is_a?(Hash) && clone["path"].is_a?(String) && clone["snapshot"].is_a?(Hash)
      raise RunCloneManagerError, "invalid run clone" unless valid
      reject_unsafe_clone_path!(clone.fetch("path"))
      stored = JSON.parse(File.binread(File.join(clone.fetch("path"), "clone.json")))
      valid_record = stored.is_a?(Hash) && stored.keys.sort == %w[bindings files repetition run_id schema_version snapshot_id snapshot_sha256] &&
        stored["schema_version"] == "complete-reserves-run-clone-v1" && stored["snapshot_id"].is_a?(String) &&
        stored["run_id"].is_a?(String) && stored["repetition"].is_a?(Integer) && sha?(stored["snapshot_sha256"])
      raise RunCloneManagerError, "invalid run clone" unless valid_record
      expected_path = File.join(clone_root, clone_name(stored, stored))
      raise RunCloneManagerError, "invalid run clone" unless clone.fetch("path") == expected_path
      expected = clone.reject { |key, _| %w[path snapshot].include?(key) }
      raise RunCloneManagerError, "clone record does not match image" unless stored == expected
      raise RunCloneManagerError, "clone state manifest does not match image" unless manifest!(File.join(clone.fetch("path"), "state")) == clone.fetch("files")
      stored
    rescue Errno::ENOENT, JSON::ParserError
      raise RunCloneManagerError, "clone image is incomplete"
    end

    def copy_state!(source, destination, expected)
      raise RunCloneManagerError, "snapshot state changed during clone" unless manifest!(source) == expected
      expected.each do |entry|
        input = File.join(source, entry.fetch("name"))
        output = File.join(destination, entry.fetch("name"))
        FileUtils.mkdir_p(File.dirname(output), mode: 0o700)
        FileUtils.copy_file(input, output, true)
      end
      raise RunCloneManagerError, "snapshot state changed during clone" unless manifest!(destination) == expected
    end

    def manifest!(root)
      root_stat = File.lstat(root)
      raise RunCloneManagerError, "clone state is incomplete" unless root_stat.directory?
      files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).map do |path|
        stat = File.lstat(path)
        next if [".", ".."].include?(File.basename(path)) || stat.directory?
        raise RunCloneManagerError, "clone state contains symlink or device" unless stat.file?
        relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
        raise RunCloneManagerError, "clone state contains unsafe path" unless safe_relative?(relative)
        { "name" => relative, "bytes" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest }
      end.compact
      raise RunCloneManagerError, "clone state is incomplete" if files.empty?
      files.sort_by { |entry| entry.fetch("name") }
    end

    def clone_root
      File.join(@runtime_root, "complete-reserves", "clones")
    end

    def ensure_clone_root!
      FileUtils.mkdir_p(clone_root, mode: 0o700)
      paths = []
      current = File.expand_path(clone_root)
      loop do
        stat = File.lstat(current)
        raise RunCloneManagerError, "clone root must not contain symlinks" if stat.symlink?
        paths << [current, stat.dev, stat.ino]
        break if current == @runtime_root
        parent = File.dirname(current)
        raise RunCloneManagerError, "clone root must not contain symlinks" if parent == current
        current = parent
      end
      paths.freeze
    rescue Errno::ENOENT
      raise RunCloneManagerError, "clone root must not contain symlinks"
    end

    def clone_name(snapshot, run)
      "#{snapshot.fetch("snapshot_id")}-#{run.fetch("run_id")}-n#{run.fetch("repetition")}"
    end

    def publish_clone_directory!(temporary, destination)
      parent = File.dirname(destination)
      raise RunCloneManagerError, "clone root must not contain symlinks" unless ensure_clone_root!
      parent_handle = RuntimePublisher::DirectoryHandle.open(parent)
      staging = parent_handle.open_child(File.basename(temporary), create: false)
      staging.close
      parent_handle.rename_noreplace(File.basename(temporary), File.basename(destination))
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise RunCloneManagerError, "clone destination already exists"
    rescue RuntimePublisher::Native::UnsupportedPlatformError, SystemCallError => error
      raise RunCloneManagerError, "could not publish run clone: #{error.message}"
    ensure
      parent_handle&.close
    end

    def snapshot_digest(snapshot)
      record = snapshot.reject { |key, _| key == "path" }.sort.to_h
      Digest::SHA256.hexdigest(JSON.generate(record))
    rescue StandardError
      raise RunCloneManagerError, "invalid verified snapshot"
    end

    def consume_clone!(path)
      lock = File.join(path, ".consumed")
      File.open(lock, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write("consumed\n") }
    rescue Errno::EEXIST, Errno::ELOOP
      raise RunCloneManagerError, "clone has already been consumed"
    rescue SystemCallError => error
      raise RunCloneManagerError, "could not consume run clone: #{error.message}"
    end

    def reject_unsafe_clone_path!(path)
      expected_root = File.expand_path(clone_root)
      raise RunCloneManagerError, "invalid run clone" unless path == File.expand_path(path) &&
        path.start_with?("#{expected_root}#{File::SEPARATOR}") && !path.split(File::SEPARATOR).include?("..")
      current = expected_root
      raise RunCloneManagerError, "invalid run clone" if File.symlink?(current)
      relative = path.delete_prefix("#{expected_root}#{File::SEPARATOR}")
      relative.split(File::SEPARATOR).each do |component|
        raise RunCloneManagerError, "invalid run clone" unless component.match?(/\A[a-z0-9-]+\z/)
        current = File.join(current, component)
        raise RunCloneManagerError, "invalid run clone" if File.symlink?(current)
      end
    end

    def safe_relative?(value)
      value.is_a?(String) && value.match?(/\A[^\/\0]+(?:\/[^\/\0]+)*\z/) && !value.split(File::SEPARATOR).include?("..")
    end

    def sha?(value)
      value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
    end
  end
end
