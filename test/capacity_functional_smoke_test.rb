# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "timeout"
require_relative "../lib/xrpl_reserve_study"
require_relative "../lib/xrpl_reserve_study/bounded_absence_query"

class CapacityFunctionalSmokeTest < Minitest::Test
  RUN_ID = "r0500000-a000010000-n01"
  CONFIG_DIR = "/validated/config"
  WORKLOAD_DIR = "/validated/workload"
  OUTPUT_DIR = File.join(
    XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT,
    RUN_ID, "execution", "functional-smoke-000000001"
  )

  class FakeInputs
    def initialize(events, error: nil)
      @events = events
      @error = error
    end

    def load(run_id:, config_dir:, workload_dir:)
      @events << [:validate, run_id, config_dir, workload_dir]
      raise @error if @error
      { "validated" => true }
    end
  end

  class FakeHarness
    def initialize(events, errors: {})
      @events = events
      @errors = errors
    end

    def call(command, run_id)
      @events << [command, run_id]
      error = @errors[command]
      error = error.shift if error.is_a?(Array)
      raise error if error
      true
    end
  end

  class FakeEngine
    def initialize(events, result)
      @events = events
      @result = result
    end

    def execute(inputs:, secret:)
      @events << [:execute, inputs, secret.dup]
      raise @result if @result.is_a?(Exception)
      Marshal.load(Marshal.dump(@result))
    ensure
      secret.clear if secret.is_a?(String) && !secret.frozen?
    end
  end

  class FakePublisher
    attr_reader :files

    class Staging
      def initialize(files)
        @files = files
      end

      def write(name, bytes)
        @files[name] = bytes
      end

      def sha256(name)
        Digest::SHA256.hexdigest(@files.fetch(name))
      end
    end

    def initialize(events, error: nil)
      @events = events
      @error = error
      @files = {}
    end

    def publish(output_dir)
      @events << [:publish, output_dir]
      raise @error if @error
      yield Staging.new(@files)
    end
  end

  def test_runs_in_exact_guarded_order_resets_before_atomic_publication_and_returns_sanitized_record
    events = []
    publisher = FakePublisher.new(events)
    smoke = build_smoke(events, publisher: publisher)

    record = smoke.run(
      run_id: RUN_ID, config_dir: CONFIG_DIR, workload_dir: WORKLOAD_DIR,
      output_dir: OUTPUT_DIR, secret_reader: secret_reader(events)
    )

    assert_equal [
      [:validate, RUN_ID, CONFIG_DIR, WORKLOAD_DIR],
      ["up-candidate", RUN_ID],
      ["verify-candidate", RUN_ID],
      [:read_secret],
      [:execute, { "validated" => true }, "fake-only-secret"],
      ["reset", RUN_ID],
      [:publish, OUTPUT_DIR]
    ], events
    assert_equal "passed", record.fetch("status")
    assert_equal "passed", record.fetch("teardown_status")
    assert_equal "2026-08-04T00:00:02.000000Z", record.fetch("teardown_completed_at")
    assert_equal %w[SHA256SUMS execution.json], publisher.files.keys.sort
    execution = publisher.files.fetch("execution.json")
    assert execution.end_with?("\n")
    assert_equal JSON.pretty_generate(record) + "\n", execution
    assert_equal "#{Digest::SHA256.hexdigest(execution)}  execution.json\n", publisher.files.fetch("SHA256SUMS")
    assert_sanitized(record)
    refute events.any? { |event| event.first == :sleep }
  end

  def test_retries_one_failed_complete_verification_before_normal_execution
    events = []
    smoke = build_smoke(events, harness_errors: {
      "verify-candidate" => [XrplReserveStudy::CapacityFunctionalSmokeError.new("not ready")]
    })

    record = run_smoke(smoke, events)

    assert_equal [
      [:validate, RUN_ID, CONFIG_DIR, WORKLOAD_DIR],
      ["up-candidate", RUN_ID],
      ["verify-candidate", RUN_ID],
      [:sleep, 1],
      ["verify-candidate", RUN_ID],
      [:read_secret],
      [:execute, { "validated" => true }, "fake-only-secret"],
      ["reset", RUN_ID],
      [:publish, OUTPUT_DIR]
    ], events
    assert_equal "passed", record.fetch("status")
  end

  def test_retries_two_failed_complete_verifications_before_normal_execution
    events = []
    smoke = build_smoke(events, harness_errors: {
      "verify-candidate" => [
        XrplReserveStudy::CapacityFunctionalSmokeError.new("not ready"),
        XrplReserveStudy::CapacityFunctionalSmokeError.new("still not ready")
      ]
    })

    record = run_smoke(smoke, events)

    assert_equal 1, events.count { |event| event == ["up-candidate", RUN_ID] }
    assert_equal 3, events.count { |event| event == ["verify-candidate", RUN_ID] }
    assert_equal 2, events.count { |event| event == [:sleep, 1] }
    assert_equal 1, events.count { |event| event.first == :read_secret }
    assert_equal 1, events.count { |event| event.first == :execute }
    assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
    assert_equal "passed", record.fetch("status")
  end

  def test_three_failed_verifications_never_read_or_publish_and_reset_once
    events = []
    publisher = FakePublisher.new(events)
    smoke = build_smoke(events, publisher: publisher, harness_errors: {
      "verify-candidate" => [
        XrplReserveStudy::CapacityFunctionalSmokeError.new("not ready"),
        XrplReserveStudy::CapacityFunctionalSmokeError.new("still not ready"),
        XrplReserveStudy::CapacityFunctionalSmokeError.new("not ready")
      ]
    })

    error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events) }

    assert_equal "capacity functional smoke failed", error.message
    assert_equal 1, events.count { |event| event == ["up-candidate", RUN_ID] }
    assert_equal 3, events.count { |event| event == ["verify-candidate", RUN_ID] }
    assert_equal 2, events.count { |event| event == [:sleep, 1] }
    refute events.any? { |event| event.first == :read_secret || event.first == :execute || event.first == :publish }
    assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
    assert_empty publisher.files
  end

  def test_verification_interrupt_is_not_retried_and_resets_once
    events = []
    publisher = FakePublisher.new(events)
    smoke = build_smoke(events, publisher: publisher, harness_errors: { "verify-candidate" => Interrupt.new("stop") })

    error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events) }

    assert_equal "capacity functional smoke failed", error.message
    assert_equal 1, events.count { |event| event == ["up-candidate", RUN_ID] }
    assert_equal 1, events.count { |event| event == ["verify-candidate", RUN_ID] }
    refute events.any? { |event| event.first == :sleep || event.first == :read_secret || event.first == :execute || event.first == :publish }
    assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
    assert_empty publisher.files
  end

  def test_startup_failure_is_not_retried_and_still_resets
    events = []
    smoke = build_smoke(events, harness_errors: { "up-candidate" => RuntimeError.new("start failed") })

    error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events) }

    assert_equal "capacity functional smoke failed", error.message
    assert_equal [
      [:validate, RUN_ID, CONFIG_DIR, WORKLOAD_DIR],
      ["up-candidate", RUN_ID],
      ["reset", RUN_ID]
    ], events
  end

  def test_input_failure_never_starts_reads_secret_resets_or_publishes
    events = []
    smoke = build_smoke(events, input_error: XrplReserveStudy::CapacityExecutionInputError.new("bad input"))

    assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) do
      run_smoke(smoke, events)
    end
    assert_equal [[:validate, RUN_ID, CONFIG_DIR, WORKLOAD_DIR]], events
  end

  def test_start_verify_secret_timeout_and_interrupt_failures_each_reset_once_without_publication
    cases = {
      "start" => { harness_errors: { "up-candidate" => RuntimeError.new("start raw") } },
      "verify" => { harness_errors: { "verify-candidate" => RuntimeError.new("verify raw") } },
      "secret" => { secret_error: IOError.new("secret raw") },
      "timeout" => { engine_result: Timeout::Error.new("timeout raw") },
      "interrupt" => { engine_result: Interrupt.new("interrupt raw") }
    }

    cases.each do |name, settings|
      events = []
      smoke = build_smoke(events, **settings)
      error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError, name) { run_smoke(smoke, events, **settings) }
      assert_equal "capacity functional smoke failed", error.message, name
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, name
      refute events.any? { |event| event.first == :publish }, name
      read_expected = !%w[start verify].include?(name)
      assert_equal read_expected, events.include?([:read_secret]), name
    end
  end

  def test_sanitized_engine_failure_is_published_after_successful_reset_and_returned
    events = []
    failed = execution_record("failed").merge("error_code" => "submission-not-preliminarily-successful")
    engine_error = XrplReserveStudy::CapacityExecutionError.new("submission-not-preliminarily-successful", failed)
    publisher = FakePublisher.new(events)
    smoke = build_smoke(events, engine_result: engine_error, publisher: publisher)

    record = run_smoke(smoke, events)

    assert_equal "failed", record.fetch("status")
    assert_equal "passed", record.fetch("teardown_status")
    assert_operator events.index(["reset", RUN_ID]), :<, events.index([:publish, OUTPUT_DIR])
    assert_sanitized(record)
  end

  def test_failed_reset_never_publishes_success_or_engine_failure
    [execution_record("passed"), XrplReserveStudy::CapacityExecutionError.new(
      "rpc-failure", execution_record("aborted").merge("error_code" => "rpc-failure")
    )].each do |engine_result|
      events = []
      smoke = build_smoke(
        events, engine_result: engine_result,
        harness_errors: { "reset" => RuntimeError.new("reset raw") }
      )
      error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events) }
      assert_equal "capacity functional smoke reset failed", error.message
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
      refute events.any? { |event| event.first == :publish }
    end
  end

  def test_publication_failure_occurs_after_only_one_reset_and_does_not_restart
    events = []
    publisher = FakePublisher.new(events, error: IOError.new("publish raw"))
    smoke = build_smoke(events, publisher: publisher)

    error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events) }
    assert_equal "capacity functional smoke publication failed", error.message
    assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }
    assert_equal 1, events.count { |event| event == ["up-candidate", RUN_ID] }
  end

  def test_real_publisher_creates_exact_files_and_refuses_existing_output
    events = []
    runtime_root = XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT
    FileUtils.mkdir_p(runtime_root)
    Dir.mktmpdir("functional-smoke-", runtime_root) do |parent|
      output = File.join(parent, "outcome")
      smoke = build_smoke(events, publisher: XrplReserveStudy::RuntimePublisher.new(
        error_class: XrplReserveStudy::CapacityFunctionalSmokeError,
        failure_label: "capacity functional smoke outcome"
      ))
      record = run_smoke(smoke, events, output_dir: output)

      assert_equal %w[SHA256SUMS execution.json], Dir.children(output).sort
      assert_equal JSON.pretty_generate(record) + "\n", File.binread(File.join(output, "execution.json"))
      event_count = events.length
      assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) { run_smoke(smoke, events, output_dir: output) }
      assert_equal event_count + 1, events.length
      assert_equal :validate, events.last.first
    end
  end

  def test_closed_execution_record_rejects_raw_and_signed_material_after_reset_without_publication
    mutations = {
      "raw response" => ->(record) { record["raw_response"] = "untrusted" },
      "signature" => ->(record) { record["signature"] = "untrusted" },
      "signing public key" => ->(record) { record["SigningPubKey"] = "untrusted" },
      "transaction signature" => ->(record) { record["TxnSignature"] = "untrusted" },
      "transaction JSON" => ->(record) { record["tx_json"] = { "TransactionType" => "Payment" } },
      "public key" => ->(record) { record["public_key"] = "untrusted" },
      "nested raw response" => ->(record) { record["outcomes"].first["raw_response"] = "untrusted" },
      "nested signature" => ->(record) { record["outcomes"].first["signature"] = "untrusted" },
      "malformed record" => ->(record) { record["counted_run"] = true }
    }

    mutations.each do |name, mutate|
      events = []
      record = execution_record("passed")
      mutate.call(record)
      smoke = build_smoke(events, engine_result: record)

      assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError, name) { run_smoke(smoke, events) }
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, name
      refute events.any? { |event| event.first == :publish }, name
    end
  end

  def test_harness_runner_bounds_pipe_drain_after_leader_exit_and_kills_original_group
    Dir.mktmpdir("harness-runner-") do |directory|
      pid_path = File.join(directory, "descendant.pid")
      program = <<~RUBY
        pid_path = ARGV.fetch(0)
        fork do
          File.binwrite(pid_path, Process.pid.to_s)
          trap("TERM") {}
          sleep 30
        end
      RUBY
      runner = XrplReserveStudy::CapacityFunctionalSmoke::HarnessRunner.new(timeout_seconds: 0.15)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError) do
        runner.send(:run_child, { "PATH" => ENV.fetch("PATH") }, [RbConfig.ruby, "-e", program, pid_path])
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_equal "capacity harness action failed", error.message
      assert_operator elapsed, :>=, 1.1
      assert_operator elapsed, :<, 2
      assert File.exist?(pid_path), "descendant pid was not recorded"
      assert_process_dead(Integer(File.binread(pid_path)))
    end
  end

  # Break caught: an outer KILL racing the complete inner TERM/KILL cleanup budget.
  def test_outer_cleanup_grace_is_frozen_above_complete_inner_termination_budget
    inner_budget = XrplReserveStudy::BoundedAbsenceQuery::CLEANUP_SECONDS * 2
    outer_grace = XrplReserveStudy::CapacityFunctionalSmoke::HarnessRunner::CLEANUP_JOIN_SECONDS

    assert_equal 0.4, inner_budget
    assert_equal 1.0, outer_grace
    assert_operator outer_grace, :>, inner_budget
  end

  def test_rejects_mixed_key_types_in_nested_hashes_after_reset_without_publication
    {
      "workload hash" => ->(record) { record.fetch("workload_sha256")[:unexpected] = "e" * 64 },
      "outcome" => ->(record) { record.fetch("outcomes").first[:unexpected] = "untrusted" }
    }.each do |name, mutation|
      events = []
      record = execution_record("passed")
      mutation.call(record)
      smoke = build_smoke(events, engine_result: record)

      error = assert_raises(XrplReserveStudy::CapacityFunctionalSmokeError, name) { run_smoke(smoke, events) }

      assert_equal "capacity functional smoke record is invalid", error.message, name
      assert_equal 1, events.count { |event| event == ["reset", RUN_ID] }, name
      refute events.any? { |event| event.first == :publish }, name
    end
  end

  private

  def build_smoke(events, input_error: nil, harness_errors: {}, engine_result: execution_record("passed"),
                  publisher: FakePublisher.new(events), **)
    clock_values = [Time.utc(2026, 8, 4, 0, 0, 2)]
    XrplReserveStudy::CapacityFunctionalSmoke.new(
      inputs: FakeInputs.new(events, error: input_error),
      engine: FakeEngine.new(events, engine_result),
      publisher: publisher,
      harness_runner: FakeHarness.new(events, errors: harness_errors),
      sleeper: ->(seconds) { events << [:sleep, seconds] },
      clock: -> { clock_values.shift || Time.utc(2026, 8, 4, 0, 0, 2) }
    )
  end

  def run_smoke(smoke, events, output_dir: OUTPUT_DIR, secret_error: nil, **)
    smoke.run(
      run_id: RUN_ID, config_dir: CONFIG_DIR, workload_dir: WORKLOAD_DIR, output_dir: output_dir,
      secret_reader: secret_reader(events, error: secret_error)
    )
  end

  def secret_reader(events, error: nil)
    lambda do
      events << [:read_secret]
      raise error if error
      +"fake-only-secret"
    end
  end

  def execution_record(status)
    {
      "schema_version" => "capacity-execution-v1",
      "study_id" => "reserve-calibration-v1",
      "study_sha256" => "a" * 64,
      "run_id" => RUN_ID,
      "config_sha256" => "b" * 64,
      "workload_sha256" => { "accounts.jsonl" => "c" * 64, "manifest.json" => "d" * 64 },
      "execution_scope" => "functional-smoke",
      "counted_run" => false,
      "pilot_complete" => false,
      "status" => status,
      "base_reserve_xrp" => 0.5,
      "base_reserve_drops" => 500_000,
      "account_count" => 10_000,
      "repetition" => 1,
      "started_at" => "2026-08-04T00:00:00.000000Z",
      "finished_at" => "2026-08-04T00:00:01.000000Z",
      "attempted_transactions" => status == "passed" ? 1 : 0,
      "validated_successes" => status == "passed" ? 1 : 0,
      "ledger_advancements" => status == "passed" ? 1 : 0,
      "preflight_validated_ledger_index" => 2,
      "final_validated_ledger_index" => 3,
      "final_validated_ledger_hash" => "A" * 64,
      "outcomes" => status == "passed" ? [
        {
          "ordinal" => 1,
          "destination_account" => "rPh7FjNmSnqQGC5zni2dA52UpxgYMy4Yc3",
          "transaction_hash" => "B" * 64,
          "preliminary_engine_result" => "tesSUCCESS",
          "final_transaction_result" => "tesSUCCESS",
          "validated_ledger_index" => 3,
          "account_root_balance_drops" => "500000"
        }
      ] : []
    }
  end

  def assert_sanitized(record)
    serialized = JSON.generate(record)
    refute_match(/raw-secret|raw_response|tx_blob|tx_json|SigningPubKey|TxnSignature|signature|public_key|private_key|seed/i, serialized)
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
