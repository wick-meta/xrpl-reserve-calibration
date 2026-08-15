# frozen_string_literal: true

require "json"
require "open3"

module XrplReserveStudy
  class CapacityEnvironmentProbeError < StudyError; end

  class CapacityEnvironmentProbe
    TIMEOUT_SECONDS = 10
    MAX_OUTPUT_BYTES = 1_048_576
    CONTROLLED_ERROR = "capacity environment probe failed"
    IMAGE_DIGEST = "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70"
    HOST_KEYS = %w[docker_server_version host_architecture host_operating_system host_logical_cpus host_memory_bytes].freeze
    ENVIRONMENT_KEYS = (HOST_KEYS + %w[candidate_image_digest candidate_image_architecture native_architecture_eligible]).freeze
    HOST_FORMAT = [
      '{"docker_server_version":{{json .ServerVersion}},',
      '"host_architecture":{{if or (eq .Architecture "amd64") (eq .Architecture "x86_64")}}"amd64"',
      '{{else if or (eq .Architecture "arm64") (eq .Architecture "aarch64")}}"arm64"{{else}}"unsupported"{{end}},',
      '"host_operating_system":{{if eq .OperatingSystem "Docker Desktop"}}"docker-desktop"',
      '{{else if eq .OSType "linux"}}"linux"{{else}}"unsupported"{{end}},',
      '"host_logical_cpus":{{json .NCPU}},"host_memory_bytes":{{json .MemTotal}}}'
    ].join.freeze
    IMAGE_FORMAT = [
      '{"candidate_image_architecture":{{if or (eq .Architecture "amd64") (eq .Architecture "x86_64")}}"amd64"',
      '{{else if or (eq .Architecture "arm64") (eq .Architecture "aarch64")}}"arm64"{{else}}"unsupported"{{end}}}'
    ].join.freeze

    class CommandRunner
      def initialize(monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @monotonic_clock = monotonic_clock
      end

      def call(argv)
        reject! unless argv.is_a?(Array) && !argv.empty? && argv.all? { |item| item.is_a?(String) }
        stdin = stdout = stderr = wait_thread = nil
        deadline = monotonic_time + TIMEOUT_SECONDS
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          { "PATH" => ENV.fetch("PATH") }, *argv, pgroup: true, unsetenv_others: true
        )
        stdin.close
        stdin = nil
        outputs = read_output(stdout, stderr, wait_thread, deadline)
        status = wait_for_exit(wait_thread, deadline)
        reject! unless status.success? && outputs.fetch(stderr).empty?
        outputs.fetch(stdout)
      rescue CapacityEnvironmentProbeError
        terminate_process_group(wait_thread, deadline)
        raise
      rescue StandardError
        terminate_process_group(wait_thread, deadline)
        reject!
      ensure
        stdin.close if stdin && !stdin.closed?
        stdout.close if stdout && !stdout.closed?
        stderr.close if stderr && !stderr.closed?
      end

      private

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
          reject! unless readable
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
        outputs
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
        Process.kill("TERM", -wait_thread.pid)
        bounded_join(wait_thread, deadline, 0.2)
        if wait_thread.alive?
          Process.kill("KILL", -wait_thread.pid)
          bounded_join(wait_thread, deadline, 0.05)
        end
      rescue Errno::ESRCH, Errno::EPERM
        bounded_join(wait_thread, deadline, 0.05) if wait_thread&.alive?
      end

      def bounded_join(wait_thread, deadline, maximum)
        remaining = deadline ? deadline - monotonic_time : 0
        wait_thread.join([remaining, maximum].min) if remaining.positive?
      end

      def monotonic_time
        value = @monotonic_clock.call
        reject! unless value.is_a?(Numeric) && value.finite? && value >= 0
        value
      rescue NoMethodError
        reject!
      end

      def reject!
        raise CapacityEnvironmentProbeError, CONTROLLED_ERROR
      end
    end

    def initialize(command_runner: CommandRunner.new)
      @command_runner = command_runner
    end

    def capture
      host = parse_object!(@command_runner.call(["docker", "info", "--format", HOST_FORMAT]), HOST_KEYS)
      image = parse_object!(
        @command_runner.call(["docker", "image", "inspect", "--format", IMAGE_FORMAT, IMAGE_DIGEST]),
        %w[candidate_image_architecture]
      )
      validate_host!(host)
      validate_architecture!(image.fetch("candidate_image_architecture"))
      result = host.merge(
        "candidate_image_digest" => IMAGE_DIGEST,
        "candidate_image_architecture" => image.fetch("candidate_image_architecture"),
        "native_architecture_eligible" => host.fetch("host_architecture") == image.fetch("candidate_image_architecture")
      )
      reject! unless result.keys.sort == ENVIRONMENT_KEYS.sort
      deep_freeze(result)
    rescue CapacityEnvironmentProbeError
      raise
    rescue StandardError
      reject!
    end

    private

    def parse_object!(bytes, keys)
      reject! unless bytes.is_a?(String) && bytes.bytesize <= MAX_OUTPUT_BYTES
      parsed = JSON.parse(bytes)
      reject! unless parsed.is_a?(Hash) && parsed.keys.sort == keys.sort
      parsed
    rescue JSON::ParserError
      reject!
    end

    def validate_host!(host)
      version = host.fetch("docker_server_version")
      reject! unless version.is_a?(String) && version.match?(/\A[0-9A-Za-z.+-]{1,64}\z/)
      validate_architecture!(host.fetch("host_architecture"))
      reject! unless %w[linux docker-desktop].include?(host.fetch("host_operating_system"))
      reject! unless positive_integer?(host.fetch("host_logical_cpus"))
      reject! unless positive_integer?(host.fetch("host_memory_bytes"))
    end

    def validate_architecture!(value)
      reject! unless %w[amd64 arm64].include?(value)
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive? && value <= (2**63) - 1
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array then value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end

    def reject!
      raise CapacityEnvironmentProbeError, CONTROLLED_ERROR
    end
  end
end
