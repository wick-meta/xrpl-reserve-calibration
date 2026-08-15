# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/xrpl_reserve_study"

class ProtocolAlignmentTest < Minitest::Test
  class FalseLike
    def ==(other)
      other.equal?(false)
    end
  end

  ROOT = File.expand_path("..", __dir__)
  ALIGNMENT_PATH = File.join(ROOT, "study", "protocol-alignment-v1.yml")
  LOCK_PATH = File.join(ROOT, "capacity", "candidate-inputs.lock.json")
  STUDY_PATH = File.join(ROOT, "study", "reserve-calibration-v1.yml")
  CONFIG_PATH = File.join(ROOT, "capacity", "config", "rippled.cfg")
  PILOT_PROTOCOL_PATH = File.join(ROOT, "capacity", "pilot-protocol-v1.yml")

  def test_accepts_only_the_closed_prospective_record_and_deeply_freezes_it
    alignment = XrplReserveStudy::ProtocolAlignment.new(record)

    assert_equal record, alignment.data
    assert_deeply_frozen alignment.data
    assert_raises(FrozenError) { alignment.data.fetch("resolution")["counted_execution_authorized"] = true }
  end

  def test_rejects_unknown_missing_symbol_and_non_string_top_level_fields
    mutations = [
      ->(value) { value["unexpected"] = "value" },
      ->(value) { value.delete("status") },
      ->(value) { value[:status] = value.delete("status") },
      ->(value) { value["status"] = :resolved_prospectively }
    ]

    mutations.each do |mutation|
      assert_rejected { XrplReserveStudy::ProtocolAlignment.new(mutated_record(&mutation)) }
    end
  end

  def test_rejects_closed_reference_target_and_resolution_mutations
    mutations = [
      ->(value) { value.fetch("original_reference")["unknown"] = "value" },
      ->(value) { value.fetch("candidate_execution_target").delete("commit") },
      ->(value) { value.fetch("candidate_execution_target")["release_url"] = "https://example.invalid" },
      ->(value) { value.fetch("candidate_execution_target")["commit"] = "0" * 40 },
      ->(value) { value.fetch("resolution")["implementation_equivalence_claimed"] = true },
      ->(value) { value.fetch("resolution")["cross_version_pooling_allowed"] = true },
      ->(value) { value.fetch("resolution")["cross_version_generalization_allowed"] = true },
      ->(value) { value.fetch("resolution")["original_study_modified"] = true },
      ->(value) { value.fetch("resolution")["matrix_modified"] = true },
      ->(value) { value.fetch("resolution")["metrics_modified"] = true },
      ->(value) { value.fetch("resolution")["thresholds_modified"] = true },
      ->(value) { value.fetch("resolution")["abort_rules_modified"] = true },
      ->(value) { value.fetch("resolution")["randomization_modified"] = true },
      ->(value) { value.fetch("resolution")["counted_execution_authorized"] = true }
    ]

    mutations.each do |mutation|
      assert_rejected { XrplReserveStudy::ProtocolAlignment.new(mutated_record(&mutation)) }
    end
  end

  def test_rejects_equality_overriding_non_boolean_resolution_values
    mutated = mutated_record do |value|
      value.fetch("resolution")["counted_execution_authorized"] = FalseLike.new
    end

    assert_rejected { XrplReserveStudy::ProtocolAlignment.new(mutated) }
  end

  def test_rejects_impact_order_disposition_or_remaining_gate_mutations
    mutations = [
      ->(value) { value.fetch("source_impact_assessment").reverse! },
      ->(value) { value.fetch("source_impact_assessment").first["disposition"] = "equivalent" },
      ->(value) { value.fetch("source_impact_assessment").first["extra"] = "value" },
      ->(value) { value.fetch("remaining_gates") << "counted-execution" },
      ->(value) { value["remaining_gates"] = ["native-execution", "pilot-validation"] }
    ]

    mutations.each do |mutation|
      assert_rejected { XrplReserveStudy::ProtocolAlignment.new(mutated_record(&mutation)) }
    end
  end

  def test_locked_inputs_bind_the_alignment_record_once_and_expose_only_validated_data
    locked = XrplReserveStudy::LockedCapacityInputs.new(sources: input_sources)

    assert_equal 4, locked.verified_inputs.length
    assert_equal Digest::SHA256.hexdigest(File.binread(ALIGNMENT_PATH)),
                 locked.input_sha256.fetch("study/protocol-alignment-v1.yml")
    assert_instance_of XrplReserveStudy::ProtocolAlignment, locked.protocol_alignment
    assert_deeply_frozen locked.protocol_alignment.data
  end

  def test_locked_inputs_reject_absent_extra_malformed_mismatched_and_changed_alignment_inputs
    absent = input_sources
    absent.delete("study/protocol-alignment-v1.yml")
    assert_locked_rejected(absent)

    extra = input_sources.merge("unexpected" => "bytes")
    assert_locked_rejected(extra)

    malformed = input_sources
    malformed["capacity/candidate-inputs.lock.json"] = "not-json"
    assert_locked_rejected(malformed)

    mismatched = input_sources
    mismatched["study/protocol-alignment-v1.yml"] = "schema_version: altered\n"
    assert_locked_rejected(mismatched)

    changed = input_sources
    changed["study/protocol-alignment-v1.yml"] = changed.fetch("study/protocol-alignment-v1.yml").sub(
      "resolved-prospectively", "resolved-retrospectively"
    )
    assert_locked_rejected(changed)
  end

  def test_locked_inputs_reject_symlink_fifo_and_yaml_alias_alignment_files
    with_replaced_alignment_file do |backup_path|
      File.symlink(backup_path, ALIGNMENT_PATH)
      assert_raises(XrplReserveStudy::StudyError) do
        XrplReserveStudy::LockedCapacityInputs.new
      end
    end

    with_replaced_alignment_file do
      assert system("mkfifo", ALIGNMENT_PATH)
      assert File.lstat(ALIGNMENT_PATH).pipe?, "FIFO probe was not installed"
      assert_raises(XrplReserveStudy::StudyError) { XrplReserveStudy::LockedCapacityInputs.new }
    end

    aliases = input_sources
    aliases["study/protocol-alignment-v1.yml"] = File.binread(ALIGNMENT_PATH).sub(
      "  implementation_equivalence_claimed: false\n  cross_version_pooling_allowed: false",
      "  implementation_equivalence_claimed: &false_value false\n  cross_version_pooling_allowed: *false_value"
    )
    aliases["capacity/candidate-inputs.lock.json"] = lock_for(aliases)
    assert_rejected { XrplReserveStudy::ProtocolAlignment.load(aliases.fetch("study/protocol-alignment-v1.yml")) }
    assert_locked_rejected(aliases)
  end

  def test_rejects_duplicate_mapping_keys_at_every_closed_record_level
    duplicates = {
      "top-level" => duplicate_alignment_bytes("status: rejected\nstatus: resolved-prospectively"),
      "reference" => duplicate_alignment_bytes("  release: rejected\n  release: 3.1.3"),
      "resolution" => duplicate_alignment_bytes(
        "  implementation_equivalence_claimed: true\n  implementation_equivalence_claimed: false"
      ),
      "impact" => duplicate_alignment_bytes(
        "  - area: changed\n    area: reserve-semantics", target: "  - area: reserve-semantics"
      )
    }

    duplicates.each_value do |bytes|
      assert_rejected { XrplReserveStudy::ProtocolAlignment.load(bytes) }
      sources = input_sources
      sources["study/protocol-alignment-v1.yml"] = bytes
      sources["capacity/candidate-inputs.lock.json"] = lock_for(sources)
      assert_locked_rejected(sources)
    end
  end

  def test_rejects_a_contradictory_second_yaml_document_directly_and_through_the_recomputed_lock
    bytes = alignment_with_contradictory_second_document

    assert_rejected { XrplReserveStudy::ProtocolAlignment.load(bytes) }

    sources = input_sources
    sources["study/protocol-alignment-v1.yml"] = bytes
    sources["capacity/candidate-inputs.lock.json"] = lock_for(sources)
    assert_locked_rejected(sources)
  end

  private

  def record
    @record ||= YAML.safe_load(File.binread(ALIGNMENT_PATH), permitted_classes: [], aliases: false)
  end

  def mutated_record
    value = Marshal.load(Marshal.dump(record))
    yield value
    value
  end

  def input_sources
    {
      "capacity/candidate-inputs.lock.json" => File.binread(LOCK_PATH),
      "study/reserve-calibration-v1.yml" => File.binread(STUDY_PATH),
      "capacity/config/rippled.cfg" => File.binread(CONFIG_PATH),
      "study/protocol-alignment-v1.yml" => File.binread(ALIGNMENT_PATH),
      "capacity/pilot-protocol-v1.yml" => File.binread(PILOT_PROTOCOL_PATH)
    }
  end

  def assert_rejected(&block)
    error = assert_raises(XrplReserveStudy::ProtocolAlignmentError, &block)
    refute_empty error.message
  end

  def assert_locked_rejected(sources)
    error = assert_raises(XrplReserveStudy::StudyError) do
      XrplReserveStudy::LockedCapacityInputs.new(sources: sources)
    end
    refute_empty error.message
  end

  def lock_for(sources)
    lock = JSON.parse(File.binread(LOCK_PATH))
    lock.fetch("inputs").each_key do |path|
      lock.fetch("inputs").fetch(path)["sha256"] = Digest::SHA256.hexdigest(sources.fetch(path))
    end
    JSON.generate(lock)
  end

  def duplicate_alignment_bytes(replacement, target: replacement.split("\n").last)
    original = File.binread(ALIGNMENT_PATH)
    original.sub(target, replacement)
  end

  def alignment_with_contradictory_second_document
    File.binread(ALIGNMENT_PATH) + <<~YAML
      ---
      resolution:
        counted_execution_authorized: true
    YAML
  end

  def with_replaced_alignment_file
    backup_path = "#{ALIGNMENT_PATH}.protocol-alignment-test-#{Process.pid}"
    File.rename(ALIGNMENT_PATH, backup_path)
    yield backup_path
  ensure
    File.unlink(ALIGNMENT_PATH) if File.exist?(ALIGNMENT_PATH) || File.symlink?(ALIGNMENT_PATH)
    File.rename(backup_path, ALIGNMENT_PATH) if File.exist?(backup_path)
  end

  def assert_deeply_frozen(value)
    assert value.frozen?, "#{value.class} was mutable"
    case value
    when Hash
      value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array
      value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
