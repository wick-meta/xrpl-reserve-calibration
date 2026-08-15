# frozen_string_literal: true

require "fileutils"
require "base64"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CapacityMetricSnapshotCollectorTest < Minitest::Test
  HASH = "A" * 64
  OTHER_HASH = "B" * 64
  MEMORY_LIMIT = 17_179_869_184
  MAX_INTEGER = (2**63) - 1
  MAX_UINT32 = 4_294_967_295
  SAMPLE_KEYS = XrplReserveStudy::CapacityMetrics::Reducer::SAMPLE_KEYS

  class ScriptedClient
    attr_reader :calls

    def initialize(&responder)
      @responder = responder
      @calls = []
    end

    def call(command, parameters = {})
      @calls << [command, Marshal.load(Marshal.dump(parameters))]
      Marshal.load(Marshal.dump(@responder.call(command, parameters, @calls.length)))
    end
  end

  class StubbornWait
    attr_reader :joins

    def initialize
      @joins = []
    end

    def pid
      123
    end

    def join(timeout = :missing)
      @joins << timeout
      false
    end

    def alive?
      true
    end
  end

  def setup
    @directory = Dir.mktmpdir("capacity-metric-snapshot-")
    @argv_path = File.join(@directory, "argv.json")
    @stdin_path = File.join(@directory, "stdin")
    @pid_path = File.join(@directory, "pids.json")
    @mode_path = File.join(@directory, "mode")
    @original_path = ENV.fetch("PATH")
    write_fake_docker
    ENV["PATH"] = "#{@directory}:#{@original_path}"
  end

  def teardown
    ENV["PATH"] = @original_path
    stop_recorded_processes
    FileUtils.remove_entry(@directory)
  end

  # Break caught: omitting a page, changing its hash, or reordering the stats read.
  def test_captures_a_fixed_complete_read_only_snapshot_and_deeply_freezes_it
    client = scripted_client([page(marker: ["opaque"]), page(data: "0A0B", index_key: "D" * 64, marker: nil)])
    snapshot = collector(client).capture(phase: "post-warmup", sample_sequence: 7, run_started_monotonic: 90.0)

    assert_equal SAMPLE_KEYS.sort, snapshot.keys.sort
    assert_equal "capacity-metric-sample-v1", snapshot.fetch("schema_version")
    assert_equal "post-warmup", snapshot.fetch("phase")
    assert_equal 7, snapshot.fetch("sample_sequence")
    assert_equal 10.0, snapshot.fetch("elapsed_seconds")
    assert_equal 42, snapshot.fetch("validated_ledger_index")
    assert_equal HASH, snapshot.fetch("validated_ledger_hash")
    assert_equal 123, snapshot.fetch("ledger_close_time")
    assert_equal 4, snapshot.fetch("ledger_state_bytes")
    assert_equal 55, snapshot.fetch("database_bytes")
    assert_equal 4096, snapshot.fetch("resident_memory_bytes")
    assert_equal 8192, snapshot.fetch("memory_current_bytes")
    assert_equal MEMORY_LIMIT, snapshot.fetch("memory_limit_bytes")
    assert_equal 1.25, snapshot.fetch("process_cpu_seconds")
    assert_equal 4, snapshot.fetch("allocated_logical_cpus")
    assert_equal 30, snapshot.fetch("free_disk_bytes")
    assert_equal 100, snapshot.fetch("disk_total_bytes")
    assert_deeply_frozen(snapshot)
    assert_equal [
      ["ledger", { "ledger_index" => "validated", "transactions" => false, "expand" => false }],
      ["ledger_data", { "ledger_hash" => HASH, "binary" => true, "limit" => 2048 }],
      ["ledger_data", { "ledger_hash" => HASH, "binary" => true, "limit" => 2048, "marker" => ["opaque"] }]
    ], client.calls
    assert_equal expected_stats_argv, JSON.parse(File.binread(@argv_path))
    assert_equal "", File.binread(@stdin_path)
    refute_match(/persist|write|mkdir/, snapshot.inspect)
  end

  # Break caught: changing the opaque marker representation before the next page.
  def test_preserves_opaque_string_array_and_object_markers
    ["next", [1, "next"], { "cursor" => ["next"] }].each do |marker|
      client = scripted_client([page(marker: marker), page(index_key: "D" * 64, marker: nil)])
      collector(client).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99)
      assert_equal marker, client.calls.fetch(2).fetch(1).fetch("marker")
    end
  end

  # Break caught: rejecting either supported successful ledger_data metadata shape.
  def test_accepts_a_realistic_binary_ledger_data_response_with_validated_metadata
    [
      { "ledger_index" => 42, "ledger_hash" => HASH },
      { "closed" => true, "ledger_data" => "AABB" }
    ].each do |ledger|
      client = scripted_client([page(marker: nil, validated: true, status: "success", ledger: ledger)])
      snapshot = collector(client).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99)
      assert_equal 2, snapshot.fetch("ledger_state_bytes")
    end
  end

  # Break caught: accepting a drifted ledger binding or duplicate state object.
  def test_rejects_pagination_and_ledger_binding_adversaries_before_stats
    cases = {
      "repeated marker" => [page(marker: "again"), page(marker: "again")],
      "hash drift" => [page(marker: "next"), page(hash: OTHER_HASH, marker: nil)],
      "index drift" => [page(marker: "next"), page(index: 43, marker: nil)],
      "duplicate index" => [page(marker: "next"), page(index_key: "C" * 64, marker: nil)],
      "malformed hex" => [page(data: "AAZZ", marker: nil)],
      "odd data" => [page(data: "A", marker: nil)],
      "extra state key" => [page(extra_state_key: true, marker: nil)],
      "omitted final page" => [page(marker: "next")]
    }
    cases.each do |name, pages|
      client = scripted_client(pages)
      assert_snapshot_error(name) { collector(client).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99) }
      refute File.exist?(@argv_path), name
    end
  end

  # Break caught: relaxing response shape or validated-ledger matching checks.
  def test_rejects_malformed_ledger_and_page_shapes
    mutations = {
      "ledger top-level index" => ->(ledger, _pages) { ledger["ledger_index"] = 41 },
      "ledger top-level hash" => ->(ledger, _pages) { ledger["ledger_hash"] = OTHER_HASH },
      "ledger nested index" => ->(ledger, _pages) { ledger.fetch("ledger")["ledger_index"] = 41 },
      "ledger nested hash" => ->(ledger, _pages) { ledger.fetch("ledger")["ledger_hash"] = OTHER_HASH },
      "ledger close time" => ->(ledger, _pages) { ledger.fetch("ledger")["close_time"] = -1 },
      "missing state" => ->(_ledger, pages) { pages.fetch(0).delete("state") },
      "extra page key" => ->(_ledger, pages) { pages.fetch(0)["extra"] = true },
      "wrong marker" => ->(_ledger, pages) { pages.fetch(0)["marker"] = 1 },
      "unvalidated page" => ->(_ledger, pages) { pages.fetch(0)["validated"] = false },
      "nested page ledger drift" => ->(_ledger, pages) { pages.fetch(0)["ledger"] = { "ledger_index" => 41, "ledger_hash" => HASH } },
      "unclosed serialized ledger" => ->(_ledger, pages) { pages.fetch(0)["ledger"] = { "closed" => false, "ledger_data" => "AABB" } },
      "malformed serialized ledger" => ->(_ledger, pages) { pages.fetch(0)["ledger"] = { "closed" => true, "ledger_data" => "AAZZ" } }
    }
    mutations.each do |name, mutation|
      ledger = ledger_response
      pages = [page(marker: nil)]
      mutation.call(ledger, pages)
      client = scripted_client(pages, ledger: ledger)
      assert_snapshot_error(name) { collector(client).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99) }
    end
  end

  # Break caught: permitting unbounded page or state traversal.
  def test_rejects_more_than_1024_pages_and_more_than_one_million_entries
    pages = Array.new(1025) { |index| page(marker: index == 1024 ? nil : "m#{index}", index_key: format("%064X", index + 1)) }
    client = scripted_client(pages)
    assert_snapshot_error { collector(client).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99) }
    assert_equal 1024, client.calls.count { |command, _| command == "ledger_data" }

    million = Array.new(1_000_001) { |index| { "data" => "AA", "index" => format("%064X", index) } }
    assert_snapshot_error { collector(scripted_client([{ "ledger_hash" => HASH, "ledger_index" => 42, "state" => million }])).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99) }
  end

  # Break caught: accepting an invalid caller-supplied sample identity or elapsed time.
  def test_rejects_invalid_capture_arguments
    [
      ["other", 0, 99], ["measurement", -1, 99], ["measurement", 1.0, 99], ["measurement", 0, Float::NAN],
      ["measurement", 0, MAX_INTEGER + 1], ["measurement", 0, 101]
    ].each do |phase, sequence, started|
      assert_snapshot_error { collector(scripted_client([page(marker: nil)])).capture(phase: phase, sample_sequence: sequence, run_started_monotonic: started) }
    end

    huge_clock = XrplReserveStudy::CapacityMetricSnapshotCollector.new(
      client: scripted_client([page(marker: nil)]), monotonic_clock: -> { MAX_INTEGER + 1 }
    )
    assert_snapshot_error do
      huge_clock.capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99)
    end
  end

  # Break caught: accepting invalid fixed child metrics or exposing the child's output in an error.
  def test_rejects_child_failures_and_invalid_child_metrics_with_generic_errors
    %w[nonzero timeout_with_child stdout_overflow stderr_overflow malformed extra missing wrong_memory wrong_cpu negative nonfinite over_integer huge_integer all_max free_over_total symlink_error].each do |mode|
      with_fake_docker(mode) do
        error = assert_snapshot_error { collector(scripted_client([page(marker: nil)])).capture(phase: "measurement", sample_sequence: 0, run_started_monotonic: 99) }
        assert_equal "capacity metric snapshot failed", error.message
        refute_includes error.message, "child-sensitive-output"
        assert_recorded_processes_dead if %w[timeout_with_child stdout_overflow stderr_overflow].include?(mode)
      end
    end
  end

  def test_accepts_each_explicit_safe_numeric_maximum_and_rejects_uint32_overflow
    %w[max_database max_resident max_process max_disk].each do |mode|
      with_fake_docker(mode) do
        snapshot = collector(scripted_client([page(marker: nil)])).capture(
          phase: "measurement", sample_sequence: 0, run_started_monotonic: 99
        )
        assert_operator JSON.generate(snapshot).bytesize, :<=,
          XrplReserveStudy::CapacityMetricSnapshotCollector::MAX_SAMPLE_BYTES, mode
      end
    end

    ledger = ledger_response
    ledger["ledger_index"] = MAX_UINT32
    ledger["ledger_hash"] = HASH
    ledger.fetch("ledger")["ledger_index"] = MAX_UINT32
    ledger.fetch("ledger")["close_time"] = MAX_UINT32
    snapshot = collector(scripted_client([page(index: MAX_UINT32, marker: nil)], ledger: ledger)).capture(
      phase: "measurement", sample_sequence: 900, run_started_monotonic: 99
    )
    assert_equal MAX_UINT32, snapshot["validated_ledger_index"]
    assert_equal MAX_UINT32, snapshot["ledger_close_time"]

    ledger["ledger_index"] = MAX_UINT32 + 1
    ledger.fetch("ledger")["ledger_index"] = MAX_UINT32 + 1
    assert_snapshot_error do
      collector(scripted_client([page(index: MAX_UINT32 + 1, marker: nil)], ledger: ledger)).capture(
        phase: "measurement", sample_sequence: 900, run_started_monotonic: 99
      )
    end
  end

  # Break caught: an unbounded wait after KILL, including the ESRCH cleanup path.
  def test_cleanup_joins_are_bounded_by_the_original_deadline
    wait = StubbornWait.new
    subject = collector(scripted_client([page(marker: nil)]))

    Process.stub(:kill, ->(*_arguments) { raise Errno::ESRCH }) do
      subject.__send__(:terminate_process_group, wait, 110.0)
    end

    refute_empty wait.joins
    assert wait.joins.all? { |timeout| timeout.is_a?(Numeric) && timeout >= 0 && timeout <= 10 }
  end

  # Break caught: queueing a pathname which can be replaced by a symlink before traversal.
  def test_database_traversal_opens_children_relative_to_parent_without_following_swaps
    encoded = Base64.strict_encode64(XrplReserveStudy::CapacityMetricSnapshotCollector::PYTHON_STATS_SCRIPT)
    harness = <<~PYTHON
      import ast
      import base64
      import json
      import os
      import stat

      tree = ast.parse(base64.b64decode(#{encoded.inspect}).decode("utf-8"))
      functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "collect_database_bytes"]
      if len(functions) != 1:
          raise RuntimeError("missing database traversal function")
      namespace = {"os": os, "stat": stat}
      exec(compile(ast.Module(body=functions, type_ignores=[]), "<stats>", "exec"), namespace)

      class Entry:
          name = "nested"

      class Entries:
          def __enter__(self):
              return iter([Entry()])
          def __exit__(self, *_args):
              return False

      class Metadata:
          st_mode = 1
          st_size = 0

      class FakeStat:
          @staticmethod
          def S_ISDIR(mode):
              return mode == 1
          @staticmethod
          def S_ISREG(_mode):
              return False

      class FakeOs:
          O_RDONLY = 1
          O_DIRECTORY = 2
          O_NOFOLLOW = 4
          def __init__(self):
              self.calls = []
          def open(self, path, flags, dir_fd=None):
              self.calls.append(["open", path, flags, dir_fd])
              if path == "/var/lib/xrpld/db":
                  return 10
              if path == "nested" and dir_fd == 10 and flags & self.O_NOFOLLOW:
                  raise OSError("replacement symlink rejected")
              return 99
          def scandir(self, descriptor):
              self.calls.append(["scandir", descriptor])
              if descriptor != 10:
                  raise RuntimeError("escaped database root")
              return Entries()
          def stat(self, name, dir_fd=None, follow_symlinks=True):
              self.calls.append(["stat", name, dir_fd, follow_symlinks])
              return Metadata()
          def close(self, descriptor):
              self.calls.append(["close", descriptor])

      fake = FakeOs()
      blocked = False
      try:
          namespace["collect_database_bytes"](os_module=fake, stat_module=FakeStat)
      except OSError:
          blocked = True
      print(json.dumps({"blocked": blocked, "calls": fake.calls}, separators=(",", ":")))
    PYTHON
    stdout, stderr, status = Open3.capture3("python3", "-I", "-c", harness)

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal true, result.fetch("blocked")
    assert_includes result.fetch("calls"), ["open", "nested", 7, 10]
    refute result.fetch("calls").any? { |call| call.first == "scandir" && call.fetch(1) != 10 }
  end

  private

  def collector(client)
    XrplReserveStudy::CapacityMetricSnapshotCollector.new(client: client, monotonic_clock: -> { 100.0 })
  end

  def scripted_client(pages, ledger: ledger_response)
    ScriptedClient.new do |command, _parameters, count|
      count == 1 ? ledger : pages.fetch(count - 2)
    end
  end

  def ledger_response
    { "validated" => true, "ledger_index" => 42, "ledger_hash" => HASH, "ledger" => { "ledger_index" => 42, "ledger_hash" => HASH, "close_time" => 123 } }
  end

  def page(hash: HASH, index: 42, data: "AABB", index_key: "C" * 64, marker: nil, extra_state_key: false, validated: nil, ledger: nil, status: nil)
    state = { "data" => data, "index" => index_key }
    state["extra"] = true if extra_state_key
    result = { "ledger_hash" => hash, "ledger_index" => index, "state" => [state] }
    result["marker"] = marker unless marker.nil?
    result["validated"] = validated unless validated.nil?
    result["ledger"] = ledger unless ledger.nil?
    result["status"] = status unless status.nil?
    result
  end

  def assert_snapshot_error(message = nil, &block)
    error = assert_raises(XrplReserveStudy::CapacityMetricSnapshotError, message, &block)
    refute_empty error.message
    error
  end

  def expected_stats_argv
    root = File.realpath(File.expand_path("..", __dir__))
    project = "xrpl-reserve-capacity-#{Digest::SHA256.hexdigest(root)[0, 12]}"
    ["compose", "--project-name", project, "--file", File.join(root, "capacity", "compose.yml"), "exec", "--no-TTY", "rippled", "python3", "-I", "-c", XrplReserveStudy::CapacityMetricSnapshotCollector::PYTHON_STATS_SCRIPT]
  end

  def with_fake_docker(mode)
    File.binwrite(@mode_path, mode)
    yield
  ensure
    File.binwrite(@mode_path, "success")
  end

  def write_fake_docker
    script = <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      require "rbconfig"
      directory = File.dirname(__FILE__)
      File.binwrite(File.join(directory, "argv.json"), JSON.generate(ARGV))
      File.binwrite(File.join(directory, "stdin"), STDIN.read)
      mode = File.binread(File.join(directory, "mode"))
      def record_child(directory)
        child = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
        File.binwrite(File.join(directory, "pids.json"), JSON.generate([Process.pid, child]))
      end
      metrics = { "database_bytes" => 55, "resident_memory_bytes" => 4096, "memory_current_bytes" => 8192, "memory_limit_bytes" => #{MEMORY_LIMIT}, "process_cpu_seconds" => 1.25, "allocated_logical_cpus" => 4, "free_disk_bytes" => 30, "disk_total_bytes" => 100 }
      case mode
      when "success" then STDOUT.write(JSON.generate(metrics))
      when "nonzero" then STDERR.write("child-sensitive-output"); exit 9
      when "timeout_with_child" then record_child(directory); sleep 30
      when "stdout_overflow" then record_child(directory); STDOUT.write("x" * 1_048_577); sleep 30
      when "stderr_overflow" then record_child(directory); STDERR.write("x" * 1_048_577); sleep 30
      when "malformed" then STDOUT.write("{")
      when "extra" then STDOUT.write(JSON.generate(metrics.merge("extra" => 1)))
      when "missing" then STDOUT.write(JSON.generate(metrics.reject { |key, _| key == "database_bytes" }))
      when "wrong_memory" then STDOUT.write(JSON.generate(metrics.merge("memory_limit_bytes" => 1)))
      when "wrong_cpu" then STDOUT.write(JSON.generate(metrics.merge("allocated_logical_cpus" => 1)))
      when "negative" then STDOUT.write(JSON.generate(metrics.merge("database_bytes" => -1)))
      when "nonfinite" then STDOUT.write('{"database_bytes":55,"resident_memory_bytes":4096,"memory_current_bytes":8192,"memory_limit_bytes":17179869184,"process_cpu_seconds":1e9999,"allocated_logical_cpus":4,"free_disk_bytes":30,"disk_total_bytes":100}')
      when "max_database" then STDOUT.write(JSON.generate(metrics.merge("database_bytes" => #{MAX_INTEGER})))
      when "max_resident" then STDOUT.write(JSON.generate(metrics.merge("resident_memory_bytes" => #{MAX_INTEGER})))
      when "max_process" then STDOUT.write(JSON.generate(metrics.merge("process_cpu_seconds" => #{MAX_INTEGER})))
      when "max_disk" then STDOUT.write(JSON.generate(metrics.merge("free_disk_bytes" => #{MAX_INTEGER}, "disk_total_bytes" => #{MAX_INTEGER})))
      when "over_integer" then STDOUT.write(JSON.generate(metrics.merge("database_bytes" => #{MAX_INTEGER + 1})))
      when "huge_integer" then STDOUT.write(JSON.generate(metrics.merge("database_bytes" => 10**100000)))
      when "all_max" then STDOUT.write(JSON.generate(metrics.merge("database_bytes" => #{MAX_INTEGER}, "resident_memory_bytes" => #{MAX_INTEGER}, "process_cpu_seconds" => #{MAX_INTEGER}, "free_disk_bytes" => #{MAX_INTEGER}, "disk_total_bytes" => #{MAX_INTEGER})))
      when "free_over_total" then STDOUT.write(JSON.generate(metrics.merge("free_disk_bytes" => 101)))
      when "symlink_error" then STDERR.write("child-sensitive-output"); exit 8
      else abort "unknown mode"
      end
    RUBY
    File.binwrite(File.join(@directory, "docker"), script)
    FileUtils.chmod(0o700, File.join(@directory, "docker"))
    File.binwrite(@mode_path, "success")
  end

  def assert_recorded_processes_dead
    pids = JSON.parse(File.binread(@pid_path))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return if pids.all? { |pid| !process_alive?(pid) }
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    flunk "child process group survived"
  end

  def stop_recorded_processes
    return unless File.exist?(@pid_path)
    JSON.parse(File.binread(@pid_path)).each { |pid| Process.kill("KILL", pid) if process_alive?(pid) }
  rescue Errno::ESRCH
    nil
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    !zombie_process?(pid)
  rescue Errno::ESRCH
    false
  end

  def zombie_process?(pid)
    stat_path = "/proc/#{pid}/stat"
    return false unless File.exist?(stat_path)

    File.read(stat_path).rpartition(")").last.split.first == "Z"
  rescue Errno::ENOENT
    false
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash then value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array then value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
