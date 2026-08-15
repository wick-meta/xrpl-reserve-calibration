# frozen_string_literal: true

require "digest"
require "json"
require "open3"

module XrplReserveStudy
  class CapacityRpcError < StudyError; end

  class CapacityRpcClient
    TIMEOUT_SECONDS = 10
    MAX_OUTPUT_BYTES = 1_048_576
    SERVICE = "rippled"
    PYTHON_RPC_SCRIPT = <<~PYTHON.freeze
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
    ALLOWED_COMMANDS = %w[server_info account_info sign submit ledger_accept tx ledger ledger_data feature].freeze
    CONTROLLED_ERROR = "capacity RPC request failed"

    def initialize
      @project_dir = File.realpath(File.expand_path("../..", __dir__))
      digest = Digest::SHA256.hexdigest(@project_dir)[0, 12]
      @project_name = "xrpl-reserve-capacity-#{digest}"
      @compose_file = File.join(@project_dir, "capacity", "compose.yml")
    end

    def call(command, parameters = {}, secret: nil)
      request_body = stdout = stderr = redacted = nil
      command = String(command)
      raise CapacityRpcError, "capacity RPC command is not allowed" unless ALLOWED_COMMANDS.include?(command)
      raise CapacityRpcError, CONTROLLED_ERROR unless parameters.is_a?(Hash)

      reject_parameter_secret!(parameters)
      request_parameters = parameters.merge("api_version" => 2)
      request_parameters["secret"] = String(secret) unless secret.nil?
      request_body = JSON.generate(canonical_value("method" => command, "params" => [request_parameters]))

      stdout, stderr = run_child(request_body)
      redacted = redact_secret(stdout, secret)
      parsed = JSON.parse(redacted)
      result = parsed.is_a?(Hash) ? parsed["result"] : nil
      unless successful_response?(parsed, result)
        raise CapacityRpcError, CONTROLLED_ERROR
      end

      result
    rescue CapacityRpcError
      raise
    rescue StandardError
      raise CapacityRpcError, CONTROLLED_ERROR
    ensure
      erase_transient_string!(request_body)
      erase_transient_string!(stdout)
      erase_transient_string!(stderr)
      erase_transient_string!(redacted)
    end

    private

    def command_argv
      [
        "docker", "compose", "--project-name", @project_name, "--file", @compose_file,
        "exec", "--no-TTY", SERVICE, "python3", "-I", "-c", PYTHON_RPC_SCRIPT
      ]
    end

    def run_child(request_body)
      stdin = stdout = stderr = wait_thread = output = nil
      deadline = monotonic_time + TIMEOUT_SECONDS
      stdin, stdout, stderr, wait_thread = Open3.popen3(
        child_environment, *command_argv, pgroup: true, unsetenv_others: true
      )
      stdin.binmode
      output = communicate(stdin, stdout, stderr, wait_thread, request_body, deadline)
      stdin = nil
      status = wait_for_exit(wait_thread, deadline)
      unless status.success?
        terminate_process_group(wait_thread, deadline)
        raise CapacityRpcError, CONTROLLED_ERROR
      end

      output
    rescue CapacityRpcError
      output&.each { |value| erase_transient_string!(value) }
      terminate_process_group(wait_thread, deadline) if wait_thread
      raise
    rescue StandardError
      output&.each { |value| erase_transient_string!(value) }
      terminate_process_group(wait_thread, deadline) if wait_thread
      raise CapacityRpcError, CONTROLLED_ERROR
    ensure
      stdin.close if stdin && !stdin.closed?
      stdout.close if stdout && !stdout.closed?
      stderr.close if stderr && !stderr.closed?
    end

    def communicate(stdin, stdout, stderr, wait_thread, request_body, deadline)
      outputs = { stdout => +"", stderr => +"" }
      completed = false
      streams = outputs.keys.to_h { |stream| [stream, true] }
      input_offset = 0

      until streams.empty? && stdin.nil?
        remaining = deadline - monotonic_time
        if remaining <= 0
          terminate_process_group(wait_thread, deadline)
          raise CapacityRpcError, CONTROLLED_ERROR
        end

        readable, writable = IO.select(streams.keys, stdin ? [stdin] : [], nil, remaining)

        if stdin && writable&.include?(stdin)
          written = stdin.write_nonblock(request_body.byteslice(input_offset..), exception: false)
          unless written == :wait_writable
            input_offset += written
            if input_offset == request_body.bytesize
              stdin.close
              stdin = nil
            end
          end
        end

        next unless readable

        readable.each do |stream|
          loop do
            chunk = stream.read_nonblock(16_384, exception: false)
            case chunk
            when :wait_readable
              break
            when nil
              streams.delete(stream)
              break
            else
              captured = outputs.fetch(stream)
              if captured.bytesize + chunk.bytesize > MAX_OUTPUT_BYTES
                terminate_process_group(wait_thread, deadline)
                raise CapacityRpcError, CONTROLLED_ERROR
              end
              captured << chunk
            end
          end
        end
      end

      completed = true
      [outputs.fetch(stdout), outputs.fetch(stderr)]
    ensure
      outputs&.each_value { |value| erase_transient_string!(value) } unless completed
    end

    def terminate_process_group(wait_thread, deadline)
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

    def child_environment
      { "PATH" => ENV.fetch("PATH") }
    end

    def wait_for_exit(wait_thread, deadline)
      remaining = deadline - monotonic_time
      if remaining <= 0 || !wait_thread.join(remaining)
        terminate_process_group(wait_thread, deadline)
        raise CapacityRpcError, CONTROLLED_ERROR
      end

      wait_thread.value
    end

    def successful_response?(parsed, result)
      return false unless result.is_a?(Hash)
      return false if parsed.key?("error") || result.key?("error")

      [parsed, result].all? { |envelope| !envelope.key?("status") || envelope["status"] == "success" }
    end

    def reject_parameter_secret!(value)
      case value
      when Hash
        value.each do |key, nested|
          raise CapacityRpcError, CONTROLLED_ERROR if String(key) == "secret"

          reject_parameter_secret!(nested)
        end
      when Array
        value.each { |nested| reject_parameter_secret!(nested) }
      end
    end

    def canonical_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[String(key)] = canonical_value(nested)
        end.sort.to_h
      when Array
        value.map { |nested| canonical_value(nested) }
      else
        value
      end
    end

    def redact_secret(value, secret)
      return value if secret.nil?

      value.gsub(String(secret), "[REDACTED]")
    end

    def erase_transient_string!(value)
      return unless value.is_a?(String) && !value.frozen?

      value.bytesize.times { |index| value.setbyte(index, 0) }
      value.clear
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
