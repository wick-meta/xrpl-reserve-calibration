# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "time"
require_relative "../lib/xrpl_reserve_study"
require_relative "schema_validator"

class CapacityRunManifestTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RUNTIME_ROOT = File.join(ROOT, "capacity", "runtime")
  RUN_ID = "r0500000-a000010000-n01"
  PILOT_ACCOUNTS = 3
  SOURCE_COMMIT = "a" * 40
  CREATED_AT = Time.utc(2026, 8, 4, 1, 2, 3, 456_789)
  IMAGE = "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70"
  EXPECTED_ALIGNMENT = {
    "status" => "resolved-prospectively",
    "method" => "prospective-candidate-specific-amendment",
    "alignment_sha256" => Digest::SHA256.file(File.join(ROOT, "study", "protocol-alignment-v1.yml")).hexdigest,
    "implementation_equivalence_claimed" => false,
    "cross_version_pooling_allowed" => false,
    "cross_version_generalization_allowed" => false,
    "counted_execution_authorized" => false,
    "remaining_gates" => %w[pilot-validation native-execution]
  }.freeze
  EXPECTED_PILOT_PROTOCOL_SHA256 = Digest::SHA256.file(
    File.join(ROOT, "capacity", "pilot-protocol-v1.yml")
  ).hexdigest
  EXPECTED_RUNTIME_PACING = {
    "target_cadence_seconds" => 2.0,
    "target_mode" => "absolute-monotonic",
    "maximum_target_lateness_seconds" => 1.0,
    "observed_boundary" => "ledger-advancement-completion",
    "consecutive_completion_interval_seconds" => { "minimum" => 1.0, "maximum" => 3.0 },
    "scheduled_preparation_stage" => "before-target"
  }.freeze

  FakeSourceControl = Struct.new(:commit) do
    def clean_head
      commit
    end

    def tracked_blob(commit:, path:)
      File.binread(File.join(ROOT, path))
    end
  end

  FakeCommandRunner = Struct.new(:outputs, :calls) do
    def call(argv)
      calls << argv
      outputs.fetch(calls.length - 1)
    end
  end

  FakeProbe = Struct.new(:value) do
    def capture
      Marshal.load(Marshal.dump(value))
    end
  end

  def test_publishes_the_exact_non_counted_manifest_and_checksum_without_overwrite
    with_inputs do |config_dir, workload_dir, output_dir|
      manifest = publisher.publish(
        run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
        workload_dir: workload_dir, output_dir: output_dir
      )

      assert_equal %w[SHA256SUMS run-manifest.json], Dir.children(output_dir).sort
      assert_equal manifest, JSON.parse(File.binread(File.join(output_dir, "run-manifest.json")))
      assert_equal "capacity-run-manifest-v1", manifest.fetch("schema_version")
      assert_equal "non-counted-pilot", manifest.fetch("manifest_scope")
      assert_equal false, manifest.fetch("counted_run")
      assert_equal false, manifest.fetch("pilot_complete")
      assert_equal SOURCE_COMMIT, manifest.fetch("source_commit")
      assert_equal 3, manifest.fetch("generated_account_count")
      assert_equal 21_338, manifest.fetch("network_id")
      assert_equal IMAGE, manifest.dig("candidate_runtime", "image_digest")
      assert_equal EXPECTED_ALIGNMENT, manifest.fetch("protocol_alignment")
      assert_equal EXPECTED_PILOT_PROTOCOL_SHA256, manifest.dig("pilot_protocol", "protocol_sha256")
      assert_equal EXPECTED_RUNTIME_PACING, manifest.dig("pilot_protocol", "runtime_pacing")
      assert_equal false, manifest.dig("pilot_protocol", "native_execution_established")
      assert_equal false, manifest.dig("pilot_protocol", "counted_execution_authorized")
      assert_equal XrplReserveStudy::CapacityMetrics::Reducer::METRIC_NAMES, manifest.fetch("metric_names")
      assert_equal CREATED_AT.iso8601(6), manifest.fetch("created_at")
      assert_equal expected_environment, manifest.fetch("environment")
      assert_deeply_frozen manifest

      expected_sum = Digest::SHA256.file(File.join(output_dir, "run-manifest.json")).hexdigest
      assert_equal "#{expected_sum}  run-manifest.json\n", File.binread(File.join(output_dir, "SHA256SUMS"))
      assert_raises(XrplReserveStudy::CapacityRunManifestError) do
        publisher.publish(
          run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
          workload_dir: workload_dir, output_dir: output_dir
        )
      end
    end
  end

  def test_manifest_is_closed_and_copies_locked_thresholds_and_protocol_hashes
    with_inputs do |config_dir, workload_dir, output_dir|
      manifest = publisher.publish(
        run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
        workload_dir: workload_dir, output_dir: output_dir
      )
      assert_equal %w[acceptance_thresholds abort_rules base_reserve_drops base_reserve_xrp candidate_runtime
                      counted_run created_at environment generated_account_count inputs manifest_scope metric_names
                      metric_protocol network_id pilot_complete planned_account_count preregistered_protocol_reference
                      protocol_alignment pilot_protocol repetition run_id run_order_index schema_version source_commit study_id
                      study_sha256 warmup_seconds workload_name measurement_seconds].sort, manifest.keys.sort
      study = XrplReserveStudy::LockedCapacityInputs.new.study.data
      assert_equal study.fetch("acceptance_thresholds"), manifest.fetch("acceptance_thresholds")
      assert_equal study.fetch("abort_rules"), manifest.fetch("abort_rules")
      refute_same study.fetch("acceptance_thresholds"), manifest.fetch("acceptance_thresholds")
      assert_equal Digest::SHA256.file(File.join(ROOT, "docs", "metrics-protocol-v1.md")).hexdigest,
                   manifest.dig("metric_protocol", "document_sha256")
      assert_equal Digest::SHA256.file(File.join(ROOT, "schemas", "capacity-metric-sample-v1.schema.json")).hexdigest,
                   manifest.dig("metric_protocol", "sample_schema_sha256")
      assert_equal Digest::SHA256.file(File.join(ROOT, "schemas", "capacity-metrics-summary-v1.schema.json")).hexdigest,
                   manifest.dig("metric_protocol", "summary_schema_sha256")

      schema = JSON.parse(File.binread(File.join(ROOT, "schemas", "capacity-run-manifest-v1.schema.json")))
      assert TestSchemaValidator.valid?(schema, manifest)
      [
        manifest.merge("generated_account_count" => 0),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("status" => "mismatch")),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("method" => "retrospective")),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("alignment_sha256" => "0" * 64)),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("alignment_sha256" => manifest.dig("protocol_alignment", "alignment_sha256") + "\n")),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("implementation_equivalence_claimed" => true)),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("cross_version_pooling_allowed" => true)),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("cross_version_generalization_allowed" => true)),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("counted_execution_authorized" => true)),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("remaining_gates" => ["native-execution", "pilot-validation"])),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").reject { |key, _| key == "method" }),
        manifest.merge("protocol_alignment" => manifest.fetch("protocol_alignment").merge("extra" => false)),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("transaction_type" => "OfferCreate")),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("scheduled_transactions_per_step" => 2)),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("scheduled_step_operation_order" => manifest.dig("pilot_protocol", "scheduled_step_operation_order").reverse)),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("unscheduled_transactions_per_step" => 1)),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("sample_cadence_basis" => "between-sample-captures")),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge(
          "runtime_pacing" => manifest.dig("pilot_protocol", "runtime_pacing").merge("maximum_target_lateness_seconds" => 1.001)
        )),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge(
          "runtime_pacing" => manifest.dig("pilot_protocol", "runtime_pacing").merge(
            "consecutive_completion_interval_seconds" => { "minimum" => 1.0, "maximum" => 3.001 }
          )
        )),
        manifest.merge("pilot_protocol" => manifest.fetch("pilot_protocol").merge("controlled_restart" => manifest.dig("pilot_protocol", "controlled_restart").merge("recovery_success_condition" => "process-running"))),
        manifest.merge("environment" => manifest.fetch("environment").merge("docker_server_version" => "free form/path")),
        manifest.merge("environment" => manifest.fetch("environment").merge("docker_server_version" => "28.3.2\n")),
        manifest.merge("environment" => manifest.fetch("environment").merge("docker_server_version" => "28.3.2\r\n")),
        manifest.merge("source_commit" => manifest.fetch("source_commit") + "\n"),
        manifest.merge("source_commit" => manifest.fetch("source_commit") + "\r\n"),
        manifest.merge("run_id" => manifest.fetch("run_id") + "\n"),
        manifest.merge("run_id" => manifest.fetch("run_id") + "\r\n"),
        manifest.merge("study_sha256" => manifest.fetch("study_sha256") + "\n"),
        manifest.merge("study_sha256" => manifest.fetch("study_sha256") + "\r\n")
      ].each { |invalid| refute TestSchemaValidator.valid?(schema, invalid) }
    end
  end

  def test_protocol_hashes_use_immutable_captured_commit_blobs
    immutable = tracked_source_blobs.merge(
      "docs/metrics-protocol-v1.md" => "immutable protocol",
      "schemas/capacity-metric-sample-v1.schema.json" => "immutable sample",
      "schemas/capacity-metrics-summary-v1.schema.json" => "immutable summary"
    )
    source = FakeSourceControl.new(SOURCE_COMMIT)
    source.define_singleton_method(:tracked_blob) { |commit:, path:| immutable.fetch(path) }
    with_inputs do |config_dir, workload_dir, output_dir|
      manifest = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: source, clock: -> { CREATED_AT }
      ).publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                workload_dir: workload_dir, output_dir: output_dir)
      assert_equal Digest::SHA256.hexdigest("immutable protocol"), manifest.dig("metric_protocol", "document_sha256")
      assert_equal Digest::SHA256.hexdigest("immutable sample"), manifest.dig("metric_protocol", "sample_schema_sha256")
      assert_equal Digest::SHA256.hexdigest("immutable summary"), manifest.dig("metric_protocol", "summary_schema_sha256")
    end
  end

  def test_alignment_digest_and_semantics_use_the_same_immutable_source_commit
    commit_b = "b" * 40
    blobs = tracked_source_blobs
    changed_alignment = blobs.fetch("study/protocol-alignment-v1.yml") + "# immutable source formatting\n"
    blobs["study/protocol-alignment-v1.yml"] = changed_alignment
    lock = JSON.parse(blobs.fetch("capacity/candidate-inputs.lock.json"))
    lock.fetch("inputs").fetch("study/protocol-alignment-v1.yml")["sha256"] =
      Digest::SHA256.hexdigest(changed_alignment)
    blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(lock)}\n"
    source = FakeSourceControl.new(commit_b)
    source.define_singleton_method(:tracked_blob) { |commit:, path:| blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      publisher = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: source, clock: -> { CREATED_AT }
      )
      manifest = publisher.publish(
        run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
        workload_dir: workload_dir, output_dir: output_dir
      )
      assert_equal commit_b, manifest.fetch("source_commit")
      assert_equal Digest::SHA256.hexdigest(changed_alignment), manifest.dig("protocol_alignment", "alignment_sha256")
      assert_equal EXPECTED_ALIGNMENT.reject { |key, _| key == "alignment_sha256" },
                   manifest.fetch("protocol_alignment").reject { |key, _| key == "alignment_sha256" }
    end

    invalid_blobs = tracked_source_blobs
    invalid_alignment = invalid_blobs.fetch("study/protocol-alignment-v1.yml").sub(
      "status: resolved-prospectively", "status: mismatch"
    )
    invalid_blobs["study/protocol-alignment-v1.yml"] = invalid_alignment
    invalid_lock = JSON.parse(invalid_blobs.fetch("capacity/candidate-inputs.lock.json"))
    invalid_lock.fetch("inputs").fetch("study/protocol-alignment-v1.yml")["sha256"] =
      Digest::SHA256.hexdigest(invalid_alignment)
    invalid_blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(invalid_lock)}\n"
    invalid_source = FakeSourceControl.new("c" * 40)
    invalid_source.define_singleton_method(:tracked_blob) { |commit:, path:| invalid_blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      publisher = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: invalid_source, clock: -> { CREATED_AT }
      )
      assert_manifest_error do
        publisher.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                          workload_dir: workload_dir, output_dir: output_dir)
      end
      refute File.exist?(output_dir)
    end
  end

  def test_pilot_protocol_digest_and_semantics_use_the_same_immutable_source_commit
    commit_b = "b" * 40
    blobs = tracked_source_blobs
    changed_protocol = blobs.fetch("capacity/pilot-protocol-v1.yml") + "# immutable source formatting\n"
    blobs["capacity/pilot-protocol-v1.yml"] = changed_protocol
    lock = JSON.parse(blobs.fetch("capacity/candidate-inputs.lock.json"))
    lock.fetch("inputs").fetch("capacity/pilot-protocol-v1.yml")["sha256"] =
      Digest::SHA256.hexdigest(changed_protocol)
    blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(lock)}\n"
    source = FakeSourceControl.new(commit_b)
    source.define_singleton_method(:tracked_blob) { |commit:, path:| blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      manifest = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: source, clock: -> { CREATED_AT }
      ).publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                workload_dir: workload_dir, output_dir: output_dir)
      assert_equal commit_b, manifest.fetch("source_commit")
      assert_equal Digest::SHA256.hexdigest(changed_protocol), manifest.dig("pilot_protocol", "protocol_sha256")
      assert_equal 3, manifest.dig("pilot_protocol", "pilot_accounts")
      assert_equal false, manifest.dig("pilot_protocol", "counted_execution_authorized")
    end

    invalid_blobs = tracked_source_blobs
    invalid_protocol = invalid_blobs.fetch("capacity/pilot-protocol-v1.yml").sub(
      "pilot_accounts: 3", "pilot_accounts: 4"
    )
    invalid_blobs["capacity/pilot-protocol-v1.yml"] = invalid_protocol
    invalid_lock = JSON.parse(invalid_blobs.fetch("capacity/candidate-inputs.lock.json"))
    invalid_lock.fetch("inputs").fetch("capacity/pilot-protocol-v1.yml")["sha256"] =
      Digest::SHA256.hexdigest(invalid_protocol)
    invalid_blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(invalid_lock)}\n"
    invalid_source = FakeSourceControl.new("c" * 40)
    invalid_source.define_singleton_method(:tracked_blob) { |commit:, path:| invalid_blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      immutable = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: invalid_source, clock: -> { CREATED_AT }
      )
      assert_manifest_error do
        immutable.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                          workload_dir: workload_dir, output_dir: output_dir)
      end
      refute File.exist?(output_dir)
    end
  end

  def test_contradictory_second_alignment_document_cannot_publish_an_immutable_manifest
    blobs = tracked_source_blobs
    alignment = blobs.fetch("study/protocol-alignment-v1.yml") + <<~YAML
      ---
      resolution:
        counted_execution_authorized: true
    YAML
    blobs["study/protocol-alignment-v1.yml"] = alignment
    lock = JSON.parse(blobs.fetch("capacity/candidate-inputs.lock.json"))
    lock.fetch("inputs").fetch("study/protocol-alignment-v1.yml")["sha256"] =
      Digest::SHA256.hexdigest(alignment)
    blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(lock)}\n"
    source = FakeSourceControl.new("d" * 40)
    source.define_singleton_method(:tracked_blob) { |commit:, path:| blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      immutable = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: source, clock: -> { CREATED_AT }
      )
      assert_manifest_error do
        immutable.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                          workload_dir: workload_dir, output_dir: output_dir)
      end
      refute File.exist?(output_dir)
    end
  end

  # Break caught: caching source inputs from commit A while labeling a clean commit B manifest.
  def test_clean_checkout_advance_cannot_mix_cached_inputs_with_the_new_source_commit
    commit_b = "b" * 40
    blobs = tracked_source_blobs
    blobs["capacity/config/rippled.cfg"] = blobs.fetch("capacity/config/rippled.cfg") + "\n"
    lock = JSON.parse(blobs.fetch("capacity/candidate-inputs.lock.json"))
    lock.fetch("inputs").fetch("capacity/config/rippled.cfg")["sha256"] =
      Digest::SHA256.hexdigest(blobs.fetch("capacity/config/rippled.cfg"))
    blobs["capacity/candidate-inputs.lock.json"] = "#{JSON.pretty_generate(lock)}\n"
    source = FakeSourceControl.new(commit_b)
    source.define_singleton_method(:tracked_blob) { |commit:, path:| blobs.fetch(path) }

    with_inputs do |config_dir, workload_dir, output_dir|
      mixed = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment), source_control: source, clock: -> { CREATED_AT }
      )
      assert_manifest_error do
        mixed.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                      workload_dir: workload_dir, output_dir: output_dir)
      end
      refute File.exist?(output_dir)
    end
  end

  def test_rejects_invalid_source_identity_and_uncontained_output
    with_inputs do |config_dir, workload_dir, output_dir|
      bad = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(expected_environment),
        source_control: FakeSourceControl.new("BAD"), clock: -> { CREATED_AT }
      )
      assert_manifest_error do
        bad.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                    workload_dir: workload_dir, output_dir: output_dir)
      end
      assert_manifest_error do
        publisher.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                          workload_dir: workload_dir, output_dir: File.join(Dir.tmpdir, "outside-manifest"))
      end

      invalid_environment = expected_environment.merge("docker_server_version" => "free form/path")
      bad_environment = XrplReserveStudy::CapacityRunManifest.new(
        environment_probe: FakeProbe.new(invalid_environment),
        source_control: FakeSourceControl.new(SOURCE_COMMIT), clock: -> { CREATED_AT }
      )
      error = assert_raises(XrplReserveStudy::CapacityRunManifestError) do
        bad_environment.publish(run_id: RUN_ID, pilot_accounts: PILOT_ACCOUNTS, config_dir: config_dir,
                                workload_dir: workload_dir, output_dir: output_dir)
      end
      assert_equal "capacity run manifest failed", error.message
      refute_includes error.message, "path"
    end
  end

  def test_source_control_uses_fixed_git_argv_and_rejects_dirty_or_moving_head
    clean = FakeCommandRunner.new(["", "#{SOURCE_COMMIT}\n", "", "#{SOURCE_COMMIT}\n"], [])
    assert_equal SOURCE_COMMIT, XrplReserveStudy::CapacityRunManifest::SourceControl.new(command_runner: clean).clean_head
    assert_equal ["git", "-C", ROOT, "status", "--porcelain=v1", "--untracked-files=no"], clean.calls.fetch(0)
    assert_equal ["git", "-C", ROOT, "rev-parse", "--verify", "HEAD"], clean.calls.fetch(1)

    blob_runner = FakeCommandRunner.new(["immutable bytes"], [])
    blob_source = XrplReserveStudy::CapacityRunManifest::SourceControl.new(command_runner: blob_runner)
    assert_equal "immutable bytes", blob_source.tracked_blob(
      commit: SOURCE_COMMIT, path: "docs/metrics-protocol-v1.md"
    )
    assert_equal ["git", "-C", ROOT, "show", "#{SOURCE_COMMIT}:docs/metrics-protocol-v1.md"],
                 blob_runner.calls.fetch(0)

    input_blob_runner = FakeCommandRunner.new(["immutable input"], [])
    input_blob_source = XrplReserveStudy::CapacityRunManifest::SourceControl.new(command_runner: input_blob_runner)
    assert_equal "immutable input", input_blob_source.tracked_blob(
      commit: SOURCE_COMMIT, path: "capacity/candidate-inputs.lock.json"
    )

    dirty = FakeCommandRunner.new([" M tracked\n", "#{SOURCE_COMMIT}\n", "", "#{SOURCE_COMMIT}\n"], [])
    assert_manifest_error do
      XrplReserveStudy::CapacityRunManifest::SourceControl.new(command_runner: dirty).clean_head
    end
    moving = FakeCommandRunner.new(["", "#{SOURCE_COMMIT}\n", "", "#{'b' * 40}\n"], [])
    assert_manifest_error do
      XrplReserveStudy::CapacityRunManifest::SourceControl.new(command_runner: moving).clean_head
    end
  end

  private

  def expected_environment
    {
      "docker_server_version" => "28.3.2", "host_architecture" => "arm64",
      "host_operating_system" => "docker-desktop", "host_logical_cpus" => 8,
      "host_memory_bytes" => 17_179_869_184, "candidate_image_digest" => IMAGE,
      "candidate_image_architecture" => "arm64", "native_architecture_eligible" => true
    }
  end

  def publisher
    probe = FakeProbe.new(expected_environment)
    XrplReserveStudy::CapacityRunManifest.new(
      environment_probe: probe, source_control: FakeSourceControl.new(SOURCE_COMMIT), clock: -> { CREATED_AT }
    )
  end

  def with_inputs
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("run-manifest-", RUNTIME_ROOT) do |root|
      config_dir = File.join(root, "config")
      workload_dir = File.join(root, "workload")
      output_dir = File.join(root, "manifests", "non-counted-pilot-000000003")
      XrplReserveStudy::CandidateConfigRenderer.new.render(run_id: RUN_ID, output_dir: config_dir)
      XrplReserveStudy::WorkloadGenerator.new.generate(
        run_id: RUN_ID, scope: "pilot", pilot_accounts: PILOT_ACCOUNTS, output_dir: workload_dir
      )
      yield config_dir, workload_dir, output_dir
    end
  end

  def tracked_source_blobs
    %w[
      capacity/candidate-inputs.lock.json capacity/config/rippled.cfg docs/metrics-protocol-v1.md
      schemas/capacity-metric-sample-v1.schema.json schemas/capacity-metrics-summary-v1.schema.json
      schemas/capacity-pilot-execution-v1.schema.json schemas/capacity-pilot-result-v1.schema.json
      schemas/capacity-run-manifest-v1.schema.json
      capacity/pilot-protocol-v1.yml study/reserve-calibration-v1.yml study/protocol-alignment-v1.yml
    ].to_h { |path| [path, File.binread(File.join(ROOT, path))] }
  end

  def assert_manifest_error(&block)
    error = assert_raises(XrplReserveStudy::CapacityRunManifestError, &block)
    refute_empty error.message
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash then value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array then value.each { |nested| assert_deeply_frozen(nested) }
    end
  end
end
