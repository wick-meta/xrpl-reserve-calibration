# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/xrpl_reserve_study"

class PopulationBuilderTest < Minitest::Test
  class FakeRpc
    attr_reader :max_inflight_per_source

    def initialize
      @max_inflight_per_source = 0
    end

    def isolated?
      true
    end

    def submit(source:, intent:, secret:)
      @max_inflight_per_source = [@max_inflight_per_source, 1].max
      { "hash" => "#{source}-#{intent.fetch('ordinal')}", "queued" => false }
    end

    def final?(hash:)
      true
    end
  end

  def test_builder_never_exceeds_ten_inflight_per_source_and_requires_finality
    fake = FakeRpc.new
    result = XrplReserveStudy::PopulationBuilder.new(client: fake).build(
      run: { "run_id" => "builder-test", "account_root_target" => 11 }, secret_reader: -> { "secret" }
    )
    assert_operator fake.max_inflight_per_source, :<=, 10
    assert_equal result.fetch("attempted_transactions"), result.fetch("validated_transactions")
    assert_equal false, result.fetch("counted_run")
  end
end
