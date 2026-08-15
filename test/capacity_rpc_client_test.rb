# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CapacityRpcClientTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SECRET = "test-only-signing-input"

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
    @directory = Dir.mktmpdir("capacity-rpc-client-")
    @argv_path = File.join(@directory, "argv.json")
    @stdin_path = File.join(@directory, "stdin.json")
    @environment_path = File.join(@directory, "environment.json")
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

  def test_sends_a_canonical_server_info_request_to_the_fixed_isolated_target
    with_fake_docker("success") do
      result = client.call("server_info")

      assert_equal({ "info" => { "server_state" => "full" } }, result)
      assert_equal expected_argv, JSON.parse(File.binread(@argv_path))
      assert_fixed_python_transport(JSON.parse(File.binread(@argv_path)))
      assert_equal(
        { "method" => "server_info", "params" => [{ "api_version" => 2 }] },
        JSON.parse(File.binread(@stdin_path))
      )
    end
  end

  def test_rejects_unsupported_commands_before_launching_docker
    error = assert_raises(XrplReserveStudy::CapacityRpcError) do
      client.call("sign_for")
    end

    assert_match(/not allowed/, error.message)
    refute File.exist?(@argv_path)
  end

  def test_allows_only_the_two_new_read_only_ledger_commands_in_addition_to_existing_commands
    %w[ledger ledger_data].each do |command|
      with_fake_docker("success") do
        client.call(command)
        assert_equal command, JSON.parse(File.binread(@stdin_path)).fetch("method")
      end
    end

    error = assert_raises(XrplReserveStudy::CapacityRpcError) { client.call("ledger_closed") }
    assert_match(/not allowed/, error.message)
  end

  def test_parameters_cannot_change_the_fixed_endpoint_or_compose_identity
    parameters = {
      "account" => "rExample",
      "endpoint" => "https://mainnet.example",
      "compose_file" => "/tmp/other-compose.yml",
      "service" => "other-container"
    }

    with_fake_docker("success") do
      client.call("account_info", parameters)

      assert_equal expected_argv, JSON.parse(File.binread(@argv_path))
      request = JSON.parse(File.binread(@stdin_path))
      assert_equal parameters, request.fetch("params").first.slice(*parameters.keys)
      assert_equal 2, request.fetch("params").first.fetch("api_version")
    end
  end

  def test_places_a_signing_secret_only_in_the_child_standard_input_json
    with_fake_docker("success") do
      client.call("sign", { "tx_json" => { "TransactionType" => "Payment" } }, secret: SECRET)

      argv = JSON.parse(File.binread(@argv_path))
      argv_text = argv.join("\n")
      request = JSON.parse(File.binread(@stdin_path))
      assert_fixed_python_transport(argv)
      refute_includes argv_text, SECRET
      refute_includes argv_text, "TransactionType"
      refute_includes JSON.parse(File.binread(@environment_path)).values.join("\n"), SECRET
      refute_includes JSON.parse(File.binread(@environment_path)).values.join("\n"), "TransactionType"
      assert_equal SECRET, request.dig("params", 0, "secret")
      assert_equal 2, request.dig("params", 0, "api_version")
    end
  end

  def test_docker_and_compose_target_selection_environment_is_not_inherited
    target_selection = {
      "DOCKER_HOST" => "tcp://remote.example:2376",
      "DOCKER_CONTEXT" => "remote-context",
      "DOCKER_CONFIG" => "/tmp/remote-docker-config",
      "DOCKER_TLS_VERIFY" => "1",
      "COMPOSE_FILE" => "/tmp/remote-compose.yml",
      "COMPOSE_PROJECT_NAME" => "remote-project"
    }

    with_environment(target_selection) do
      with_fake_docker("success") do
        client.call("sign", { "tx_json" => { "TransactionType" => "Payment" } }, secret: SECRET)
      end
    end

    environment = JSON.parse(File.binread(@environment_path))
    target_selection.each_key { |name| refute environment.key?(name), "child inherited #{name}" }
  end

  def test_signing_failures_do_not_expose_the_secret_or_raw_request_body
    with_fake_docker("secret_failure") do
      error = assert_raises(XrplReserveStudy::CapacityRpcError) do
        client.call("sign", { "tx_json" => { "Memo" => "private-payload" } }, secret: SECRET)
      end

      refute_includes error.message, SECRET
      refute_includes error.message, "private-payload"
      refute_includes error.message, "tx_json"
      assert_equal "capacity RPC request failed", error.message
    end
  end

  def test_rejects_malformed_json_with_a_controlled_error
    assert_controlled_failure("malformed_json")
  end

  def test_rejects_non_success_rpc_envelopes_with_a_controlled_error
    assert_controlled_failure("rpc_error")
  end

  def test_rejects_a_non_success_top_level_status_with_a_controlled_error
    assert_controlled_failure("top_level_status_error")
  end

  def test_rejects_pending_and_invalid_top_level_statuses
    assert_controlled_failure("top_level_status_pending")
    assert_controlled_failure("top_level_status_invalid")
  end

  def test_rejects_pending_and_invalid_result_statuses
    assert_controlled_failure("result_status_pending")
    assert_controlled_failure("result_status_invalid")
  end

  def test_rejects_nonzero_exit_with_a_controlled_error
    assert_controlled_failure("nonzero")
  end

  def test_rejects_stdout_and_stderr_larger_than_one_mebibyte
    assert_controlled_failure("stdout_overflow")
    assert_controlled_failure("stderr_overflow")
  end

  def test_timeout_terminates_the_entire_child_process_group
    with_fake_docker("timeout_with_child") do
      assert_controlled_failure(nil)
      assert_recorded_processes_dead
    end
  end

  def test_deadline_covers_process_exit_after_the_child_closes_all_output_streams
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_fake_docker("closed_fds_then_sleep") do
      assert_controlled_failure(nil)
      assert_recorded_processes_dead
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :>=, 9
    assert_operator elapsed, :<, 11
  end

  def test_output_overflow_terminates_the_entire_child_process_group
    with_fake_docker("overflow_with_child") do
      assert_controlled_failure(nil)
      assert_recorded_processes_dead
    end
  end

  def test_term_ignoring_descendant_is_killed_after_its_leader_exits
    with_fake_docker("term_ignoring_descendant") do
      assert_controlled_failure(nil)
      assert_recorded_processes_dead
    end
  end

  # Break caught: an unbounded wait after KILL, including the ESRCH cleanup path.
  def test_cleanup_joins_are_bounded_by_the_original_deadline
    wait = StubbornWait.new
    subject = client
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1

    Process.stub(:kill, ->(*_arguments) { raise Errno::ESRCH }) do
      subject.__send__(:terminate_process_group, wait, deadline)
    end

    refute_empty wait.joins
    assert wait.joins.all? { |timeout| timeout.is_a?(Numeric) && timeout >= 0 && timeout <= 1 }
  end

  private

  def client
    XrplReserveStudy::CapacityRpcClient.new
  end

  def expected_argv
    canonical_root = File.realpath(ROOT)
    project = "xrpl-reserve-capacity-#{Digest::SHA256.hexdigest(canonical_root)[0, 12]}"
    [
      "compose", "--project-name", project, "--file", File.join(canonical_root, "capacity", "compose.yml"),
      "exec", "--no-TTY", "rippled", "python3", "-I", "-c", expected_python_script
    ]
  end

  def expected_python_script
    <<~PYTHON
      import http.client
      import sys

      body = sys.stdin.buffer.read()
      connection = http.client.HTTPConnection("127.0.0.1", 5005, timeout=10)
      try:
          connection.request("POST", "/", body=body, headers={"Content-Type": "application/json"})
          response = connection.getresponse()
          while True:
              chunk = response.read(16_384)
              if not chunk:
                  break
              sys.stdout.buffer.write(chunk)
              sys.stdout.buffer.flush()
          if not 200 <= response.status < 300:
              raise SystemExit(1)
      finally:
          connection.close()
    PYTHON
  end

  def assert_fixed_python_transport(argv)
    assert_equal "python3", argv.fetch(-4)
    assert_equal "-I", argv.fetch(-3)
    assert_equal "-c", argv.fetch(-2)
    script = argv.fetch(-1)
    refute_includes argv, "wget"
    refute_includes argv, "--post-file=-"
    assert_includes script, 'HTTPConnection("127.0.0.1", 5005, timeout=10)'
    assert_includes script, 'connection.request("POST", "/", body=body, headers={"Content-Type": "application/json"})'
    assert_includes script, "body = sys.stdin.buffer.read()"
    assert_includes script, "chunk = response.read(16_384)"
    assert_includes script, "sys.stdout.buffer.flush()"
    refute_includes script, "response.read()"
    refute_match(/sys\.argv|os\.environ|open\(/, script)
  end

  def assert_controlled_failure(mode)
    return with_fake_docker(mode) { assert_controlled_failure(nil) } if mode

    error = assert_raises(XrplReserveStudy::CapacityRpcError) { client.call("server_info") }
    assert_equal "capacity RPC request failed", error.message
    refute_includes error.message, "server_info"
    refute_includes error.message, "api_version"
  end

  def with_fake_docker(mode)
    original_mode = File.exist?(@mode_path) ? File.binread(@mode_path) : nil
    File.binwrite(@mode_path, mode) if mode
    yield
  ensure
    if original_mode
      File.binwrite(@mode_path, original_mode)
    else
      File.unlink(@mode_path) if File.exist?(@mode_path)
    end
  end

  def with_environment(values)
    previous = values.each_with_object({}) { |(name, _), result| result[name] = ENV[name] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each do |name, value|
      value ? ENV[name] = value : ENV.delete(name)
    end
  end

  def write_fake_docker
    script = <<~RUBY
      #!#{RbConfig.ruby}
      require "json"

      require "rbconfig"

      directory = File.dirname(__FILE__)
      argv_path = File.join(directory, "argv.json")
      stdin_path = File.join(directory, "stdin.json")
      environment_path = File.join(directory, "environment.json")
      pid_path = File.join(directory, "pids.json")
      mode = File.binread(File.join(directory, "mode"))
      File.binwrite(argv_path, JSON.generate(ARGV))
      body = STDIN.read
      File.binwrite(stdin_path, body)
      File.binwrite(environment_path, JSON.generate(ENV.to_h))

      def record_child(pid_path)
        child = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
        File.binwrite(pid_path, JSON.generate([Process.pid, child]))
      end

      def record_term_ignoring_child(pid_path)
        child = Process.spawn(RbConfig.ruby, "-e", 'trap("TERM") {}; STDOUT.close; STDERR.close; sleep 30')
        File.binwrite(pid_path, JSON.generate([Process.pid, child]))
      end

      case mode
      when "success"
        STDOUT.write(JSON.generate("result" => { "info" => { "server_state" => "full" } }))
      when "malformed_json"
        STDOUT.write("{")
      when "rpc_error"
        STDOUT.write(JSON.generate("error" => { "message" => "request rejected: \#{body}" }))
      when "top_level_status_error"
        STDOUT.write(JSON.generate("status" => "error", "result" => { "info" => { "server_state" => "full" } }))
      when "top_level_status_pending"
        STDOUT.write(JSON.generate("status" => "pending", "result" => { "info" => { "server_state" => "full" } }))
      when "top_level_status_invalid"
        STDOUT.write(JSON.generate("status" => "invalid", "result" => { "info" => { "server_state" => "full" } }))
      when "result_status_pending"
        STDOUT.write(JSON.generate("result" => { "status" => "pending", "info" => { "server_state" => "full" } }))
      when "result_status_invalid"
        STDOUT.write(JSON.generate("result" => { "status" => "invalid", "info" => { "server_state" => "full" } }))
      when "nonzero"
        STDERR.write("nonzero: \#{body}")
        exit 9
      when "secret_failure"
        STDOUT.write(body)
        STDERR.write("secret failure: \#{body}")
        exit 9
      when "stdout_overflow"
        STDOUT.write("x" * 1_048_577)
      when "stderr_overflow"
        STDERR.write("x" * 1_048_577)
      when "timeout_with_child"
        record_child(pid_path)
        sleep 30
      when "closed_fds_then_sleep"
        File.binwrite(pid_path, JSON.generate([Process.pid]))
        STDOUT.close
        STDERR.close
        sleep 12
      when "overflow_with_child"
        record_child(pid_path)
        STDOUT.write("x" * 1_048_577)
        sleep 30
      when "term_ignoring_descendant"
        record_term_ignoring_child(pid_path)
        exit 9
      else
        abort "unknown fake docker mode"
      end
    RUBY
    path = File.join(@directory, "docker")
    File.binwrite(path, script)
    FileUtils.chmod(0o700, path)
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
    flunk "child process group survived: #{pids.join(', ')}"
  end

  def stop_recorded_processes
    return unless File.exist?(@pid_path)

    JSON.parse(File.binread(@pid_path)).each do |pid|
      Process.kill("KILL", pid) if process_alive?(pid)
    rescue Errno::ESRCH
      nil
    end
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
end
