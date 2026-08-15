# frozen_string_literal: true

require "minitest/autorun"
require "psych"

class PrivateNetworkTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  COMPOSE = File.join(ROOT, "capacity", "private-network", "compose.yml")
  SCRIPT = File.join(ROOT, "bin", "private-network")
  IMAGE = "xrpllabsofficial/xrpld@sha256:353d5e016bb93519e9fcac715cdc8c2205b96c4cfe2d1f0f1d22a22f6efaff70"

  def setup
    @compose = Psych.safe_load(File.read(COMPOSE), aliases: false)
    @script = File.read(SCRIPT)
  end

  def test_has_three_pinned_validators_and_no_published_ports
    services = @compose.fetch("services")
    assert_equal %w[validator_1 validator_2 validator_3], services.keys.sort
    assert_equal IMAGE, services.fetch("validator_1").fetch("image")
    service = services.fetch("validator_1")
    assert_equal "linux/amd64", service.fetch("platform")
    refute service.key?("ports")
    assert_equal ["ALL"], service.fetch("cap_drop")
    assert_equal true, service.fetch("read_only")
    assert_includes service.fetch("command").join, "--start --net"
    assert_equal "validator_1", services.fetch("validator_2").fetch("extends").fetch("service")
    assert_equal "validator_1", services.fetch("validator_3").fetch("extends").fetch("service")
  end

  def test_network_is_internal_and_lifecycle_is_guarded
    assert_equal true, @compose.fetch("networks").fetch("private_network").fetch("internal")
    assert_includes @script, "prepare"
    assert_includes @script, "activate"
    assert_includes @script, "wait"
    assert_includes @script, "verify"
    assert_includes @script, "XRPL_PRIVATE_NETWORK_CONFIRM_RESET=1"
    assert_includes @script, "21339"
    refute_match(%r{https?://[^127][^/]*}, @script)
  end
end
