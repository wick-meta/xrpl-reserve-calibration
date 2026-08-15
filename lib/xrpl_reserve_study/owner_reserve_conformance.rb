# frozen_string_literal: true

module XrplReserveStudy
  class OwnerReserveConformanceError < StudyError; end

  class OwnerReserveConformance
    CASES = {
      "trust-line-one-sided" => { "kind" => "trust_line", "expected_owner_delta" => 1 },
      "trust-line-two-sided" => { "kind" => "trust_line", "expected_owner_delta" => 1 },
      "trust-line-first-two" => { "kind" => "trust_line", "expected_owner_delta" => 2 },
      "check-lifecycle" => { "kind" => "check", "expected_owner_delta" => 1 },
      "deposit-preauthorization-lifecycle" => { "kind" => "deposit_preauthorization", "expected_owner_delta" => 1 },
      "escrow-lifecycle" => { "kind" => "escrow", "expected_owner_delta" => 1 },
      "nftoken-offer-lifecycle" => { "kind" => "nftoken_offer", "expected_owner_delta" => 1 },
      "nftoken-page-packing" => { "kind" => "nftoken_page", "expected_owner_delta" => 1 },
      "offer-lifecycle" => { "kind" => "offer", "expected_owner_delta" => 1 },
      "oracle-lifecycle" => { "kind" => "oracle", "expected_owner_delta" => 1 },
      "payment-channel-lifecycle" => { "kind" => "payment_channel", "expected_owner_delta" => 1 },
      "signer-list-lifecycle" => { "kind" => "signer_list", "expected_owner_delta" => 1 },
      "ticket-lifecycle" => { "kind" => "ticket", "expected_owner_delta" => 1 },
      "insufficient-reserve-rejection" => { "kind" => "insufficient_reserve", "expected_owner_delta" => 0 }
    }.freeze

    def initialize(client:)
      @client = client
    end

    def call(case_id:, secret_reader:)
      recipe = CASES[case_id]
      raise OwnerReserveConformanceError, "unknown conformance case" unless recipe
      raise OwnerReserveConformanceError, "isolated candidate network is required" unless @client.isolated?
      secret = secret_reader.call
      raise OwnerReserveConformanceError, "missing signing authority" unless secret.is_a?(String) && !secret.empty?
      observed = @client.exercise(recipe: recipe.merge("case_id" => case_id), secret: secret)
      validate!(observed, recipe)
      locked = observed.fetch("before_balance_drops") - observed.fetch("after_lock_balance_drops")
      released = observed.fetch("after_release_balance_drops") - observed.fetch("after_lock_balance_drops")
      { "schema_version" => "owner-reserve-conformance-v1", "case_id" => case_id, "status" => "passed", "counted_run" => false,
        "object_kind" => recipe.fetch("kind"), "before_balance_drops" => observed.fetch("before_balance_drops"),
        "after_lock_balance_drops" => observed.fetch("after_lock_balance_drops"), "after_release_balance_drops" => observed.fetch("after_release_balance_drops"),
        "owner_count_before" => observed.fetch("owner_count_before"), "owner_count_after_lock" => observed.fetch("owner_count_after_lock"),
        "owner_count_after_release" => observed.fetch("owner_count_after_release"), "locked_xrp_drops" => locked,
        "released_xrp_drops" => released, "terminal_result" => observed.fetch("terminal_result"), "cleanup_result" => observed.fetch("cleanup_result") }.freeze
    ensure
      if secret.is_a?(String) && !secret.frozen?
        secret.bytesize.times { |index| secret.setbyte(index, 0) }
        secret.clear
      end
    end

    private

    def validate!(value, recipe)
      required = %w[before_balance_drops after_lock_balance_drops after_release_balance_drops owner_count_before owner_count_after_lock owner_count_after_release terminal_result cleanup_result]
      raise OwnerReserveConformanceError, "invalid conformance observation" unless value.is_a?(Hash) && required.all? { |key| value.key?(key) }
      raise OwnerReserveConformanceError, "unverified transaction finality" unless value["terminal_result"] == "tesSUCCESS" && value["cleanup_result"] == "tesSUCCESS"
      expected = recipe.fetch("expected_owner_delta")
      raise OwnerReserveConformanceError, "unexpected owner reserve responsibility" unless value["owner_count_after_lock"] - value["owner_count_before"] == expected && value["owner_count_after_release"] == value["owner_count_before"]
      raise OwnerReserveConformanceError, "reserve was not released" unless value["after_release_balance_drops"] == value["before_balance_drops"]
    end
  end
end
