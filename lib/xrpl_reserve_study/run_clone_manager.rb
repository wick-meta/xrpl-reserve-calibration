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
        "run_id" => run.fetch("run_id"), "repetition" => run.fetch("repetition"), "bindings" => bindings, "files" => files
      }
      File.binwrite(File.join(temporary, "clone.json"), JSON.generate(record) + "\n")
      File.rename(temporary, destination)
      record.merge("path" => destination).freeze
    rescue RunCloneManagerError
      raise
    rescue StandardError => error
      raise RunCloneManagerError, "could not prepare run clone: #{error.message}"
    ensure
      FileUtils.rm_rf(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def start(clone:, run:)
      record = verify_clone!(clone)
      expected = run_bindings!(run)
      raise RunCloneManagerError, "run does not match clone bindings" unless record.fetch("bindings") == expected &&
        record.fetch("run_id") == run.fetch("run_id") && record.fetch("repetition") == run.fetch("repetition")
      raise RunCloneManagerError, "checkout clone runtime adapter is invalid" unless @runtime.respond_to?(:start_clone!)
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
      valid = clone.is_a?(Hash) && clone["path"].is_a?(String) && clone["path"].start_with?("#{clone_root}#{File::SEPARATOR}")
      raise RunCloneManagerError, "invalid run clone" unless valid
      stored = JSON.parse(File.binread(File.join(clone.fetch("path"), "clone.json")))
      expected = clone.reject { |key, _| key == "path" }
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
      raise RunCloneManagerError, "clone state is incomplete" unless File.directory?(root) && !File.symlink?(root)
      files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).map do |path|
        next if [".", ".."].include?(File.basename(path)) || File.directory?(path)
        stat = File.lstat(path)
        raise RunCloneManagerError, "clone state contains symlink or device" unless stat.file?
        relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
        raise RunCloneManagerError, "clone state contains unsafe path" unless relative.match?(/\A[^\/\0]+(?:\/[^\/\0]+)*\z/)
        { "name" => relative, "bytes" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest }
      end.compact
      raise RunCloneManagerError, "clone state is incomplete" if files.empty?
      files.sort_by { |entry| entry.fetch("name") }
    end

    def clone_root
      File.join(@runtime_root, "complete-reserves", "clones")
    end

    def clone_name(snapshot, run)
      "#{snapshot.fetch("snapshot_id")}-#{run.fetch("run_id")}-n#{run.fetch("repetition")}"
    end
  end
end
