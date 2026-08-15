# frozen_string_literal: true

require "digest"
require "json"

module XrplReserveStudy
  class WorkloadGenerationError < StudyError; end

  class WorkloadGenerator
    BASE58_ALPHABET = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz"
    DERIVATION_DOMAIN = "xrpl-reserve-calibration/keyless-account-id-v1"
    DERIVATION_DESCRIPTION =
      'sha256(input)[0,20], input=xrpl-reserve-calibration/keyless-account-id-v1\0<study_id>\0<random_seed>\0<run_id>\0<ordinal>; reserved retry=sha256(input||\0retry\0<N>)[0,20]; address=base58(version-byte-0||account-id||first-4(double-sha256(version-byte-0||account-id))), alphabet=rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz'
    SOURCE_ACCOUNT = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    NETWORK_ID = 21_338
    RESERVED_ACCOUNT_IDS = [("\0" * 20).b, (("\0" * 19) + "\1").b].freeze

    def self.encode_account_id(account_id)
      unless account_id.is_a?(String) && account_id.bytesize == 20
        raise ArgumentError, "AccountID must contain exactly 20 bytes"
      end

      payload = "\0".b + account_id.b
      checksum = Digest::SHA256.digest(Digest::SHA256.digest(payload)).byteslice(0, 4)
      bytes = payload + checksum
      leading_zeroes = bytes.bytes.take_while(&:zero?).length
      number = bytes.unpack1("H*").to_i(16)
      encoded = +""
      while number.positive?
        number, remainder = number.divmod(58)
        encoded << BASE58_ALPHABET[remainder]
      end

      (BASE58_ALPHABET[0] * leading_zeroes) + encoded.reverse
    end

    def initialize(inputs: nil)
      @inputs = inputs || LockedCapacityInputs.new(error_class: WorkloadGenerationError)
      @study = @inputs.study
      @publisher = RuntimePublisher.new(
        error_class: WorkloadGenerationError,
        failure_label: "capacity workload"
      )
    end

    def generate(run_id:, scope:, output_dir:, pilot_accounts: nil)
      run = planned_run(run_id)
      generated_count = generated_count!(scope, pilot_accounts, run.fetch("account_count"))
      reserve_drops = (run.fetch("base_reserve_xrp") * 1_000_000).round

      artifact_sha256 = @publisher.publish(output_dir) do |staging|
        staging.open("accounts.jsonl") do |file|
          (1..generated_count).each do |ordinal|
            file.write(JSON.generate(account_record(run, reserve_drops, ordinal)))
            file.write("\n")
          end
        end
        accounts_sha256 = staging.sha256("accounts.jsonl")

        staging.write(
          "manifest.json",
          "#{JSON.pretty_generate(manifest(run, scope, generated_count, reserve_drops, accounts_sha256))}\n"
        )
        manifest_sha256 = staging.sha256("manifest.json")
        sums = {
          "accounts.jsonl" => accounts_sha256,
          "manifest.json" => manifest_sha256
        }
        staging.write(
          "SHA256SUMS",
          sums.keys.sort.map { |name| "#{sums.fetch(name)}  #{name}\n" }.join
        )
        sums
      end

      {
        "run_id" => run.fetch("run_id"),
        "generation_scope" => scope,
        "generated_account_count" => generated_count,
        "artifact_sha256" => artifact_sha256
      }
    end

    private

    def planned_run(run_id)
      run = @study.plan.fetch("runs").find { |candidate| candidate.fetch("run_id") == run_id }
      raise WorkloadGenerationError, "unknown planned run ID: #{run_id}" unless run

      run
    end

    def generated_count!(scope, pilot_accounts, planned_count)
      case scope
      when "pilot"
        unless pilot_accounts.is_a?(Integer) && pilot_accounts.between?(1, planned_count)
          raise WorkloadGenerationError,
                "pilot account count must be an integer between 1 and #{planned_count}"
        end
        pilot_accounts
      when "full-plan"
        unless pilot_accounts.nil?
          raise WorkloadGenerationError, "pilot account count is not supported for full-plan generation"
        end
        planned_count
      else
        raise WorkloadGenerationError, "generation scope must be pilot or full-plan"
      end
    end

    def account_record(run, reserve_drops, ordinal)
      {
        "ordinal" => ordinal,
        "transaction_type" => "Payment",
        "source_account" => SOURCE_ACCOUNT,
        "destination_account" => derived_destination(run.fetch("run_id"), ordinal),
        "amount_drops" => reserve_drops.to_s,
        "network_id" => NETWORK_ID
      }
    end

    def derived_destination(run_id, ordinal)
      sequence = [
        DERIVATION_DOMAIN,
        @study.data.fetch("study_id"),
        @study.data.fetch("random_seed").to_s,
        run_id,
        ordinal.to_s
      ].join("\0").b
      retry_number = 0
      loop do
        retry_suffix = retry_number.zero? ? "".b : "\0retry\0#{retry_number}".b
        account_id = digest_account_id_input(sequence + retry_suffix).byteslice(0, 20)
        return self.class.encode_account_id(account_id) unless RESERVED_ACCOUNT_IDS.include?(account_id)

        retry_number += 1
      end
    end

    def digest_account_id_input(bytes)
      Digest::SHA256.digest(bytes)
    end

    def manifest(run, scope, generated_count, reserve_drops, accounts_sha256)
      {
        "schema_version" => "capacity-workload-v1",
        "study_id" => @study.data.fetch("study_id"),
        "study_sha256" => @inputs.input_sha256.fetch("study/reserve-calibration-v1.yml"),
        "run_id" => run.fetch("run_id"),
        "workload_name" => @study.data.fetch("workload").fetch("name"),
        "generation_scope" => scope,
        "counted_run" => false,
        "base_reserve_xrp" => run.fetch("base_reserve_xrp"),
        "base_reserve_drops" => reserve_drops,
        "planned_account_count" => run.fetch("account_count"),
        "generated_account_count" => generated_count,
        "repetition" => run.fetch("repetition"),
        "network_id" => NETWORK_ID,
        "source_account" => SOURCE_ACCOUNT,
        "destination_model" => "keyless-synthetic-account-id-v1",
        "private_keys_generated" => false,
        "signing_state" => "unsigned-intents",
        "account_id_derivation" => DERIVATION_DESCRIPTION,
        "accounts_path" => "accounts.jsonl",
        "accounts_sha256" => accounts_sha256
      }
    end
  end
end
