# frozen_string_literal: true

require "yaml"

module XrplReserveStudy
  class CompleteReservesProfileError < StudyError; end

  class CompleteReservesProfile
    ERROR = "invalid complete reserves profile"
    PATH = File.expand_path("../../study/complete-reserves-profiles-v1.yml", __dir__)
    EXPECTED = {
      "schema_version" => "complete-reserves-profiles-v1",
      "calibrated" => {
        "profile_id" => "complete-reserves-calibrated-v1",
        "account_root_targets" => [10_000, 25_000, 50_000],
        "warmup_seconds" => 300,
        "measurement_seconds" => 1_800,
        "counted_run" => false
      },
      "full_matrix" => {
        "profile_id" => "complete-reserves-full-matrix-v1",
        "warmup_seconds" => 300,
        "measurement_seconds" => 1_800,
        "counted_run" => false
      }
    }.freeze

    def initialize(path = PATH, source: nil, study: CompleteReservesStudy.new(File.expand_path("../../study/complete-reserves-v1.yml", __dir__)))
      @data = YAML.safe_load(source || File.binread(path), permitted_classes: [], aliases: false)
      validate!
      @study = study
    rescue Psych::Exception, SystemCallError
      raise CompleteReservesProfileError, ERROR
    end

    def calibrated_cells(distribution:)
      accounts, objects = distribution_values(distribution)
      profile = @data.fetch("calibrated")
      profile.fetch("account_root_targets").map do |target|
        {
          "profile_id" => profile.fetch("profile_id"),
          "account_root_target" => target,
          "owned_object_target" => (objects * target.to_f / accounts).ceil,
          "warmup_seconds" => profile.fetch("warmup_seconds"),
          "measurement_seconds" => profile.fetch("measurement_seconds"),
          "counted_run" => profile.fetch("counted_run")
        }.freeze
      end.freeze
    end

    def full_matrix_cells(distribution:)
      profile = @data.fetch("full_matrix")
      @study.plan(distribution: distribution).fetch("runs").map do |cell|
        cell.merge(
          "profile_id" => profile.fetch("profile_id"),
          "warmup_seconds" => profile.fetch("warmup_seconds"),
          "measurement_seconds" => profile.fetch("measurement_seconds"),
          "counted_run" => profile.fetch("counted_run")
        ).freeze
      end.freeze
    end

    private

    def validate!
      raise CompleteReservesProfileError, ERROR unless @data == EXPECTED
    end

    def distribution_values(distribution)
      accounts = distribution.is_a?(Hash) ? distribution["account_roots"] : nil
      objects = distribution.is_a?(Hash) ? distribution["owned_objects"] : nil
      unless accounts.is_a?(Integer) && accounts.positive? && objects.is_a?(Integer) && objects.positive?
        raise CompleteReservesProfileError, ERROR
      end

      [accounts, objects]
    end
  end
end
