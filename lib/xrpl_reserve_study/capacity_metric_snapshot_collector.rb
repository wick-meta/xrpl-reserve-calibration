# frozen_string_literal: true

require "digest"
require "json"
require "open3"

module XrplReserveStudy
  class CapacityMetricSnapshotError < StudyError
    attr_reader :stage

    def initialize(stage = "unknown")
      @stage = stage
      super("capacity metric snapshot failed")
    end
  end

  class CapacityMetricSnapshotCollector
    TIMEOUT_SECONDS = 10
    MAX_OUTPUT_BYTES = 1_048_576
    MAX_PAGES = 1024
    MAX_STATE_ENTRIES = 1_000_000
    MAX_INTEGER = (2**63) - 1
    MAX_UINT32 = 4_294_967_295
    MAX_SAMPLE_SEQUENCE = 900
    MAX_ELAPSED_SECONDS = 3_600
    MAX_SAMPLE_BYTES = 560
    MEMORY_LIMIT_BYTES = 17_179_869_184
    ALLOCATED_LOGICAL_CPUS = 4
    HASH_PATTERN = /\A[A-F0-9]{64}\z/
    HEX_PATTERN = /\A[A-F0-9]*\z/
    CONTROLLED_ERROR = "capacity metric snapshot failed"
    STATS_KEYS = %w[
      database_bytes resident_memory_bytes memory_current_bytes memory_limit_bytes
      process_cpu_seconds allocated_logical_cpus free_disk_bytes disk_total_bytes
    ].freeze
    SAMPLE_KEYS = CapacityMetrics::Reducer::SAMPLE_KEYS
    PYTHON_STATS_SCRIPT = <<~PYTHON.freeze
      import json
      import os
      import stat

      def collect_database_bytes(os_module=os, stat_module=stat):
          database_bytes = 0
          visited_entries = 0
          directory_flags = os_module.O_RDONLY | os_module.O_DIRECTORY | os_module.O_NOFOLLOW
          pending = [os_module.open("/var/lib/xrpld/db", directory_flags)]
          try:
              while pending:
                  directory_fd = pending.pop()
                  try:
                      with os_module.scandir(directory_fd) as entries:
                          for entry in entries:
                              visited_entries += 1
                              if visited_entries > 100000:
                                  raise RuntimeError("database traversal limit")
                              metadata = os_module.stat(
                                  entry.name, dir_fd=directory_fd, follow_symlinks=False
                              )
                              if stat_module.S_ISDIR(metadata.st_mode):
                                  child_fd = os_module.open(
                                      entry.name, directory_flags, dir_fd=directory_fd
                                  )
                                  pending.append(child_fd)
                              elif stat_module.S_ISREG(metadata.st_mode):
                                  database_bytes += metadata.st_size
                  finally:
                      os_module.close(directory_fd)
          finally:
              for directory_fd in pending:
                  os_module.close(directory_fd)
          return database_bytes

      with open("/proc/1/stat", "r", encoding="ascii") as source:
          process_fields = source.read().rsplit(")", 1)[1].split()
      ticks = os.sysconf("SC_CLK_TCK")
      process_cpu_seconds = (int(process_fields[11]) + int(process_fields[12])) / ticks

      with open("/proc/1/status", "r", encoding="ascii") as source:
          rss_values = [line.split() for line in source if line.startswith("VmRSS:")]
      if len(rss_values) != 1 or len(rss_values[0]) != 3 or rss_values[0][2] != "kB":
          raise RuntimeError("invalid VmRSS")
      resident_memory_bytes = int(rss_values[0][1]) * 1024

      try:
          with open("/sys/fs/cgroup/memory.current", "r", encoding="ascii") as source:
              memory_current_bytes = int(source.read().strip())
          with open("/sys/fs/cgroup/memory.max", "r", encoding="ascii") as source:
              memory_limit_bytes = int(source.read().strip())
      except FileNotFoundError:
          with open("/sys/fs/cgroup/memory/memory.usage_in_bytes", "r", encoding="ascii") as source:
              memory_current_bytes = int(source.read().strip())
          with open("/sys/fs/cgroup/memory/memory.limit_in_bytes", "r", encoding="ascii") as source:
              memory_limit_bytes = int(source.read().strip())
      if memory_limit_bytes != 17179869184:
          raise RuntimeError("unexpected memory limit")

      database_bytes = collect_database_bytes()

      filesystem = os.statvfs("/var/lib/xrpld")
      free_disk_bytes = filesystem.f_bavail * filesystem.f_frsize
      disk_total_bytes = filesystem.f_blocks * filesystem.f_frsize
      result = {
          "database_bytes": database_bytes,
          "resident_memory_bytes": resident_memory_bytes,
          "memory_current_bytes": memory_current_bytes,
          "memory_limit_bytes": memory_limit_bytes,
          "process_cpu_seconds": process_cpu_seconds,
          "allocated_logical_cpus": 4,
          "free_disk_bytes": free_disk_bytes,
          "disk_total_bytes": disk_total_bytes,
      }
      print(json.dumps(result, separators=(",", ":")))
    PYTHON

    def initialize(client: CapacityRpcClient.new, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @client = client
      @monotonic_clock = monotonic_clock
      @project_dir = File.realpath(File.expand_path("../..", __dir__))
      digest = Digest::SHA256.hexdigest(@project_dir)[0, 12]
      @project_name = "xrpl-reserve-capacity-#{digest}"
      @compose_file = File.join(@project_dir, "capacity", "compose.yml")
    end

    def capture(phase:, sample_sequence:, run_started_monotonic:)
      validate_capture_arguments!(phase, sample_sequence, run_started_monotonic)
      @capture_stage = "validated-ledger"
      ledger = validated_ledger!
      @capture_stage = "ledger-data"
      ledger_state_bytes = ledger_state_bytes!(ledger.fetch("hash"), ledger.fetch("index"))
      @capture_stage = "runtime-metrics"
      runtime = runtime_stats!
      elapsed_seconds = monotonic_time - run_started_monotonic
      reject! unless bounded_numeric?(elapsed_seconds, MAX_ELAPSED_SECONDS)

      sample = {
        "schema_version" => "capacity-metric-sample-v1",
        "phase" => phase,
        "sample_sequence" => sample_sequence,
        "elapsed_seconds" => elapsed_seconds,
        "validated_ledger_index" => ledger.fetch("index"),
        "validated_ledger_hash" => ledger.fetch("hash"),
        "ledger_close_time" => ledger.fetch("close_time"),
        "ledger_state_bytes" => ledger_state_bytes
      }
      sample.merge!(runtime)
      reject! if JSON.generate(sample).bytesize > MAX_SAMPLE_BYTES
      deep_freeze(sample)
    rescue CapacityMetricSnapshotError
      raise
    rescue StandardError
      reject!(@capture_stage)
    ensure
      @capture_stage = nil
    end

    private

    def validated_ledger!
      response = @client.call("ledger", { "ledger_index" => "validated", "transactions" => false, "expand" => false })
      nested = response["ledger"] if response.is_a?(Hash)
      reject! unless response.is_a?(Hash) && response["validated"] == true && nested.is_a?(Hash)
      index = response["ledger_index"]
      hash = response["ledger_hash"]
      reject! unless bounded_integer?(index, MAX_UINT32, minimum: 1) && valid_hash?(hash)
      reject! unless nested["ledger_index"] == index && nested["ledger_hash"] == hash
      close_time = nested["close_time"]
      reject! unless bounded_integer?(close_time, MAX_UINT32)
      { "index" => index, "hash" => hash, "close_time" => close_time }
    end

    def ledger_state_bytes!(hash, index)
      marker = nil
      markers = {}
      entries = {}
      total = 0
      pages = 0
      loop do
        parameters = { "ledger_hash" => hash, "binary" => true, "limit" => 2048 }
        parameters["marker"] = marker unless marker.nil?
        response = @client.call("ledger_data", parameters)
        pages += 1
        reject! if pages > MAX_PAGES
        state, next_marker = validated_page!(response, hash, index)
        state.each do |item|
          state_index = item.fetch("index")
          reject! if entries.key?(state_index)
          reject! if entries.length >= MAX_STATE_ENTRIES
          entries[state_index] = true
          bytes = item.fetch("data").bytesize / 2
          reject! if total > MAX_INTEGER - bytes
          total += bytes
        end
        return total if next_marker.nil?

        reject! if pages >= MAX_PAGES

        marker_id = canonical_marker(next_marker)
        reject! if markers.key?(marker_id)
        markers[marker_id] = true
        marker = next_marker
      end
    end

    def validated_page!(response, hash, index)
      reject! unless response.is_a?(Hash)
      allowed_keys = %w[ledger_hash ledger_index state marker validated ledger status]
      reject! unless (response.keys - allowed_keys).empty?
      reject! unless response["ledger_hash"] == hash && response["ledger_index"] == index && response["state"].is_a?(Array)
      reject! if response.key?("status") && response["status"] != "success"
      reject! if response.key?("validated") && response["validated"] != true
      if response.key?("ledger")
        reject! unless valid_nested_ledger?(response["ledger"], hash, index)
      end
      response.fetch("state").each do |item|
        reject! unless item.is_a?(Hash) && item.keys.sort == %w[data index]
        reject! unless valid_hash?(item["index"])
        data = item["data"]
        reject! unless data.is_a?(String) && data.bytesize.even? && data.match?(HEX_PATTERN)
      end
      marker = response["marker"]
      reject! if response.key?("marker") && !valid_marker?(marker)
      [response.fetch("state"), marker]
    end

    def valid_nested_ledger?(value, hash, index)
      return false unless value.is_a?(Hash)

      identity = value["ledger_index"] == index && value["ledger_hash"] == hash
      serialized = value.keys.sort == %w[closed ledger_data] && value["closed"] == true &&
        value["ledger_data"].is_a?(String) && value["ledger_data"].bytesize.positive? &&
        value["ledger_data"].bytesize.even? && value["ledger_data"].match?(HEX_PATTERN)
      identity || serialized
    end

    def runtime_stats!
      stdout, stderr = run_stats_child
      reject! unless stderr.empty?
      parsed = JSON.parse(stdout)
      reject! unless parsed.is_a?(Hash) && parsed.keys.sort == STATS_KEYS.sort
      %w[database_bytes resident_memory_bytes memory_current_bytes free_disk_bytes disk_total_bytes].each do |name|
        reject! unless bounded_integer?(parsed[name], MAX_INTEGER)
      end
      reject! unless parsed["memory_limit_bytes"] == MEMORY_LIMIT_BYTES
      reject! unless parsed["memory_current_bytes"] <= MEMORY_LIMIT_BYTES
      reject! unless bounded_numeric?(parsed["process_cpu_seconds"], MAX_INTEGER)
      reject! unless parsed["allocated_logical_cpus"] == ALLOCATED_LOGICAL_CPUS
      reject! unless parsed["disk_total_bytes"].positive?
      reject! unless parsed["free_disk_bytes"] <= parsed["disk_total_bytes"]
      parsed
    end

    def stats_argv
      [
        "docker", "compose", "--project-name", @project_name, "--file", @compose_file,
        "exec", "--no-TTY", "rippled", "python3", "-I", "-c", PYTHON_STATS_SCRIPT
      ]
    end

    def run_stats_child
      stdin = stdout = stderr = wait_thread = nil
      deadline = monotonic_time + TIMEOUT_SECONDS
      stdin, stdout, stderr, wait_thread = Open3.popen3(
        { "PATH" => ENV.fetch("PATH") }, *stats_argv, pgroup: true, unsetenv_others: true
      )
      stdin.binmode
      stdin.close
      stdin = nil
      output = read_output(stdout, stderr, wait_thread, deadline)
      status = wait_for_exit(wait_thread, deadline)
      reject! unless status.success?
      output
    rescue CapacityMetricSnapshotError
      terminate_process_group(wait_thread, deadline) if wait_thread
      raise
    rescue StandardError
      terminate_process_group(wait_thread, deadline) if wait_thread
      reject!
    ensure
      stdin.close if stdin && !stdin.closed?
      stdout.close if stdout && !stdout.closed?
      stderr.close if stderr && !stderr.closed?
    end

    def read_output(stdout, stderr, wait_thread, deadline)
      outputs = { stdout => +"", stderr => +"" }
      streams = outputs.keys.to_h { |stream| [stream, true] }
      until streams.empty?
        remaining = deadline - monotonic_time
        if remaining <= 0
          terminate_process_group(wait_thread, deadline)
          reject!
        end
        readable, = IO.select(streams.keys, nil, nil, remaining)
        readable.each do |stream|
          loop do
            chunk = stream.read_nonblock(16_384, exception: false)
            case chunk
            when :wait_readable then break
            when nil then streams.delete(stream); break
            else
              captured = outputs.fetch(stream)
              if captured.bytesize + chunk.bytesize > MAX_OUTPUT_BYTES
                terminate_process_group(wait_thread, deadline)
                reject!
              end
              captured << chunk
            end
          end
        end
      end
      [outputs.fetch(stdout), outputs.fetch(stderr)]
    end

    def wait_for_exit(wait_thread, deadline)
      remaining = deadline - monotonic_time
      if remaining <= 0 || !wait_thread.join(remaining)
        terminate_process_group(wait_thread, deadline)
        reject!
      end
      wait_thread.value
    end

    def terminate_process_group(wait_thread, deadline)
      return unless wait_thread
      pid = wait_thread.pid
      Process.kill("TERM", -pid)
      wait_thread.join([0.2, remaining_cleanup_time(deadline)].min)
      Process.kill("KILL", -pid)
      wait_thread.join(remaining_cleanup_time(deadline)) if wait_thread.alive?
    rescue Errno::ESRCH
      wait_thread.join(remaining_cleanup_time(deadline)) if wait_thread&.alive?
    end

    def remaining_cleanup_time(deadline)
      remaining = deadline - monotonic_time
      remaining.positive? ? remaining : 0
    end

    def validate_capture_arguments!(phase, sequence, started)
      reject! unless %w[post-warmup measurement].include?(phase)
      reject! unless bounded_integer?(sequence, MAX_SAMPLE_SEQUENCE) && bounded_numeric?(started, MAX_INTEGER)
    end

    def valid_hash?(value)
      value.is_a?(String) && value.match?(HASH_PATTERN)
    end

    def valid_marker?(value)
      value.is_a?(String) || value.is_a?(Array) || value.is_a?(Hash)
    end

    def canonical_marker(value)
      JSON.generate(canonical_value(value))
    rescue JSON::GeneratorError
      reject!
    end

    def canonical_value(value)
      case value
      when Hash then value.each_with_object({}) { |(key, nested), result| result[String(key)] = canonical_value(nested) }.sort.to_h
      when Array then value.map { |nested| canonical_value(nested) }
      else value
      end
    end

    def monotonic_time
      value = @monotonic_clock.call
      reject! unless bounded_numeric?(value, MAX_INTEGER)
      value
    end

    def finite_nonnegative_numeric?(value)
      (value.instance_of?(Integer) || value.instance_of?(Float)) && value.finite? && value >= 0
    rescue NoMethodError
      false
    end

    def nonnegative_integer?(value)
      value.instance_of?(Integer) && value >= 0
    end

    def positive_integer?(value)
      value.instance_of?(Integer) && value.positive?
    end

    def bounded_integer?(value, maximum, minimum: 0)
      value.instance_of?(Integer) && value.between?(minimum, maximum)
    end

    def bounded_numeric?(value, maximum)
      (value.instance_of?(Integer) || value.instance_of?(Float)) && value.finite? &&
        value.between?(0, maximum)
    rescue NoMethodError
      false
    end

    def reject!(stage = @capture_stage)
      raise CapacityMetricSnapshotError.new(stage || "unknown")
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
