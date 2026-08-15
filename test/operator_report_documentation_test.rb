# frozen_string_literal: true

require "minitest/autorun"

class OperatorReportDocumentationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_public_handoff_documents_both_safe_distribution_acquisition_paths
    readme = File.read(File.join(ROOT, "README.md"))
    methodology = File.read(File.join(ROOT, "docs", "methodology.md"))

    [readme, methodology].each do |text|
      assert_includes text, "ledger_data"
      assert_includes text, "complete-reserves-import"
      assert_includes text, "operator_local"
      assert_includes text, "independently_corroborated"
    end
    refute_includes readme, "server_info` and `ledger_entry"
  end
end
