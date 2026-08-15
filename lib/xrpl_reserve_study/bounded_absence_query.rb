# frozen_string_literal: true

require "open3"
require "thread"

module XrplReserveStudy
  class BoundedAbsenceQuery
    ABSENT = 0
    PRESENT = 1
    FAILED = 2
    TIMEOUT_SECONDS = 5
    READ_BYTES = 16_384
    POLL_SECONDS = 0.01
    CLEANUP_SECONDS = 0.2

    def self.exit_code(argv)
      new.call(argv)
    end

    def call(argv)
      return FAILED unless valid_argv?(argv)

      stdin = stdout = stderr = wait_thread = nil
      readers = []
      signal = Queue.new
      deadline = monotonic_time + TIMEOUT_SECONDS
      stdin, stdout, stderr, wait_thread = Open3.popen3(*argv, pgroup: true)
      stdin.close
      stdin = nil
      readers = [stdout, stderr].map do |stream|
        Thread.new do
          begin
            stream.readpartial(READ_BYTES)
            signal << :output
          rescue EOFError, IOError, Errno::EBADF
            nil
          end
        end
      end

      until wait_thread.join(POLL_SECONDS)
        return PRESENT unless signal.empty?
        return FAILED if monotonic_time >= deadline
      end
      readers.each do |reader|
        remaining = deadline - monotonic_time
        return FAILED unless remaining.positive? && reader.join(remaining)
      end
      return PRESENT unless signal.empty?

      wait_thread.value.success? ? ABSENT : FAILED
    rescue Interrupt
      raise
    rescue StandardError
      FAILED
    ensure
      terminate(wait_thread) if wait_thread
      stdin.close if stdin && !stdin.closed?
      stdout.close if stdout && !stdout.closed?
      stderr.close if stderr && !stderr.closed?
      readers.each { |reader| reader.join(CLEANUP_SECONDS) }
    end

    private

    def valid_argv?(argv)
      argv.instance_of?(Array) && !argv.empty? &&
        argv.all? { |value| value.instance_of?(String) && !value.empty? && !value.include?("\0") }
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def terminate(wait_thread)
      process_group = -wait_thread.pid
      Process.kill("TERM", process_group)
      wait_thread.join(CLEANUP_SECONDS)
      Process.kill("KILL", process_group)
      wait_thread.join(CLEANUP_SECONDS) if wait_thread.alive?
    rescue Errno::ESRCH
      wait_thread.join(CLEANUP_SECONDS) if wait_thread&.alive?
    end
  end
end
