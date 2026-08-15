# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class CompleteReservesWorkloadError < StudyError; end

  class CompleteReservesWorkload
    STUDY_PATH = File.expand_path("../../study/complete-reserves-v1.yml", __dir__)

    def initialize(study: CompleteReservesStudy.new(STUDY_PATH))
      @study = study
      @study_sha256 = Digest::SHA256.file(STUDY_PATH).hexdigest
      @publisher = RuntimePublisher.new(error_class: CompleteReservesWorkloadError, failure_label: "complete reserves workload")
    end

    def generate(run:, distribution:, output_dir:)
      canonical_run = locked_run!(run, distribution)
      distribution_hash = canonical_hash(distribution)
      allocations = allocation(distribution.fetch("class_counts"), canonical_run.fetch("scale"))
      accounts = (1..canonical_run.fetch("account_root_target")).map { |ordinal| account_record(canonical_run, distribution_hash, ordinal) }
      objects = allocations.flat_map { |klass, count| (1..count).map { |ordinal| object_record(canonical_run, distribution_hash, klass, ordinal) } }
      sums = @publisher.publish(output_dir) do |staging|
        write_jsonl(staging, "accounts.jsonl", accounts)
        write_jsonl(staging, "objects.jsonl", objects)
        account_sha = staging.sha256("accounts.jsonl")
        object_sha = staging.sha256("objects.jsonl")
        manifest = {
          "schema_version" => "complete-reserves-workload-v1", "study_sha256" => @study_sha256,
          "distribution_sha256" => distribution_hash, "run_id" => canonical_run.fetch("run_id"),
          "account_intent_count" => accounts.length, "object_intent_count" => objects.length,
          "class_allocations" => allocations, "private_keys_generated" => false, "signing_state" => "unsigned-intents",
          "accounts_sha256" => account_sha, "objects_sha256" => object_sha
        }
        staging.write("manifest.json", JSON.pretty_generate(manifest) + "\n")
        manifest_sha = staging.sha256("manifest.json")
        staging.write("SHA256SUMS", [[account_sha, "accounts.jsonl"], [manifest_sha, "manifest.json"], [object_sha, "objects.jsonl"]].sort_by(&:last).map { |sha, name| "#{sha}  #{name}\n" }.join)
        { "accounts.jsonl" => account_sha, "objects.jsonl" => object_sha, "manifest.json" => manifest_sha }
      end
      { "run_id" => canonical_run.fetch("run_id"), "account_intent_count" => accounts.length,
        "object_intent_count" => objects.length, "artifact_sha256" => sums }.freeze
    end

    private

    def locked_run!(run, distribution)
      raise CompleteReservesWorkloadError, "invalid distribution" unless valid_distribution?(distribution)
      expected = @study.plan(distribution: { "account_roots" => distribution.fetch("account_roots"), "owned_objects" => distribution.fetch("class_counts").values.sum }).fetch("runs")
      canonical = expected.find { |candidate| candidate.fetch("run_id") == run["run_id"] }
      raise CompleteReservesWorkloadError, "unknown or altered complete reserves run" unless canonical == run
      canonical
    end

    def valid_distribution?(value)
      value.is_a?(Hash) && value["account_roots"].is_a?(Integer) && value["account_roots"].positive? && value["class_counts"].is_a?(Hash) &&
        value["class_counts"].all? { |name, count| OwnerObjectDistribution::CLASSIFIERS.value?(name) && count.is_a?(Integer) && count >= 0 }
    end

    def allocation(counts, scale)
      raw = counts.sort.to_h { |name, count| [name, Rational(count) * Rational(scale.to_s)] }
      target = (counts.values.sum * scale).ceil
      result = raw.transform_values(&:floor)
      raw.sort_by { |name, value| [-(value - value.floor), name] }.first(target - result.values.sum).each { |name, _| result[name] += 1 }
      result.freeze
    end

    def account_record(run, distribution_hash, ordinal)
      { "ordinal" => ordinal, "account_id" => identity(run, distribution_hash, "account_root", ordinal) }
    end

    def object_record(run, distribution_hash, klass, ordinal)
      { "object_type" => klass, "ordinal" => ordinal, "owner" => identity(run, distribution_hash, klass, ordinal) }
    end

    def identity(run, distribution_hash, klass, ordinal)
      Digest::SHA256.hexdigest(["complete-reserves-workload-v1", @study_sha256, distribution_hash, run.fetch("run_id"), klass, ordinal].join("\0"))[0, 40]
    end

    def write_jsonl(staging, name, records)
      staging.open(name) { |file| records.each { |record| file.write(JSON.generate(record) + "\n") } }
    end

    def canonical_hash(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end
  end
end
