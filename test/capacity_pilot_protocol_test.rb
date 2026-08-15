# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "yaml"
require_relative "../lib/xrpl_reserve_study"

class CapacityPilotProtocolTest < Minitest::Test
  class ThreeLike
    def ==(other)
      other == 3
    end
  end

  ROOT = File.expand_path("..", __dir__)
  PROTOCOL_PATH = File.join(ROOT, "capacity", "pilot-protocol-v1.yml")
  LOCK_PATH = File.join(ROOT, "capacity", "candidate-inputs.lock.json")
  RUNTIME_PACING = {
    "target_cadence_seconds" => 2.0,
    "target_mode" => "absolute-monotonic",
    "maximum_target_lateness_seconds" => 1.0,
    "observed_boundary" => "ledger-advancement-completion",
    "consecutive_completion_interval_seconds" => { "minimum" => 1.0, "maximum" => 3.0 },
    "scheduled_preparation_stage" => "before-target"
  }.freeze

  def test_accepts_only_the_exact_fixed_protocol_and_recursively_freezes_it
    protocol = XrplReserveStudy::CapacityPilotProtocol.load(File.binread(PROTOCOL_PATH))

    assert_equal record, protocol.data
    assert_deeply_frozen protocol.data
    assert_equal [
      { "ordinal" => 1, "measurement_sample_sequence" => 1 },
      { "ordinal" => 2, "measurement_sample_sequence" => 450 },
      { "ordinal" => 3, "measurement_sample_sequence" => 900 }
    ], protocol.data.fetch("transaction_schedule")
    assert_raises(FrozenError) { protocol.data["pilot_accounts"] = 4 }
  end

  def test_rejects_unknown_missing_wrong_order_wrong_type_and_changed_values
    mutations = [
      ->(value) { value["extra"] = false },
      ->(value) { value.delete("status") },
      ->(value) { value["pilot_accounts"] = ThreeLike.new },
      ->(value) { value["pilot_accounts"] = 4 },
      ->(value) { value["warmup_seconds"] = 301 },
      ->(value) { value["measurement_seconds"] = 1_799 },
      ->(value) { value["sample_cadence_seconds"] = 2.0 },
      ->(value) { value["measurement_sample_count"] = 899 },
      ->(value) { value["total_sample_count"] = 900 },
      ->(value) { value.delete("sample_cadence_basis") },
      ->(value) { value["transaction_type"] = "OfferCreate" },
      ->(value) { value["transaction_type"] = :Payment },
      ->(value) { value["scheduled_transactions_per_step"] = 2 },
      ->(value) { value["scheduled_step_operation_order"].reverse! },
      ->(value) { value["unscheduled_transactions_per_step"] = 1 },
      ->(value) { value["unscheduled_step_operation"] = "advance-after-transaction" },
      ->(value) { value["sample_cadence_basis"] = "between-sample-captures" },
      ->(value) { value.fetch("controlled_restart")["recovery_success_condition"] = "process-running" },
      ->(value) { value.fetch("controlled_restart").delete("recovery_success_condition") },
      ->(value) { value.fetch("controlled_restart")["recovery_success_condition"] = true },
      ->(value) { value.fetch("controlled_restart")["extra"] = false },
      lambda do |value|
        restart = value.fetch("controlled_restart")
        first = restart.to_a.first
        restart.delete(first.first)
        restart[first.first] = first.last
      end,
      ->(value) { value["native_execution_established"] = true },
      ->(value) { value["counted_execution_authorized"] = true },
      ->(value) { value["transaction_schedule"].reverse! },
      ->(value) { value["transaction_schedule"].first["measurement_sample_sequence"] = 2 },
      ->(value) { value["transaction_schedule"].first["extra"] = false },
      ->(value) { value["success_requirements"].reverse! },
      lambda do |value|
        first = value.to_a.first
        value.delete(first.first)
        value[first.first] = first.last
      end
    ]

    mutations.each do |mutation|
      changed = Marshal.load(Marshal.dump(record))
      mutation.call(changed)
      assert_protocol_rejected { XrplReserveStudy::CapacityPilotProtocol.new(changed) }
    end
  end

  # Break caught: leaving runtime scheduling tolerance implicit or permitting a drifted pacing window.
  def test_freezes_the_exact_runtime_pacing_policy
    protocol = XrplReserveStudy::CapacityPilotProtocol.load(File.binread(PROTOCOL_PATH))

    assert_equal RUNTIME_PACING, protocol.data["runtime_pacing"]

    mutations = [
      ->(pacing) { pacing["target_cadence_seconds"] = 2 },
      ->(pacing) { pacing["target_mode"] = "relative" },
      ->(pacing) { pacing["maximum_target_lateness_seconds"] = 1.001 },
      ->(pacing) { pacing["observed_boundary"] = "advance-call-start" },
      ->(pacing) { pacing.fetch("consecutive_completion_interval_seconds")["minimum"] = 0.999 },
      ->(pacing) { pacing.fetch("consecutive_completion_interval_seconds")["maximum"] = 3.001 },
      ->(pacing) { pacing["scheduled_preparation_stage"] = "at-target" },
      ->(pacing) { pacing["extra"] = false },
      ->(pacing) { pacing.delete("maximum_target_lateness_seconds") }
    ]
    mutations.each do |mutation|
      changed = Marshal.load(Marshal.dump(record))
      mutation.call(changed.fetch("runtime_pacing"))
      assert_protocol_rejected { XrplReserveStudy::CapacityPilotProtocol.new(changed) }
    end
  end

  def test_rejects_alias_duplicate_key_and_multiple_documents
    original = File.binread(PROTOCOL_PATH)
    alias_bytes = original.sub("candidate_specific: true", "candidate_specific: &truth true")
                          .sub("native_execution_established: false", "native_execution_established: *truth")
    duplicate = original.sub("pilot_accounts: 3", "pilot_accounts: 4\npilot_accounts: 3")
    second = original + "---\ncounted_execution_authorized: true\n"

    [alias_bytes, duplicate, second].each do |bytes|
      assert_protocol_rejected { XrplReserveStudy::CapacityPilotProtocol.load(bytes) }
    end
  end

  def test_locked_inputs_bind_exactly_four_sources_and_reject_changed_bytes
    locked = XrplReserveStudy::LockedCapacityInputs.new(sources: input_sources)

    assert_equal 4, locked.verified_inputs.length
    assert_instance_of XrplReserveStudy::CapacityPilotProtocol, locked.pilot_protocol
    assert_equal Digest::SHA256.hexdigest(File.binread(PROTOCOL_PATH)),
                 locked.input_sha256.fetch("capacity/pilot-protocol-v1.yml")

    absent = input_sources.tap { |sources| sources.delete("capacity/pilot-protocol-v1.yml") }
    assert_locked_rejected(absent)
    assert_locked_rejected(input_sources.merge("unexpected" => "bytes"))
    changed = input_sources
    changed["capacity/pilot-protocol-v1.yml"] = changed.fetch("capacity/pilot-protocol-v1.yml").sub(
      "pilot_accounts: 3", "pilot_accounts: 4"
    )
    assert_locked_rejected(changed)

    extra_descriptor = input_sources
    lock = JSON.parse(extra_descriptor.fetch("capacity/candidate-inputs.lock.json"))
    lock.fetch("inputs").fetch("capacity/pilot-protocol-v1.yml")["extra"] = false
    extra_descriptor["capacity/candidate-inputs.lock.json"] = JSON.generate(lock)
    assert_locked_rejected(extra_descriptor)

    duplicate_lock = input_sources
    duplicate_lock["capacity/candidate-inputs.lock.json"] = duplicate_lock.fetch(
      "capacity/candidate-inputs.lock.json"
    ).sub('"schema_version": 1', '"schema_version": 2, "schema_version": 1')
    assert_locked_rejected(duplicate_lock)
  end

  def test_locked_inputs_reject_symlink_fifo_and_oversized_protocol
    with_replaced_protocol_file do |backup|
      File.symlink(backup, PROTOCOL_PATH)
      assert_raises(XrplReserveStudy::StudyError) { XrplReserveStudy::LockedCapacityInputs.new }
    end

    with_replaced_protocol_file do
      assert system("mkfifo", PROTOCOL_PATH)
      assert_raises(XrplReserveStudy::StudyError) { XrplReserveStudy::LockedCapacityInputs.new }
    end

    oversized = input_sources
    oversized["capacity/pilot-protocol-v1.yml"] = "x" * (XrplReserveStudy::LockedCapacityInputs::MAX_INPUT_BYTES + 1)
    oversized["capacity/candidate-inputs.lock.json"] = lock_for(oversized)
    assert_locked_rejected(oversized)
  end

  private

  def record
    @record ||= YAML.safe_load(File.binread(PROTOCOL_PATH), permitted_classes: [], aliases: false)
  end

  def input_sources
    XrplReserveStudy::LockedCapacityInputs::SOURCE_PATHS.to_h do |path, absolute|
      [path, File.binread(absolute)]
    end
  end

  def lock_for(sources)
    lock = JSON.parse(File.binread(LOCK_PATH))
    lock.fetch("inputs").each_key do |path|
      lock.fetch("inputs").fetch(path)["sha256"] = Digest::SHA256.hexdigest(sources.fetch(path))
    end
    JSON.generate(lock)
  end

  def assert_protocol_rejected(&block)
    error = assert_raises(XrplReserveStudy::CapacityPilotProtocolError, &block)
    assert_equal "invalid capacity pilot protocol", error.message
  end

  def assert_locked_rejected(sources)
    assert_raises(XrplReserveStudy::StudyError) do
      XrplReserveStudy::LockedCapacityInputs.new(sources: sources)
    end
  end

  def with_replaced_protocol_file
    backup = "#{PROTOCOL_PATH}.test-#{Process.pid}"
    File.rename(PROTOCOL_PATH, backup)
    yield backup
  ensure
    File.unlink(PROTOCOL_PATH) if File.exist?(PROTOCOL_PATH) || File.symlink?(PROTOCOL_PATH)
    File.rename(backup, PROTOCOL_PATH) if File.exist?(backup)
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash then value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array then value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
