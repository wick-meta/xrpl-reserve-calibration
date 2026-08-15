# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "rbconfig"
require_relative "../lib/xrpl_reserve_study"

class CapacityEnvironmentProbeTest < Minitest::Test
  IMAGE = "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70"

  FakeRunner = Struct.new(:outputs, :calls) do
    def call(argv)
      calls << argv
      outputs.fetch(calls.length - 1)
    end
  end

  def test_captures_only_the_normalized_closed_environment_and_freezes_it
    runner = FakeRunner.new([
      JSON.generate(
        "docker_server_version" => "28.3.2", "host_architecture" => "arm64",
        "host_operating_system" => "docker-desktop", "host_logical_cpus" => 8,
        "host_memory_bytes" => 17_179_869_184
      ),
      JSON.generate("candidate_image_architecture" => "arm64")
    ], [])

    captured = XrplReserveStudy::CapacityEnvironmentProbe.new(command_runner: runner).capture

    assert_equal %w[candidate_image_architecture candidate_image_digest docker_server_version host_architecture
                    host_logical_cpus host_memory_bytes host_operating_system native_architecture_eligible], captured.keys.sort
    assert_equal IMAGE, captured.fetch("candidate_image_digest")
    assert_equal true, captured.fetch("native_architecture_eligible")
    assert captured.frozen?
    assert_equal "docker", runner.calls.fetch(0).fetch(0)
    assert_equal ["docker", "image", "inspect"], runner.calls.fetch(1).first(3)
    assert_includes runner.calls.fetch(1), IMAGE
  end

  def test_reports_architecture_mismatch_without_authorizing_it
    runner = runner_for(host_arch: "arm64", image_arch: "amd64")
    captured = XrplReserveStudy::CapacityEnvironmentProbe.new(command_runner: runner).capture
    assert_equal false, captured.fetch("native_architecture_eligible")
  end

  def test_rejects_unsupported_malformed_extra_nonfinite_and_wrong_digest_outputs
    valid_host = host_json
    invalid_hosts = [
      JSON.generate(JSON.parse(valid_host).merge("host_architecture" => "s390x")),
      JSON.generate(JSON.parse(valid_host).merge("host_operating_system" => "other")),
      JSON.generate(JSON.parse(valid_host).merge("host_logical_cpus" => 0)),
      valid_host.sub("17179869184", "1e9999"),
      JSON.generate(JSON.parse(valid_host).merge("name" => "forbidden")),
      JSON.generate(JSON.parse(valid_host).merge("docker_server_version" => "28.3.2\n")),
      JSON.generate(JSON.parse(valid_host).merge("docker_server_version" => "28.3.2\r\n")),
      "not-json"
    ]
    invalid_hosts.each do |host|
      assert_probe_error { probe_with(host, JSON.generate("candidate_image_architecture" => "amd64")) }
    end
    [
      JSON.generate("candidate_image_architecture" => "s390x"),
      JSON.generate("candidate_image_architecture" => "amd64", "candidate_image_digest" => "bad")
    ].each do |image|
      assert_probe_error { probe_with(valid_host, image) }
    end
  end

  def test_sanitizes_runner_failures
    runner = Object.new
    def runner.call(_argv)
      raise StandardError, "raw host and path"
    end
    error = assert_probe_error { XrplReserveStudy::CapacityEnvironmentProbe.new(command_runner: runner).capture }
    assert_equal "capacity environment probe failed", error.message
    refute_includes error.message, "raw"
  end

  def test_bounded_child_runner_rejects_nonzero_overflow_and_timeout_with_controlled_errors
    runner = XrplReserveStudy::CapacityEnvironmentProbe::CommandRunner.new
    [
      [RbConfig.ruby, "-e", 'STDERR.write("raw failure"); exit 1'],
      [RbConfig.ruby, "-e", 'STDOUT.write("x" * 1_048_577)'],
      [RbConfig.ruby, "-e", 'STDERR.write("x" * 1_048_577)']
    ].each do |argv|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_probe_error { runner.call(argv) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      assert_equal "capacity environment probe failed", error.message
      refute_includes error.message, "raw"
    end

    ticks = [0.0, 11.0]
    timeout_runner = XrplReserveStudy::CapacityEnvironmentProbe::CommandRunner.new(
      monotonic_clock: -> { ticks.shift || 11.0 }
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_probe_error { timeout_runner.call([RbConfig.ruby, "-e", "sleep 30"]) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal "capacity environment probe failed", error.message
  end

  def test_termination_never_uses_an_unbounded_join_after_kill
    joins = []
    thread = Struct.new(:pid) do
      define_method(:join) { |timeout = :unbounded| joins << timeout; nil }
      define_method(:alive?) { true }
    end.new(12_345)
    runner = XrplReserveStudy::CapacityEnvironmentProbe::CommandRunner.new(monotonic_clock: -> { 10.0 })
    Process.stub(:kill, ->(*) {}) do
      runner.__send__(:terminate_process_group, thread, 10.0)
    end
    refute_includes joins, :unbounded
  end

  private

  def host_json(host_arch: "amd64")
    JSON.generate(
      "docker_server_version" => "28.3.2", "host_architecture" => host_arch,
      "host_operating_system" => "linux", "host_logical_cpus" => 8,
      "host_memory_bytes" => 17_179_869_184
    )
  end

  def runner_for(host_arch:, image_arch:)
    FakeRunner.new([host_json(host_arch: host_arch), JSON.generate("candidate_image_architecture" => image_arch)], [])
  end

  def probe_with(host, image)
    XrplReserveStudy::CapacityEnvironmentProbe.new(command_runner: FakeRunner.new([host, image], [])).capture
  end

  def assert_probe_error(&block)
    assert_raises(XrplReserveStudy::CapacityEnvironmentProbeError, &block)
  end
end
