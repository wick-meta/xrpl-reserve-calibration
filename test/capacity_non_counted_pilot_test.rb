# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class CapacityNonCountedPilotTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUN_ID = "r0500000-a000010000-n01"
  SOURCE_COMMIT = "a" * 40
  HASH = "b" * 64
  CONFIG_DIR = "/validated/config"
  WORKLOAD_DIR = "/validated/workload"
  MANIFEST_DIR = "/validated/manifest"
  OUTPUT_DIR = File.join(
    XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT,
    RUN_ID, "execution", "non-counted-pilot-000000003"
  )

  class FakeInputLoader
    def initialize(events, snapshot: nil, load_error: nil, revalidate_error: nil)
      @events = events
      @snapshot = snapshot
      @load_error = load_error
      @revalidate_errors = Array(revalidate_error).dup
    end

    def load(run_id:, config_dir:, workload_dir:, manifest_dir:)
      @events << [:load, run_id, config_dir, workload_dir, manifest_dir]
      raise @load_error if @load_error
      @snapshot
    end

    def revalidate(snapshot)
      @events << [:revalidate, snapshot.fetch("binding_fingerprint")]
      error = @revalidate_errors.shift
      raise error if error
      true
    end
  end

  class FakeHarness
    def initialize(events, failures: {})
      @events = events
      @failures = failures.transform_values { |value| Array(value).dup }
    end

    def call(command, run_id)
      @events << [command, run_id]
      queue = @failures[command]
      raise queue.shift if queue && !queue.empty?
      true
    end
  end

  class FakeSampler
    def initialize(events, result:, run_error: nil, recovery_error: nil)
      @events = events
      @result = result
      @run_error = run_error
      @recovery_error = recovery_error
    end

    def run(authority:)
      @events << [:sample, authority.dup]
      raise @run_error if @run_error
      @result
    end

    def recover(restart_started_monotonic:, expected_ledger:)
      @events << [:recover, restart_started_monotonic, expected_ledger]
      raise @recovery_error if @recovery_error
      { "recovered" => true, "recovery_seconds" => 2.5, "validated_ledger" => expected_ledger }
    end
  end

  class FakeReducer
    def initialize(events, thresholds_passed: true, error: nil)
      @events = events
      @thresholds_passed = thresholds_passed
      @error = error
    end

    def summarize(**arguments)
      @events << [:reduce, arguments]
      raise @error if @error
      {
        "schema_version" => "capacity-metrics-summary-v1",
        "thresholds_passed" => @thresholds_passed,
        "abort_rule_breaches" => []
      }
    end
  end

  class FakeValidator
    def initialize(events, error: nil)
      @events = events
      @error = error
    end

    def validate_artifacts!(**arguments)
      @events << [:validate_artifacts, arguments]
      raise @error if @error
      true
    end
  end

  class FakePublisher
    attr_reader :files

    class Staging
      def initialize(files, fail_name: nil)
        @files = files
        @fail_name = fail_name
      end

      def write(name, bytes)
        raise IOError, "staging write failed" if name == @fail_name
        @files[name] = bytes
      end

      def sha256(name)
        Digest::SHA256.hexdigest(@files.fetch(name))
      end
    end

    def initialize(events, error: nil, fail_name: nil)
      @events = events
      @error = error
      @fail_name = fail_name
      @files = {}
    end

    def publish(output_dir)
      @events << [:publish, output_dir]
      raise @error if @error
      yield Staging.new(@files, fail_name: @fail_name)
    end
  end

  def test_runs_guarded_sequence_resets_before_validation_and_publishes_exact_inventory
    events = []
    publisher = FakePublisher.new(events)
    pilot = build_pilot(events, publisher: publisher)
    secret = +"test-only-authority"

    result = run_pilot(pilot, events, secret: secret)

    assert_equal "passed", result.fetch("status")
    assert_equal "success", result.fetch("disposition_code")
    assert_equal true, result.fetch("pilot_complete")
    assert_equal false, result.fetch("counted_execution_authorized")
    assert_equal false, result.fetch("native_execution_established")
    assert_equal "", secret
    assert_operator event_index(events, ["reset", RUN_ID]), :<, event_index(events, :validate_artifacts)
    assert_operator event_index(events, :validate_artifacts), :<, event_index(events, :publish)
    assert_equal 2, events.count { |event| event.first == :revalidate }
    assert_equal %w[SHA256SUMS metrics-summary.json pilot-result.json samples.jsonl transactions.jsonl],
                 publisher.files.keys.sort
    assert_equal %w[pilot-result.json transactions.jsonl samples.jsonl metrics-summary.json],
                 publisher.files.fetch("SHA256SUMS").lines.map { |line| line.split("  ").last.strip }
    assert_equal result, JSON.parse(publisher.files.fetch("pilot-result.json"))
    assert publisher.files.values.all? { |bytes| bytes.end_with?("\n") }
  end

  def test_complete_threshold_failure_is_published_but_never_promotes_lifecycle
    events = []
    publisher = FakePublisher.new(events)
    pilot = build_pilot(events, publisher: publisher, thresholds_passed: false)

    result = run_pilot(pilot, events)

    assert_equal "failed", result.fetch("status")
    assert_equal "threshold-failure", result.fetch("disposition_code")
    assert_equal false, result.fetch("pilot_complete")
    assert_equal false, result.fetch("counted_execution_authorized")
    assert_equal false, result.fetch("native_execution_established")
    refute_empty publisher.files
  end

  def test_preexecution_input_failure_never_starts_reads_resets_or_publishes
    events = []
    publisher = FakePublisher.new(events)
    error = XrplReserveStudy::CapacityNonCountedPilotError.new("input-failure", empty_progress)
    pilot = build_pilot(events, publisher: publisher, load_error: error)

    assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) { run_pilot(pilot, events) }
    refute events.any? { |event| %w[up-candidate reset].include?(event.first) || event.first == :read_secret }
    assert_empty publisher.files
  end

  def test_alternate_output_directory_is_rejected_before_inputs_or_start
    events = []
    publisher = FakePublisher.new(events)
    pilot = build_pilot(events, publisher: publisher)

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      pilot.run(
        run_id: RUN_ID, config_dir: CONFIG_DIR, workload_dir: WORKLOAD_DIR,
        manifest_dir: MANIFEST_DIR,
        output_dir: File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, RUN_ID, "alternate"),
        secret_reader: -> { events << [:read_secret] }
      )
    end

    assert_equal "input-failure", error.code
    assert_empty events
    assert_empty publisher.files
  end

  def test_every_failure_after_start_attempt_resets_exactly_once_and_never_publishes_partial_artifacts
    cases = {
      "start" => { harness_failures: { "up-candidate" => RuntimeError.new("raw") } },
      "verify" => { harness_failures: { "verify-candidate" => Array.new(3) { RuntimeError.new("raw") } } },
      "secret" => { secret_error: IOError.new("raw") },
      "sampling" => { sampler_error: RuntimeError.new("raw") },
      "restart" => { harness_failures: { "restart-candidate" => RuntimeError.new("raw") } },
      "recovery" => { recovery_error: RuntimeError.new("raw") },
      "reducer" => { reducer_error: RuntimeError.new("raw") }
    }

    cases.each do |name, settings|
      events = []
      publisher = FakePublisher.new(events)
      pilot = build_pilot(events, publisher: publisher, **settings)
      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError, name) do
        run_pilot(pilot, events, secret_error: settings[:secret_error])
      end
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, name
      refute events.any? { |event| event.first == :publish }, name
      assert_empty publisher.files, name
      refute_match(/raw|authority/i, error.message, name)
    end
  end

  def test_interrupt_erases_authority_resets_once_and_does_not_publish
    events = []
    secret = +"test-only-authority"
    publisher = FakePublisher.new(events)
    pilot = build_pilot(events, publisher: publisher, sampler_error: Interrupt.new("raw interrupt"))

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      run_pilot(pilot, events, secret: secret)
    end

    assert_equal "interrupted", error.code
    assert_equal "", secret
    assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
    assert_empty publisher.files
  end

  def test_preserves_a_safe_sampler_failure_code_without_changing_the_public_disposition
    events = []
    publisher = FakePublisher.new(events)
    sampler_error = XrplReserveStudy::CapacityPilotSamplerError.new(
      "advance-deadline-missed", empty_progress
    )
    pilot = build_pilot(events, publisher: publisher, sampler_error: sampler_error)

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      run_pilot(pilot, events)
    end

    assert_equal "runtime-error", error.code
    assert_equal "advance-deadline-missed", error.progress.fetch("sampling_error_code")
    refute events.any? { |event| event.first == :publish }
  end

  def test_reports_the_safe_post_measurement_stage_when_candidate_restart_fails
    events = []
    publisher = FakePublisher.new(events)
    pilot = build_pilot(
      events, publisher: publisher,
      harness_failures: { "restart-candidate" => RuntimeError.new("raw") }
    )

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      run_pilot(pilot, events)
    end

    assert_equal "runtime-error", error.code
    assert_equal "restart-candidate", error.progress.fetch("pilot_failure_stage")
    refute events.any? { |event| event.first == :publish }
  end

  def test_preserves_safe_sample_progression_categories
    events = []
    publisher = FakePublisher.new(events)
    progress = empty_progress.merge("sample_progression_mismatches" => ["ledger-index", "database"])
    sampler_error = XrplReserveStudy::CapacityPilotSamplerError.new(
      "sample-ledger-binding-mismatch", progress
    )
    pilot = build_pilot(events, publisher: publisher, sampler_error: sampler_error)

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      run_pilot(pilot, events)
    end

    assert_equal ["ledger-index", "database"], error.progress.fetch("sample_progression_mismatches")
  end

  # Break caught: a safe sampler abort being collapsed into generic incompletion.
  def test_abort_rule_breach_preserves_disposition_and_progress_at_every_schedule_boundary
    boundaries = [[1, 0], [2, 1], [450, 1], [451, 2], [900, 2], [901, 3]]
    boundaries.each do |sample_count, transaction_count|
      events = []
      secret = +"test-only-authority"
      publisher = FakePublisher.new(events)
      sampling = terminal_sampling_result(
        "abort-rule-breach", sample_count: sample_count,
        transaction_count: transaction_count
      )
      pilot = build_pilot(events, publisher: publisher, sampling_result: sampling)

      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
        run_pilot(pilot, events, secret: secret)
      end

      assert_equal "abort-rule-breach", error.code, [sample_count, transaction_count]
      assert_equal sample_count, error.progress.fetch("sample_count"), sample_count
      assert_equal transaction_count, error.progress.fetch("validated_transaction_count"), sample_count
      assert_equal transaction_count, error.progress.fetch("completed_record_count"), sample_count
      assert_equal "", secret, sample_count
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, sample_count
      refute events.any? { |event| %i[recover reduce publish].include?(event.first) }, sample_count
      assert_empty publisher.files, sample_count
    end
  end

  # Break caught: terminal sampler states being conflated or unknown states being accepted.
  def test_terminal_sampler_statuses_are_explicit_and_unknown_status_is_rejected
    {
      "interrupted" => "interrupted",
      "runtime-error" => "runtime-error",
      "incomplete" => "incomplete",
      "unexpected-state" => "runtime-error"
    }.each do |status, expected_code|
      events = []
      publisher = FakePublisher.new(events)
      pilot = build_pilot(
        events, publisher: publisher,
        sampling_result: terminal_sampling_result(status, sample_count: 2, transaction_count: 1)
      )

      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError, status) do
        run_pilot(pilot, events)
      end

      assert_equal expected_code, error.code, status
      assert_equal 2, error.progress.fetch("sample_count"), status
      assert_equal 1, error.progress.fetch("validated_transaction_count"), status
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, status
      assert_empty publisher.files, status
    end
  end

  # Break caught: recovery-local empty progress erasing a complete measurement set.
  def test_recovery_interrupt_and_runtime_failures_keep_complete_sampling_progress
    recovery_failures = [
      ["before-probe-interrupt", XrplReserveStudy::CapacityPilotSamplerError.new("interrupted", empty_progress),
       "interrupted"],
      ["before-probe-runtime", XrplReserveStudy::CapacityPilotSamplerError.new("recovery-runtime-error", empty_progress),
       "runtime-error"],
      ["during-probe-interrupt", Interrupt.new, "interrupted"],
      ["during-probe-runtime", RuntimeError.new("raw"), "runtime-error"],
      ["after-probe-interrupt", XrplReserveStudy::CapacityPilotSamplerError.new("interrupted", empty_progress),
       "interrupted"],
      ["after-probe-runtime", XrplReserveStudy::CapacityPilotSamplerError.new("recovery-runtime-error", empty_progress),
       "runtime-error"]
    ]
    recovery_failures.each do |stage, recovery_error, expected_code|
      events = []
      secret = +"test-only-authority"
      publisher = FakePublisher.new(events)
      pilot = build_pilot(
        events, publisher: publisher, recovery_error: recovery_error,
        sampling_result: terminal_sampling_result("completed", sample_count: 901, transaction_count: 3)
      )

      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError, stage) do
        run_pilot(pilot, events, secret: secret)
      end

      assert_equal expected_code, error.code, stage
      assert_equal 901, error.progress.fetch("sample_count"), stage
      assert_equal 3, error.progress.fetch("validated_transaction_count"), stage
      assert_equal 3, error.progress.fetch("completed_record_count"), stage
      assert_equal "", secret, stage
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, stage
      assert_empty publisher.files, stage
    end
  end

  def test_unconfirmed_reset_or_changed_binding_forbids_publication
    [
      [{ harness_failures: { "reset" => RuntimeError.new("raw") } }, "reset-failure"],
      [{ revalidate_error: [nil, RuntimeError.new("raw")] }, "binding-failure"]
    ].each do |settings, expected_code|
      events = []
      publisher = FakePublisher.new(events)
      pilot = build_pilot(events, publisher: publisher, **settings)

      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
        run_pilot(pilot, events)
      end
      assert_equal expected_code, error.code
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
      refute events.any? { |event| event.first == :publish }
      assert_empty publisher.files
    end
  end

  # Break caught: an outer reset timeout can strand a TERM-resistant query subtree.
  def test_outer_reset_timeout_reaps_query_wrapper_and_all_descendants_without_publication
    survivors = []
    10.times do |iteration|
      pids = []
      Dir.mktmpdir("pilot-reset-tree-") do |directory|
        pid_path = File.join(directory, "query-tree.pids")
        log_path = File.join(directory, "docker.log")
        docker_path = File.join(directory, "docker")
        docker_program = <<~SH
          #!/bin/sh
          printf '%s\n' "$*" >> #{log_path}
          if [ "$1" = "compose" ]; then
            exit 0
          fi
          if [ "$1" = "ps" ]; then
            trap '' TERM
            sleep 30 &
            descendant=$!
            printf '%s\n%s\n%s\n' "$PPID" "$$" "$descendant" > #{pid_path}
            wait "$descendant"
          fi
          exit 70
        SH
        File.write(docker_path, docker_program)
        File.chmod(0o755, docker_path)
        File.write(log_path, "")

        events = []
        secret = +"test-only-authority"
        publisher = FakePublisher.new(events)
        real_runner = XrplReserveStudy::CapacityFunctionalSmoke::HarnessRunner.new(timeout_seconds: 1.0)
        runner = Object.new
        runner.define_singleton_method(:call) do |command, run_id|
          events << [command, run_id]
          real_runner.call(command, run_id) if command == "reset"
          true
        end
        pilot = build_pilot(events, publisher: publisher, harness_runner: runner)
        original_path = ENV.fetch("PATH")
        begin
          ENV["PATH"] = "#{directory}:#{original_path}"
          error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError, iteration) do
            run_pilot(pilot, events, secret: secret)
          end
        ensure
          ENV["PATH"] = original_path
        end

        assert_equal "reset-failure", error.code, iteration
        assert_equal "", secret, iteration
        assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, iteration
        assert_equal 1, File.readlines(log_path).count { |line| line.include?(" down --volumes") }, iteration
        refute events.any? { |event| event.first == :publish }, iteration
        assert_empty publisher.files, iteration
        assert File.exist?(pid_path), "query tree pid file missing at iteration #{iteration}"
        pids = File.readlines(pid_path, chomp: true).map { |value| Integer(value) }
        survivors << [iteration, pids.select { |pid| process_alive?(pid) }] unless
          processes_gone_within?(pids, 0.7)
      ensure
        Array(pids).each do |pid|
          Process.kill("KILL", pid) if process_alive?(pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end

    assert_empty survivors
  end

  def test_validation_and_each_staging_failure_remain_after_one_confirmed_reset
    failures = [
      { validator_error: RuntimeError.new("raw") },
      { fail_name: "pilot-result.json" },
      { fail_name: "transactions.jsonl" },
      { fail_name: "samples.jsonl" },
      { fail_name: "metrics-summary.json" },
      { fail_name: "SHA256SUMS" }
    ]
    failures.each do |settings|
      events = []
      publisher = FakePublisher.new(events, fail_name: settings[:fail_name])
      pilot = build_pilot(events, publisher: publisher, validator_error: settings[:validator_error])

      assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) { run_pilot(pilot, events) }
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
      refute events.any? { |event| event.first == "up-candidate" && events.count { |e| e.first == "up-candidate" } > 1 }
    end
  end

  # Break caught: a manifest can be schema-shaped while binding a different source or runtime bundle.
  def test_default_input_loader_revalidates_exact_source_manifest_environment_and_runtime_inputs
    with_real_fixed_inputs do |source, probe, config_dir, workload_dir, manifest_dir|
      loader = XrplReserveStudy::CapacityNonCountedPilot::InputLoader.new(
        source_control: source, environment_probe: probe
      )
      snapshot = loader.load(
        run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir,
        manifest_dir: manifest_dir
      )

      assert_equal RUN_ID, snapshot.dig("pilot_bundle", "run", "run_id")
      assert_equal 3, snapshot.dig("pilot_bundle", "intents").length
      assert_equal Digest::SHA256.file(File.join(manifest_dir, "run-manifest.json")).hexdigest,
                   snapshot.fetch("manifest_sha256")
      assert loader.revalidate(snapshot)

      manifest_path = File.join(manifest_dir, "run-manifest.json")
      checksums_path = File.join(manifest_dir, "SHA256SUMS")
      original_manifest = File.binread(manifest_path)
      original_checksums = File.binread(checksums_path)
      changed_manifest = JSON.parse(original_manifest)
      changed_manifest["base_reserve_xrp"] = 0.25
      changed_manifest["base_reserve_drops"] = 250_000
      changed_bytes = "#{JSON.pretty_generate(changed_manifest)}\n"
      File.binwrite(manifest_path, changed_bytes)
      File.binwrite(
        checksums_path,
        "#{Digest::SHA256.hexdigest(changed_bytes)}  run-manifest.json\n"
      )
      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
        loader.load(
          run_id: RUN_ID, config_dir: config_dir, workload_dir: workload_dir,
          manifest_dir: manifest_dir
        )
      end
      assert_equal "input-failure", error.code
      File.binwrite(manifest_path, original_manifest)
      File.binwrite(checksums_path, original_checksums)

      accounts = File.join(workload_dir, "accounts.jsonl")
      File.binwrite(accounts, File.binread(accounts).sub("\n", " \n"))
      error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) { loader.revalidate(snapshot) }
      assert_equal "input-failure", error.code
    end
  end

  # Break caught: closed schemas alone do not prove digest, deterministic destination, or sensitive-value binding.
  def test_real_artifact_validator_accepts_only_exact_complete_sanitized_bundle
    snapshot = artifact_snapshot
    sampling = full_sampling_result(snapshot.fetch("pilot_bundle"))
    recovery = deep_freeze(
      "recovered" => true, "recovery_seconds" => 2.5,
      "validated_ledger" => {
        "validated_ledger_index" => 2, "validated_ledger_hash" => format("%064X", 2)
      }
    )
    summary = XrplReserveStudy::CapacityMetrics::Reducer.new.summarize(
      post_warmup: sampling.fetch("post_warmup_sample"),
      measurement_samples: sampling.fetch("measurement_samples"),
      attempted_transactions: 3, validated_successes: 3,
      restart_started_seconds: 2_100.0, tracking_resumed_seconds: 2_102.5
    )
    pilot = build_pilot([], publisher: FakePublisher.new([]))
    artifacts = pilot.send(:build_artifacts, snapshot, sampling, recovery, summary)
    validator = XrplReserveStudy::CapacityNonCountedPilot::ArtifactValidator.new

    assert validator.validate_artifacts!(
      snapshot: snapshot, sampling: sampling, recovery: recovery,
      summary: summary, result: artifacts.fetch("result"), bytes: artifacts.fetch("bytes")
    )

    changed = Marshal.load(Marshal.dump(artifacts.fetch("bytes")))
    changed["transactions.jsonl"] = changed.fetch("transactions.jsonl").sub(
      '"destination_account":', '"secret":"forbidden","destination_account":'
    )
    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      validator.validate_artifacts!(
        snapshot: snapshot, sampling: sampling, recovery: recovery,
        summary: summary, result: artifacts.fetch("result"), bytes: changed
      )
    end
    assert_equal "validation-failure", error.code
  end

  # Break caught: restart recovery can accept an unrelated ledger or candidate identity.
  def test_candidate_ledger_boundary_advances_once_and_recovers_only_exact_verified_candidate
    client = Object.new
    calls = []
    responses = [
      { "ledger_current_index" => 4 },
      { "status" => "success", "validated" => true, "ledger_index" => 3, "ledger_hash" => "B" * 64,
        "ledger" => { "ledger_index" => 3, "ledger_hash" => "B" * 64 } },
      { "info" => { "build_version" => "3.3.0", "network_id" => 21_338, "peers" => 0,
                      "validation_quorum" => 0,
                      "validated_ledger" => { "seq" => 3, "hash" => "B" * 64,
                                                "reserve_base_xrp" => 0.5 } } }
    ]
    client.define_singleton_method(:call) do |command, parameters = {}|
      calls << [command, parameters]
      responses.shift
    end
    boundary = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory::CandidateLedgerBoundary.new(
      client: client, expected_reserve: 0.5
    )
    previous = deep_freeze("validated_ledger_index" => 2, "validated_ledger_hash" => "A" * 64)

    assert_equal(
      { "validated_ledger_index" => 3, "validated_ledger_hash" => "B" * 64 },
      boundary.advance(previous_ledger: previous)
    )
    assert_equal(
      { "validated_ledger_index" => 3, "validated_ledger_hash" => "B" * 64 },
      boundary.validated_ledger
    )
    assert_equal %w[ledger_accept ledger server_info], calls.map(&:first)
  end

  def test_candidate_ledger_boundary_rejects_non_success_ledger_status
    client = Object.new
    responses = [
      { "ledger_current_index" => 4 },
      { "status" => "error", "validated" => true, "ledger_index" => 3, "ledger_hash" => "B" * 64,
        "ledger" => { "ledger_index" => 3, "ledger_hash" => "B" * 64 } }
    ]
    client.define_singleton_method(:call) { |_command, _parameters = {}| responses.shift }
    boundary = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory::CandidateLedgerBoundary.new(
      client: client, expected_reserve: 0.5
    )
    previous = deep_freeze("validated_ledger_index" => 2, "validated_ledger_hash" => "A" * 64)

    error = assert_raises(XrplReserveStudy::CapacityNonCountedPilotError) do
      boundary.advance(previous_ledger: previous)
    end
    assert_equal "ledger-boundary-failure", error.code
  end

  # Break caught: broad boundary rescue converting or delaying an operator Interrupt.
  def test_candidate_ledger_boundary_re_raises_raw_interrupt_at_every_rpc_position
    previous = deep_freeze(
      "validated_ledger_index" => 2, "validated_ledger_hash" => "A" * 64
    )
    [1, 2].each do |interrupt_call|
      calls = 0
      client = Object.new
      client.define_singleton_method(:call) do |_command, _parameters = {}|
        calls += 1
        raise Interrupt if calls == interrupt_call
        { "ledger_current_index" => 4 }
      end
      boundary = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory::CandidateLedgerBoundary.new(
        client: client, expected_reserve: 0.5
      )

      assert_raises(Interrupt) { boundary.advance(previous_ledger: previous) }
    end

    client = Object.new
    client.define_singleton_method(:call) { |_command, _parameters = {}| raise Interrupt }
    boundary = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory::CandidateLedgerBoundary.new(
      client: client, expected_reserve: 0.5
    )
    assert_raises(Interrupt) { boundary.validated_ledger }
  end

  def test_default_sampler_factory_constructs_the_reviewed_engine_stack_without_runtime_calls
    sampler = XrplReserveStudy::CapacityNonCountedPilot::SamplerFactory.new.call(artifact_snapshot)
    assert_instance_of XrplReserveStudy::CapacityPilotSampler, sampler
  end

  private

  def build_pilot(events, publisher: FakePublisher.new(events), thresholds_passed: true,
                  harness_failures: {}, sampler_error: nil, recovery_error: nil,
                  reducer_error: nil, validator_error: nil, load_error: nil, revalidate_error: nil,
                  sampling_result: completed_sampling_result, harness_runner: nil, **)
    snapshot = deep_freeze(
      "source_commit" => SOURCE_COMMIT,
      "manifest_sha256" => HASH,
      "protocol_sha256" => HASH,
      "binding_fingerprint" => HASH,
      "pilot_bundle" => { "run" => {}, "intents" => [] }
    )
    sampler = FakeSampler.new(events, result: sampling_result,
                              run_error: sampler_error, recovery_error: recovery_error)
    clock_values = [100.0, 100.0]
    XrplReserveStudy::CapacityNonCountedPilot.new(
      input_loader: FakeInputLoader.new(
        events, snapshot: snapshot, load_error: load_error, revalidate_error: revalidate_error
      ),
      harness_runner: harness_runner || FakeHarness.new(events, failures: harness_failures),
      sampler_factory: ->(_snapshot) { sampler },
      reducer: FakeReducer.new(events, thresholds_passed: thresholds_passed, error: reducer_error),
      artifact_validator: FakeValidator.new(events, error: validator_error),
      publisher: publisher,
      sleeper: ->(seconds) { events << [:sleep, seconds] },
      monotonic_clock: -> { clock_values.shift || 100.0 }
    )
  end

  def run_pilot(pilot, events, secret: +"test-only-authority", secret_error: nil)
    pilot.run(
      run_id: RUN_ID, config_dir: CONFIG_DIR, workload_dir: WORKLOAD_DIR,
      manifest_dir: MANIFEST_DIR, output_dir: OUTPUT_DIR,
      secret_reader: lambda {
        events << [:read_secret]
        raise secret_error if secret_error
        secret
      }
    )
  end

  def completed_sampling_result
    ledger = deep_freeze("validated_ledger_index" => 901, "validated_ledger_hash" => "A" * 64)
    deep_freeze(
      "status" => "completed", "post_warmup_sample" => { "sample_sequence" => 0 },
      "measurement_samples" => [{ "sample_sequence" => 900, "validated_ledger_index" => 901,
                                    "validated_ledger_hash" => "A" * 64 }],
      "transaction_records" => [{ "ordinal" => 1 }, { "ordinal" => 2 }, { "ordinal" => 3 }],
      "sample_count" => 901, "validated_transaction_count" => 3,
      "completed_record_count" => 3, "abort_rule_breaches" => [], "final_ledger" => ledger
    )
  end

  def terminal_sampling_result(status, sample_count:, transaction_count:)
    post_warmup = sample_count.positive? ? { "sample_sequence" => 0 } : nil
    measurement_count = [sample_count - 1, 0].max
    measurements = Array.new(measurement_count) do |index|
      {
        "sample_sequence" => index + 1,
        "validated_ledger_index" => index + 2,
        "validated_ledger_hash" => format("%064X", index + 2)
      }
    end
    transactions = Array.new(transaction_count) { |index| { "ordinal" => index + 1 } }
    deep_freeze(
      "status" => status,
      "post_warmup_sample" => post_warmup,
      "measurement_samples" => measurements,
      "transaction_records" => transactions,
      "sample_count" => sample_count,
      "validated_transaction_count" => transaction_count,
      "completed_record_count" => transaction_count,
      "abort_rule_breaches" => status == "abort-rule-breach" ? ["free-disk-bytes"] : []
    )
  end

  def empty_progress
    deep_freeze("sample_count" => 0, "validated_transaction_count" => 0,
                "completed_record_count" => 0, "transaction_records" => [],
                "post_warmup_sample" => nil, "measurement_samples" => [])
  end

  def event_index(events, value)
    events.index do |event|
      value.is_a?(Symbol) ? event.first == value : event == value
    end
  end

  def processes_gone_within?(pids, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return true unless pids.any? { |pid| process_alive?(pid) }
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
    when Array then value.each { |nested| deep_freeze(nested) }
    end
    value.freeze
  end

  FakeSourceControl = Struct.new(:commit) do
    def clean_head
      commit
    end

    def tracked_blob(commit:, path:)
      output, status = Open3.capture2("git", "show", "#{commit}:#{path}", chdir: ROOT)
      raise "missing source blob" unless status.success?
      output
    end
  end

  FakeProbe = Struct.new(:environment) do
    def capture
      Marshal.load(Marshal.dump(environment))
    end
  end

  def with_real_fixed_inputs
    runtime = File.join(XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT, RUN_ID)
    FileUtils.rm_rf(runtime)
    config_dir = File.join(runtime, "config")
    workload_dir = File.join(runtime, "workload", "pilot-000000003")
    manifest_dir = File.join(runtime, "manifests", "non-counted-pilot-000000003")
    XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: RUN_ID, output_dir: config_dir)
    XrplReserveStudy::WorkloadGenerator.new.generate(
      run_id: RUN_ID, scope: "pilot", pilot_accounts: 3, output_dir: workload_dir
    )
    commit = `git rev-parse HEAD`.strip
    source = FakeSourceControl.new(commit)
    environment = {
      "docker_server_version" => "28.3.2", "host_architecture" => "arm64",
      "host_operating_system" => "docker-desktop", "host_logical_cpus" => 8,
      "host_memory_bytes" => 17_179_869_184,
      "candidate_image_digest" => XrplReserveStudy::CapacityEnvironmentProbe::IMAGE_DIGEST,
      "candidate_image_architecture" => "amd64", "native_architecture_eligible" => false
    }
    probe = FakeProbe.new(environment)
    XrplReserveStudy::CapacityRunManifest.new(
      environment_probe: probe, source_control: source,
      clock: -> { Time.utc(2026, 8, 5, 0, 0, 0) }
    ).publish(
      run_id: RUN_ID, pilot_accounts: 3, config_dir: config_dir,
      workload_dir: workload_dir, output_dir: manifest_dir
    )
    yield source, probe, config_dir, workload_dir, manifest_dir
  ensure
    FileUtils.rm_rf(runtime) if runtime
  end

  def artifact_snapshot
    locked = XrplReserveStudy::LockedCapacityInputs.new(
      error_class: XrplReserveStudy::CapacityNonCountedPilotError
    )
    run = locked.study.plan.fetch("runs").find { |entry| entry.fetch("run_id") == RUN_ID }
    generator = XrplReserveStudy::WorkloadGenerator.new(inputs: locked)
    intents = 1.upto(3).map do |ordinal|
      {
        "ordinal" => ordinal, "transaction_type" => "Payment",
        "source_account" => XrplReserveStudy::WorkloadGenerator::SOURCE_ACCOUNT,
        "destination_account" => generator.send(:derived_destination, RUN_ID, ordinal),
        "amount_drops" => "500000", "network_id" => 21_338
      }
    end
    schema_names = %w[
      capacity-run-manifest-v1.schema.json capacity-pilot-execution-v1.schema.json
      capacity-pilot-result-v1.schema.json capacity-metric-sample-v1.schema.json
      capacity-metrics-summary-v1.schema.json
    ]
    deep_freeze(
      "source_commit" => SOURCE_COMMIT, "manifest_sha256" => HASH,
      "protocol_sha256" => Digest::SHA256.file(
        File.join(XrplReserveStudy::RuntimePublisher::REPOSITORY_ROOT, "capacity", "pilot-protocol-v1.yml")
      ).hexdigest,
      "binding_fingerprint" => HASH,
      "pilot_bundle" => { "run" => Marshal.load(Marshal.dump(run)), "intents" => intents },
      "schemas" => schema_names.to_h do |name|
        [name, JSON.parse(File.binread(File.join(XrplReserveStudy::RuntimePublisher::REPOSITORY_ROOT, "schemas", name)))]
      end
    )
  end

  def full_sampling_result(bundle)
    post = metric_sample(0, 300.0, 2, "post-warmup")
    measurements = 1.upto(900).map { |sequence| metric_sample(sequence, 300.0 + (sequence * 2), 2 + sequence, "measurement") }
    schedules = [[1, 1], [2, 450], [3, 900]]
    records = schedules.map do |ordinal, sequence|
      deep_freeze(
        "schema_version" => "capacity-pilot-execution-v1", "execution_scope" => "non-counted-pilot",
        "run_id" => RUN_ID, "ordinal" => ordinal,
        "destination_account" => bundle.fetch("intents").fetch(ordinal - 1).fetch("destination_account"),
        "measurement_sample_sequence" => sequence, "transaction_hash" => format("%064X", ordinal),
        "preliminary_result" => "tesSUCCESS", "final_result" => "tesSUCCESS",
        "validated_ledger_index" => 2 + sequence, "validated_ledger_hash" => format("%064X", 2 + sequence),
        "destination_accountroot_verified" => true, "status" => "validated-success", "counted_run" => false
      )
    end
    deep_freeze(
      "status" => "completed", "post_warmup_sample" => post,
      "measurement_samples" => measurements, "transaction_records" => records,
      "sample_count" => 901, "validated_transaction_count" => 3,
      "completed_record_count" => 3, "abort_rule_breaches" => []
    )
  end

  def metric_sample(sequence, elapsed, ledger, phase)
    deep_freeze(
      "schema_version" => "capacity-metric-sample-v1", "phase" => phase,
      "sample_sequence" => sequence, "elapsed_seconds" => elapsed,
      "validated_ledger_index" => ledger, "validated_ledger_hash" => format("%064X", ledger),
      "ledger_close_time" => ledger, "ledger_state_bytes" => 1_000 + sequence,
      "database_bytes" => 2_000 + sequence, "resident_memory_bytes" => 3_000,
      "memory_current_bytes" => 4_000,
      "memory_limit_bytes" => XrplReserveStudy::CapacityMetrics::Reducer::MEMORY_LIMIT_BYTES,
      "process_cpu_seconds" => sequence.to_f,
      "allocated_logical_cpus" => XrplReserveStudy::CapacityMetrics::Reducer::ALLOCATED_LOGICAL_CPUS,
      "free_disk_bytes" => 20_000_000_000, "disk_total_bytes" => 40_000_000_000
    )
  end
end
