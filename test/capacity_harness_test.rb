# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study/bounded_absence_query"

class CapacityHarnessTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HARNESS = File.join(ROOT, "bin", "capacity-harness")
  COMPOSE_FILE = File.join(ROOT, "capacity", "compose.yml")
  IMAGE_REF = "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70"

  FAKE_DOCKER = <<~'RUBY'
    #!/usr/bin/env ruby
    require "json"

    arguments = ARGV
    config = ENV.fetch("XRPL_CAPACITY_CONFIG_DIR", "<unset>")
    File.open(ENV.fetch("FAKE_DOCKER_LOG"), "a") { |log| log.puts("config=#{config} #{arguments.join(" ")}") }
    reset_query = File.exist?(ENV.fetch("FAKE_RESET_DOWN_FILE"))
    if reset_query
      case ENV["FAKE_RESET_QUERY_MODE"]
      when "failure"
        exit 70
      when "timeout"
        sleep 30
      when "oversize"
        print "x" * 1_100_000
        exit 0
      end
    end

    case arguments.first
    when "version"
      if ENV["FAKE_DOCTOR_FAILURE"] == "docker-version"
        warn "fake docker version failure"
        exit 70
      end
      exit 0
    when "compose"
      project_option = arguments.index("--project-name")
      if project_option
        File.write(ENV.fetch("FAKE_DOCKER_PROJECT_FILE"), arguments.fetch(project_option + 1))
      end

      if ENV["FAKE_DOCTOR_FAILURE"] == "compose-validation" && arguments.include?("config")
        warn "fake compose validation failure"
        exit 70
      end

      if arguments.include?("ps")
        puts "fake-container-id-full"
      elsif arguments.include?("restart")
        File.write(ENV.fetch("FAKE_RESTARTED_FILE"), "restarted") if ENV["FAKE_MOUNT_ORDER_AFTER_RESTART"] == "1"
        exit 70 if ENV["FAKE_RESTART_FAILURE"] == "1"
      elsif arguments.include?("down")
        File.write(ENV.fetch("FAKE_RESET_DOWN_FILE"), "down-complete")
      elsif arguments.include?("exec")
        info = {
          "build_version" => "3.3.0",
          "network_id" => 21_338,
          "peers" => 0,
          "validation_quorum" => 0,
          "validated_ledger" => {
            "reserve_base_xrp" => 0.5,
            "reserve_inc_xrp" => 0.2,
            "seq" => 1,
            "hash" => "A" * 64
          }
        }
        case ENV["FAKE_SERVER_DRIFT"]
        when "build" then info["build_version"] = "3.2.0"
        when "network" then info["network_id"] = 1
        when "peers" then info["peers"] = 1
        when "quorum" then info["validation_quorum"] = 1
        when "reserve" then info["validated_ledger"]["reserve_base_xrp"] = 1
        end
        puts JSON.generate(
          "result" => {
            "info" => info
          }
        )
      end
    when "image"
      format = arguments.last
      if format.include?("Architecture")
        if ENV["FAKE_DOCTOR_FAILURE"] == "image-architecture"
          warn "fake image architecture inspection failure"
          exit 70
        end
        puts ENV.fetch("FAKE_IMAGE_ARCH", "amd64")
      else
        if ENV["FAKE_DOCTOR_FAILURE"] == "image-digest"
          warn "fake image digest inspection failure"
          exit 70
        end
        puts ENV.fetch("FAKE_IMAGE_REF")
      end
    when "info"
      if ENV["FAKE_DOCTOR_FAILURE"] == "host-architecture"
        warn "fake host architecture inspection failure"
        exit 70
      end
      puts ENV.fetch("FAKE_HOST_ARCH", "x86_64")
    when "inspect"
      project = if File.exist?(ENV.fetch("FAKE_DOCKER_PROJECT_FILE"))
                  File.read(ENV.fetch("FAKE_DOCKER_PROJECT_FILE")).strip
                else
                  "xrpl-reserve-capacity"
                end
      expected_network = "#{project}_capacity_internal"
      networks = {
        expected_network => {
          "NetworkID" => ENV.fetch("FAKE_CONTAINER_NETWORK_ID", "fake-network-id")
        }
      }
      if ENV["FAKE_EXTRA_NETWORK"] == "1"
        networks["unrelated_default"] = { "NetworkID" => "extra-network-id" }
      end
      mounts = [
        {
          "Type" => "bind",
          "Source" => ENV.fetch("FAKE_CONFIG_SOURCE", File.expand_path("capacity/config", ENV.fetch("FAKE_ROOT"))),
          "Destination" => ENV.fetch("FAKE_CONFIG_DESTINATION", "/config"),
          "Mode" => "ro",
          "RW" => ENV["FAKE_CONFIG_RW"] == "1",
          "Propagation" => ENV.fetch("FAKE_CONFIG_PROPAGATION", "rprivate")
        },
        { "Type" => "volume", "Name" => "#{project}_capacity_data", "Source" => "#{project}_capacity_data", "Destination" => "/var/lib/xrpld", "Mode" => "rw", "RW" => true, "Propagation" => "" },
        { "Type" => "volume", "Name" => "#{project}_capacity_logs", "Source" => "#{project}_capacity_logs", "Destination" => "/var/log/xrpld", "Mode" => "rw", "RW" => true, "Propagation" => "" }
      ]
      if ENV["FAKE_EXTRA_CONFIG_MOUNT"] == "1"
        mounts << { "Type" => "bind", "Source" => "/tmp/extra", "Destination" => "/config/extra", "Mode" => "ro", "RW" => false, "Propagation" => "rprivate" }
      end
      mounts.reverse! if ENV["FAKE_MOUNT_ORDER_AFTER_RESTART"] == "1" && File.exist?(ENV.fetch("FAKE_RESTARTED_FILE"))
      puts JSON.generate(
        [
          {
            "HostConfig" => {
              "ReadonlyRootfs" => true,
              "CapDrop" => ["ALL"],
              "SecurityOpt" => ["no-new-privileges:true"],
              "Memory" => 17_179_869_184,
              "NanoCpus" => 4_000_000_000,
              "PidsLimit" => 512
            },
            "Config" => {
              "User" => "997:997",
              "Image" => ENV.fetch("FAKE_CONTAINER_IMAGE", ENV.fetch("FAKE_IMAGE_REF")),
              "Labels" => {
                "com.docker.compose.project" => project,
                "com.docker.compose.service" => "rippled"
              },
              "Entrypoint" => ["/bin/sh", "-c"],
              "Cmd" => [ENV.fetch(
                "FAKE_CONTAINER_COMMAND",
                "mkdir -p /var/lib/xrpld/db/nudb /var/log/xrpld && exec /usr/bin/xrpld --conf /config/rippled.cfg --standalone"
              )]
            },
            "NetworkSettings" => { "Ports" => {}, "Networks" => networks },
            "Mounts" => mounts
          }
        ]
      )
    when "network"
      if arguments.include?("ls")
        puts "retained-network" if reset_query && ENV["FAKE_RESET_RESIDUE"] == "network"
        exit 70 if ENV["FAKE_RESOURCE_QUERY_FAILURE"] == "network"
        if ENV["FAKE_EXISTING_CANDIDATE"] == "1"
          project = File.read(ENV.fetch("FAKE_DOCKER_PROJECT_FILE")).strip
          puts "#{project}_capacity_internal"
        elsif ENV["FAKE_RESOURCE_KIND"] == "network"
          puts "existing-network"
        end
        exit 0
      end
      if ENV["FAKE_RESOURCE_KIND"] == "network" && arguments.include?("inspect") && arguments.include?("--format")
        puts "existing-network-id"
        exit 0
      end
      unless File.exist?(ENV.fetch("FAKE_DOCKER_PROJECT_FILE"))
        exit 1
      end
      network_name = arguments.fetch(2)
      if arguments.include?("--format")
        puts "fake-network-id"
      else
        puts JSON.generate(
          [
            {
              "Name" => network_name,
              "Id" => "fake-network-id",
              "Internal" => true,
              "Attachable" => false
            }
          ]
        )
      end
    when "ps"
      puts "retained-container" if reset_query && ENV["FAKE_RESET_RESIDUE"] == "container"
      exit 70 if ENV["FAKE_RESOURCE_QUERY_FAILURE"] == "container"
      if ENV["FAKE_EXISTING_CANDIDATE"] == "1"
        puts arguments.include?("--no-trunc") ? "fake-container-id-full" : "fake-container-id"
      elsif ENV["FAKE_RESOURCE_KIND"] == "container"
        puts "existing-container"
      end
    when "volume"
      if arguments.include?("ls")
        if reset_query
          filter = arguments.each_cons(2).find { |left, _right| left == "--filter" }&.last.to_s
          if ENV["FAKE_RESET_RESIDUE"] == "data-volume" && filter.include?("capacity_data")
            puts "retained-data-volume"
          elsif ENV["FAKE_RESET_RESIDUE"] == "log-volume" && filter.include?("capacity_logs")
            puts "retained-log-volume"
          end
        end
        exit 70 if ENV["FAKE_RESOURCE_QUERY_FAILURE"] == "volume"
        if ENV["FAKE_EXISTING_CANDIDATE"] == "1"
          project = File.read(ENV.fetch("FAKE_DOCKER_PROJECT_FILE")).strip
          puts "#{project}_capacity_data"
          puts "#{project}_capacity_logs"
        elsif ENV["FAKE_RESOURCE_KIND"] == "volume"
          puts arguments.last
        end
        exit 0
      end
      if arguments.include?("inspect") && ENV["FAKE_RESOURCE_KIND"] == "volume"
        puts arguments.last
      else
        exit 1
      end
    else
      warn "unexpected fake docker arguments: #{arguments.inspect}"
      exit 70
    end
  RUBY

  RUN_ID = "r0500000-a000010000-n01"

  def test_doctor_reports_native_eligibility_but_never_authorizes_counted_execution
    counted_diagnostic = "counted_run_ready=false reason=counted-execution-prerequisites-not-complete remaining_gates=pilot-validation,native-execution"
    phase_two_diagnostic = "phase2_complete=false remaining_gates=pilot-validation,native-execution,randomized-counted-runs,second-environment-replication,final-review"

    stdout, _stderr, status, = run_harness("doctor", host_arch: "x86_64", image_arch: "amd64")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "image_arch=amd64 host_arch=amd64"
    assert_includes stdout, "native_architecture_eligible=true"
    assert_includes stdout, counted_diagnostic
    assert_includes stdout, phase_two_diagnostic
    refute_includes stdout, "counted_run_ready=true"

    stdout, _stderr, status, = run_harness("doctor", host_arch: "aarch64", image_arch: "amd64")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "image_arch=amd64 host_arch=arm64"
    assert_includes stdout, "native_architecture_eligible=false reason=non-native-container-architecture"
    assert_includes stdout, counted_diagnostic
    assert_includes stdout, phase_two_diagnostic
    refute_includes stdout, "counted_run_ready=true"

    stdout, _stderr, status, = run_harness("doctor", host_arch: "riscv64", image_arch: "amd64")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "native_architecture_eligible=false reason=unsupported-host-architecture"
    assert_includes stdout, counted_diagnostic
    assert_includes stdout, phase_two_diagnostic
    refute_includes stdout, "counted_run_ready=true"

    stdout, _stderr, status, = run_harness("doctor", host_arch: "x86_64", image_arch: "s390x")
    assert_equal 2, status.exitstatus
    assert_includes stdout, "native_architecture_eligible=false reason=unsupported-container-architecture"
    assert_includes stdout, counted_diagnostic
    assert_includes stdout, phase_two_diagnostic
    refute_includes stdout, "counted_run_ready=true"
  end

  def test_doctor_image_digest_mismatch_is_hard_failure_with_false_readiness_diagnostics
    counted_diagnostic = "counted_run_ready=false reason=counted-execution-prerequisites-not-complete remaining_gates=pilot-validation,native-execution"
    phase_two_diagnostic = "phase2_complete=false remaining_gates=pilot-validation,native-execution,randomized-counted-runs,second-environment-replication,final-review"
    mismatched_ref = "xrpllabsofficial/xrpld@sha256:#{'0' * 64}"

    stdout, stderr, status, = run_harness("doctor", resolved_image_ref: mismatched_ref)

    assert_equal 2, status.exitstatus
    assert_equal "image digest mismatch\n", stderr
    assert_equal "#{counted_diagnostic}\n#{phase_two_diagnostic}\n", stdout
    refute_includes stdout, "counted_run_ready=true"
    refute_includes stdout, "phase2_complete=true"
  end

  def test_doctor_prerequisite_failures_preserve_tool_errors_and_report_false_readiness
    counted_diagnostic = "counted_run_ready=false reason=counted-execution-prerequisites-not-complete remaining_gates=pilot-validation,native-execution"
    phase_two_diagnostic = "phase2_complete=false remaining_gates=pilot-validation,native-execution,randomized-counted-runs,second-environment-replication,final-review"
    failures = {
      "docker-version" => "fake docker version failure\n",
      "compose-validation" => "fake compose validation failure\n",
      "image-architecture" => "fake image architecture inspection failure\n",
      "host-architecture" => "fake host architecture inspection failure\n",
      "image-digest" => "fake image digest inspection failure\n"
    }

    failures.each do |failure, expected_error|
      stdout, stderr, status, = run_harness("doctor", doctor_failure: failure)

      assert_equal 2, status.exitstatus, failure
      assert_equal expected_error, stderr, failure
      assert_equal "#{counted_diagnostic}\n#{phase_two_diagnostic}\n", stdout, failure
      refute_includes stdout, "counted_run_ready=true", failure
      refute_includes stdout, "phase2_complete=true", failure
    end
  end

  def test_verify_rejects_extra_container_network_attachments
    _stdout, stderr, status, = run_harness("verify", extra_network: true)

    refute status.success?
    assert_match(/unexpected container network attachments/, stderr)
  end

  def test_verify_rejects_container_network_id_different_from_inspected_network
    _stdout, stderr, status, = run_harness("verify", container_network_id: "different-network-id")

    refute status.success?
    assert_match(/container network ID drift/, stderr)
  end

  def test_verify_accepts_exact_expected_internal_non_attachable_network
    stdout, stderr, status, log = run_harness("verify")

    assert status.success?, stderr
    assert_includes stdout, "container isolation verified"
    project_name = compose_project_names(log).fetch(0)
    assert log.any? { |line| line.include?("network inspect #{project_name}_capacity_internal ") }
  end

  def test_compose_project_identity_is_stable_per_checkout_and_unique_across_checkouts
    with_fake_docker do |environment, log_path|
      Dir.mktmpdir("capacity-checkouts-") do |directory|
        checkout_a = make_harness_checkout(File.join(directory, "checkout-a"))
        checkout_b = make_harness_checkout(File.join(directory, "checkout-b"))

        2.times do
          _stdout, stderr, status = Open3.capture3(environment, File.join(checkout_a, "bin", "capacity-harness"), "doctor", chdir: checkout_a)
          assert_equal 2, status.exitstatus, stderr
        end
        _stdout, stderr, status = Open3.capture3(environment, File.join(checkout_b, "bin", "capacity-harness"), "doctor", chdir: checkout_b)
        assert_equal 2, status.exitstatus, stderr

        project_names = compose_project_names(File.readlines(log_path, chomp: true))
        assert_equal 3, project_names.length
        assert_equal project_names.fetch(0), project_names.fetch(1)
        refute_equal project_names.fetch(0), project_names.fetch(2)
        assert project_names.all? { |name| name.match?(/\Axrpl-reserve-capacity-[0-9a-f]{12}\z/) }
      end
    end
  end

  def test_confirmed_reset_targets_only_checkout_project_without_orphan_sweep
    _stdout, stderr, status, log = run_harness("reset", confirm_reset: true)

    assert status.success?, stderr
    down_command = log.find { |line| line.include?(" down ") }
    refute_nil down_command
    assert_match(/compose --project-name xrpl-reserve-capacity-[0-9a-f]{12} --file .* down --volumes\z/, down_command)
    refute_includes down_command, "--remove-orphans"
    project = down_command[/--project-name ([^ ]+)/, 1]
    assert log.any? do |line|
      line.include?("ps --all --filter label=com.docker.compose.project=#{project} --format {{.ID}}")
    end
    assert log.any? do |line|
      line.include?("network ls --filter name=^#{project}_capacity_internal$ --format {{.Name}}")
    end
    %w[capacity_data capacity_logs].each do |suffix|
      assert log.any? do |line|
        line.include?("volume ls --filter name=^#{project}_#{suffix}$ --format {{.Name}}")
      end
    end
  end

  # Break caught: Compose can exit zero while a checkout-scoped resource remains.
  def test_reset_requires_exact_absence_of_container_network_and_both_named_volumes
    %w[container network data-volume log-volume].each do |resource|
      _stdout, stderr, status, log = run_harness(
        "reset", confirm_reset: true, reset_residue: resource
      )

      refute status.success?, resource
      assert_match(/cleanup verification failed/, stderr, resource)
      assert_equal 1, log.count { |line| line.include?(" down --volumes") }, resource
    end
  end

  # Break caught: an unbounded or output-flooding absence query can falsely confirm cleanup.
  def test_reset_fails_closed_on_absence_query_failure_timeout_and_oversize_output
    %w[failure timeout oversize].each do |mode|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _stdout, stderr, status, log = run_harness(
        "reset", confirm_reset: true, reset_query_mode: mode
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute status.success?, mode
      assert_match(/cleanup verification failed/, stderr, mode)
      assert_operator elapsed, :<, 8, mode
      assert_equal 1, log.count { |line| line.include?(" down --volumes") }, mode
    end
  end

  # Break caught: exact-PID cleanup can strand a TERM-resistant query descendant.
  def test_inner_query_timeout_reaps_the_term_resistant_query_group
    Dir.mktmpdir("bounded-query-") do |directory|
      pids = []
      pid_path = File.join(directory, "query-tree.pids")
      program = <<~RUBY
        trap("TERM") {}
        descendant = fork { sleep 30 }
        File.binwrite(ARGV.fetch(0), [Process.pid, Process.getpgrp, descendant].join("\\n"))
        sleep 30
      RUBY
      query = XrplReserveStudy::BoundedAbsenceQuery.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = query.call([RbConfig.ruby, "-e", program, pid_path])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      pid, process_group, descendant = File.readlines(pid_path, chomp: true).map { |value| Integer(value) }
      pids = [pid, descendant]

      assert_equal XrplReserveStudy::BoundedAbsenceQuery::FAILED, result
      assert_operator elapsed, :>=, 5
      assert_operator elapsed, :<, 7
      pids.each { |process_id| assert_process_dead(process_id) }
      assert_equal pid, process_group
    ensure
      Array(pids).each do |process_id|
        Process.kill("KILL", process_id) if process_alive?(process_id)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  # Break caught: a query leader exiting on TERM can hide a resistant group descendant.
  def test_inner_query_kills_group_after_query_leader_exits
    Dir.mktmpdir("bounded-query-leader-") do |directory|
      pids = []
      pid_path = File.join(directory, "query-tree.pids")
      program = <<~RUBY
        descendant = fork do
          trap("TERM") {}
          sleep 30
        end
        File.binwrite(ARGV.fetch(0), [Process.pid, descendant].join("\\n"))
        sleep 30
      RUBY
      query = XrplReserveStudy::BoundedAbsenceQuery.new
      clock_values = [0.0] + Array.new(20, 0.1) + [6.0]
      query.define_singleton_method(:monotonic_time) { clock_values.shift || 6.0 }

      result = query.call([RbConfig.ruby, "-e", program, pid_path])
      pids = File.readlines(pid_path, chomp: true).map { |value| Integer(value) }

      assert_equal XrplReserveStudy::BoundedAbsenceQuery::FAILED, result
      pids.each { |process_id| assert_process_dead(process_id) }
    ensure
      Array(pids).each do |process_id|
        Process.kill("KILL", process_id) if process_alive?(process_id)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_inner_query_present_result_reaps_group_after_query_leader_exits
    Dir.mktmpdir("bounded-query-present-") do |directory|
      pids = []
      pid_path = File.join(directory, "query-tree.pids")
      program = <<~RUBY
        descendant = fork do
          trap("TERM") {}
          sleep 30
        end
        STDOUT.sync = true
        File.binwrite(ARGV.fetch(0), [Process.pid, descendant].join("\\n"))
        puts "query output"
        sleep 0.2
      RUBY
      query = XrplReserveStudy::BoundedAbsenceQuery.new

      result = query.call([RbConfig.ruby, "-e", program, pid_path])
      pids = File.readlines(pid_path, chomp: true).map { |value| Integer(value) }

      assert_equal XrplReserveStudy::BoundedAbsenceQuery::PRESENT, result
      pids.each { |process_id| assert_process_dead(process_id) }
    ensure
      Array(pids).each do |process_id|
        Process.kill("KILL", process_id) if process_alive?(process_id)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_inner_query_absent_result_reaps_group_after_query_leader_exits
    Dir.mktmpdir("bounded-query-absent-") do |directory|
      pids = []
      pid_path = File.join(directory, "query-tree.pids")
      program = <<~RUBY
        STDOUT.reopen("/dev/null", "w")
        STDERR.reopen("/dev/null", "w")
        descendant = fork do
          trap("TERM") {}
          sleep 30
        end
        File.binwrite(ARGV.fetch(0), [Process.pid, descendant].join("\\n"))
        sleep 0.2
      RUBY
      query = XrplReserveStudy::BoundedAbsenceQuery.new

      result = query.call([RbConfig.ruby, "-e", program, pid_path])
      pids = File.readlines(pid_path, chomp: true).map { |value| Integer(value) }

      assert_equal XrplReserveStudy::BoundedAbsenceQuery::ABSENT, result
      pids.each { |process_id| assert_process_dead(process_id) }
    ensure
      Array(pids).each do |process_id|
        Process.kill("KILL", process_id) if process_alive?(process_id)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_candidate_start_removes_caller_config_override_and_sets_only_validated_run_config
    with_candidate_config do |config_dir|
      stdout, stderr, status, log = run_harness(
        "up-candidate", RUN_ID, inherited_config: "/attacker/config", config_source: config_dir
      )

      assert status.success?, "#{stdout}\n#{stderr}"
      up = log.find { |line| line.include?(" compose ") && line.include?(" up ") }
      assert_equal "config=#{config_dir}", up.split.first
      refute log.any? { |line| line.start_with?("config=/attacker/config") }
      refute_includes stdout, "counted_run_ready=true"
    end
  end

  def test_candidate_commands_reject_invalid_missing_and_symlinked_config_before_docker
    invalid_ids = ["r1-a1-n1", "r0500000-a000010000-n01;touch-x", "../r0500000-a000010000-n01"]
    invalid_ids.each do |run_id|
      _stdout, stderr, status, log = run_harness("up-candidate", run_id)
      refute status.success?, run_id
      assert_match(/invalid candidate run ID/, stderr, run_id)
      assert_empty log, run_id
    end

    _stdout, stderr, status, log = run_harness("up-candidate", RUN_ID)
    refute status.success?
    assert_match(/candidate configuration/, stderr)
    assert_empty log

    with_candidate_config do |config_dir|
      file = File.join(config_dir, "rippled.cfg")
      target = "#{file}.target"
      File.rename(file, target)
      File.symlink(target, file)
      _stdout, stderr, status, log = run_harness("up-candidate", RUN_ID)
      refute status.success?
      assert_match(/candidate configuration/, stderr)
      assert_empty log
    end
  end

  def test_candidate_commands_reject_surplus_arguments_before_docker
    %w[up-candidate verify-candidate].each do |command|
      _stdout, stderr, status, log = run_harness(command, RUN_ID, "unexpected")

      refute status.success?, command
      assert_match(/usage: bin\/capacity-harness/, stderr, command)
      assert_empty log, command
    end
  end

  def test_candidate_start_refuses_preexisting_checkout_resources_without_cleanup
    %w[container network volume].each do |kind|
      with_candidate_config do |config_dir|
        _stdout, stderr, status, log = run_harness(
          "up-candidate", RUN_ID, resource_kind: kind, config_source: config_dir
        )
        refute status.success?, kind
        assert_match(/checkout-scoped capacity resource already exists/, stderr, kind)
        refute log.any? { |line| line.include?(" down ") }, kind
        refute log.any? { |line| line.include?(" rm ") }, kind
      end
    end
  end

  def test_candidate_start_fails_closed_when_resource_discovery_cannot_report_absence
    %w[container network volume].each do |kind|
      with_candidate_config do |config_dir|
        _stdout, stderr, status, log = run_harness(
          "up-candidate", RUN_ID, resource_query_failure: kind, config_source: config_dir
        )

        refute status.success?, kind
        assert_match(/checkout-scoped capacity resource discovery failed/, stderr, kind)
        refute log.any? { |line| line.include?(" compose ") && line.include?(" up ") }, kind
      end
    end
  end

  def test_verify_candidate_accepts_exact_mount_and_server_contract
    with_candidate_config do |config_dir|
      stdout, stderr, status, = run_harness("verify-candidate", RUN_ID, config_source: config_dir)

      assert status.success?, stderr
      assert_includes stdout, "candidate verified"
      refute_includes stdout, "counted_run_ready=true"
    end
  end

  def test_verify_candidate_rejects_mount_image_and_server_drift
    cases = {
      "wrong mount" => { config_source: "/tmp/wrong", pattern: /config mount source drift/ },
      "wrong destination" => { config_destination: "/other", pattern: /config mount/ },
      "writable mount" => { config_rw: true, pattern: /config mount is not read-only/ },
      "propagation" => { config_propagation: "rshared", pattern: /config mount propagation drift/ },
      "extra config mount" => { extra_config_mount: true, pattern: /additional config mount/ },
      "image" => { container_image: "example.invalid/drift@sha256:#{'f' * 64}", pattern: /image digest mismatch/ },
      "standalone command" => { container_command: "exec /usr/bin/xrpld --conf /config/rippled.cfg", pattern: /standalone command drift/ },
      "build" => { server_drift: "build", pattern: /wrong build version/ },
      "network" => { server_drift: "network", pattern: /wrong network id/ },
      "peers" => { server_drift: "peers", pattern: /peer isolation failed/ },
      "quorum" => { server_drift: "quorum", pattern: /unexpected validation quorum/ },
      "reserve" => { server_drift: "reserve", pattern: /wrong base reserve/ }
    }

    cases.each do |name, settings|
      with_candidate_config do |config_dir|
        effective = settings.reject { |key, _| key == :pattern }.merge(
          config_source: settings.fetch(:config_source, config_dir)
        )
        _stdout, stderr, status, = run_harness("verify-candidate", RUN_ID, **effective)
        refute status.success?, name
        assert_match settings.fetch(:pattern), stderr, name
      end
    end
  end

  # Break caught: a controlled restart can drift identity or accidentally remove persistent data.
  def test_restart_candidate_preserves_exact_verified_container_and_never_resets_or_removes
    with_candidate_config do |config_dir|
      stdout, stderr, status, log = run_harness(
        "restart-candidate", RUN_ID, config_source: config_dir, restart_mount_order_change: true
      )

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes stdout, "candidate restarted"
      assert_equal 1, log.count { |line| line.include?(" compose ") && line.include?(" restart rippled") }
      refute log.any? { |line| line.include?(" down ") || line.include?(" rm ") || line.include?("--volumes") }
    end
  end

  def test_restart_candidate_rejects_invalid_identity_and_surplus_arguments_before_restart
    with_candidate_config do |config_dir|
      _stdout, stderr, status, log = run_harness(
        "restart-candidate", RUN_ID, config_source: config_dir,
        container_image: "example.invalid/drift@sha256:#{'f' * 64}"
      )
      refute status.success?
      assert_match(/image digest mismatch/, stderr)
      refute log.any? { |line| line.include?(" restart ") }
    end

    _stdout, stderr, status, log = run_harness("restart-candidate", RUN_ID, "unexpected")
    refute status.success?
    assert_match(/usage: bin\/capacity-harness/, stderr)
    assert_empty log
  end

  private

  def run_harness(command, *arguments, host_arch: "x86_64", image_arch: "amd64", extra_network: false,
                  container_network_id: "fake-network-id", confirm_reset: false, inherited_config: nil,
                  config_source: nil, config_destination: "/config", config_rw: false,
                  config_propagation: "rprivate", extra_config_mount: false, container_image: IMAGE_REF,
                  resource_kind: nil, resource_query_failure: nil, container_command: nil, server_drift: nil,
                  resolved_image_ref: IMAGE_REF, doctor_failure: nil, restart_failure: false,
                  reset_residue: nil, reset_query_mode: nil, restart_mount_order_change: false)
    result = nil
    with_fake_docker do |environment, log_path|
      environment = environment.merge(
        "FAKE_HOST_ARCH" => host_arch,
        "FAKE_IMAGE_ARCH" => image_arch,
        "FAKE_IMAGE_REF" => resolved_image_ref,
        "FAKE_EXTRA_NETWORK" => extra_network ? "1" : "0",
        "FAKE_CONTAINER_NETWORK_ID" => container_network_id,
        "XRPL_CAPACITY_CONFIRM_RESET" => confirm_reset ? "1" : "0",
        "XRPL_CAPACITY_CONFIG_DIR" => inherited_config,
        "FAKE_ROOT" => ROOT,
        "FAKE_CONFIG_SOURCE" => config_source,
        "FAKE_CONFIG_DESTINATION" => config_destination,
        "FAKE_CONFIG_RW" => config_rw ? "1" : "0",
        "FAKE_CONFIG_PROPAGATION" => config_propagation,
        "FAKE_EXTRA_CONFIG_MOUNT" => extra_config_mount ? "1" : "0",
        "FAKE_CONTAINER_IMAGE" => container_image,
        "FAKE_RESOURCE_KIND" => resource_kind,
        "FAKE_RESOURCE_QUERY_FAILURE" => resource_query_failure,
        "FAKE_CONTAINER_COMMAND" => container_command,
        "FAKE_SERVER_DRIFT" => server_drift,
        "FAKE_DOCTOR_FAILURE" => doctor_failure,
        "FAKE_RESTART_FAILURE" => restart_failure ? "1" : "0",
        "FAKE_MOUNT_ORDER_AFTER_RESTART" => restart_mount_order_change ? "1" : "0",
        "FAKE_EXISTING_CANDIDATE" => command == "restart-candidate" ? "1" : "0",
        "FAKE_RESET_RESIDUE" => reset_residue,
        "FAKE_RESET_QUERY_MODE" => reset_query_mode
      )
      environment.compact!
      stdout, stderr, status = Open3.capture3(environment, HARNESS, command, *arguments, chdir: ROOT)
      result = [stdout, stderr, status, File.readlines(log_path, chomp: true)]
    end
    result
  end

  def with_fake_docker
    Dir.mktmpdir("fake-docker-") do |directory|
      docker_path = File.join(directory, "docker")
      log_path = File.join(directory, "docker.log")
      File.write(docker_path, FAKE_DOCKER)
      File.chmod(0o755, docker_path)
      File.write(log_path, "")
      environment = {
        "PATH" => "#{directory}:#{ENV.fetch('PATH')}",
        "FAKE_DOCKER_LOG" => log_path,
        "FAKE_DOCKER_PROJECT_FILE" => File.join(directory, "project-name"),
        "FAKE_RESET_DOWN_FILE" => File.join(directory, "reset-down"),
        "FAKE_RESTARTED_FILE" => File.join(directory, "restarted"),
        "FAKE_IMAGE_REF" => IMAGE_REF
      }
      yield environment, log_path
    end
  end

  def with_candidate_config
    config_dir = File.join(ROOT, "capacity", "runtime", RUN_ID, "config")
    FileUtils.rm_rf(File.join(ROOT, "capacity", "runtime", RUN_ID))
    FileUtils.mkdir_p(config_dir)
    canonical = File.binread(File.join(ROOT, "capacity", "config", "rippled.cfg"))
    File.binwrite(File.join(config_dir, "rippled.cfg"), canonical.sub("account_reserve = 1000000", "account_reserve = 500000"))
    yield config_dir
  ensure
    FileUtils.rm_rf(File.join(ROOT, "capacity", "runtime", RUN_ID))
  end

  def make_harness_checkout(path)
    FileUtils.mkdir_p(File.join(path, "bin"))
    FileUtils.mkdir_p(File.join(path, "capacity"))
    FileUtils.cp(HARNESS, File.join(path, "bin", "capacity-harness"))
    FileUtils.cp(COMPOSE_FILE, File.join(path, "capacity", "compose.yml"))
    path
  end

  def compose_project_names(log)
    log.map { |line| line[/ compose --project-name ([^ ]+)/, 1] }.compact
  end

  def assert_process_dead(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      return unless process_alive?(pid)

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    flunk "process survived: #{pid}"
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
