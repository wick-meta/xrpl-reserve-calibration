# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../lib/xrpl_reserve_study"

class RuntimePublisherTest < Minitest::Test
  RUNTIME_ROOT = XrplReserveStudy::RuntimePublisher::RUNTIME_ROOT

  class PublicationError < XrplReserveStudy::StudyError; end

  def test_fails_closed_and_cleans_staging_when_a_verified_ancestor_is_replaced_by_a_symlink
    with_runtime_directory do |directory|
      ancestor = File.join(directory, "ancestor")
      displaced_ancestor = File.join(directory, "ancestor-displaced")
      output_dir = File.join(ancestor, "published")
      Dir.mkdir(ancestor)

      Dir.mktmpdir("publisher-outside-") do |outside|
        publisher = publisher()
        error = assert_raises(PublicationError) do
          publisher.publish(output_dir) do |staging|
            staging.write("payload.txt", "complete")
            File.rename(ancestor, displaced_ancestor)
            File.symlink(outside, ancestor)
            :result
          end
        end

        assert_match(/changed during publication/, error.message)
        assert_empty Dir.children(outside)
        assert_empty Dir.children(displaced_ancestor)
        refute File.exist?(output_dir)
      end
    end
  end

  def test_atomic_no_replace_preserves_an_empty_destination_created_at_publication_boundary
    with_runtime_directory do |directory|
      output_dir = File.join(directory, "published")
      publisher = publisher()

      error = assert_raises(PublicationError) do
        publisher.publish(output_dir) do |staging|
          staging.write("payload.txt", "complete")
          Dir.mkdir(output_dir)
          :result
        end
      end

      assert_match(/already exists/, error.message)
      assert File.directory?(output_dir)
      assert_empty Dir.children(output_dir)
      refute Dir.children(directory).any? { |name| name.start_with?(".published.tmp-") }
    end
  end

  def test_fails_closed_and_removes_output_when_ancestor_changes_as_atomic_rename_returns
    with_runtime_directory do |directory|
      ancestor = File.join(directory, "ancestor")
      displaced_ancestor = File.join(directory, "ancestor-displaced")
      output_dir = File.join(ancestor, "published")
      Dir.mkdir(ancestor)

      Dir.mktmpdir("publisher-outside-") do |outside|
        native_rename = XrplReserveStudy::RuntimePublisher::Native.method(:rename_noreplace)
        rename_then_swap = lambda do |*arguments|
          native_rename.call(*arguments)
          File.rename(ancestor, displaced_ancestor)
          File.symlink(outside, ancestor)
        end

        error = XrplReserveStudy::RuntimePublisher::Native.stub(:rename_noreplace, rename_then_swap) do
          assert_raises(PublicationError) do
            publisher.publish(output_dir) do |staging|
              staging.write("payload.txt", "complete")
              :result
            end
          end
        end

        assert_match(/changed during publication/, error.message)
        assert_empty Dir.children(outside)
        assert_empty Dir.children(displaced_ancestor)
        refute File.exist?(output_dir)
      end
    end
  end

  def test_fails_closed_when_descriptor_or_atomic_no_replace_primitive_is_unavailable
    atomic_method = RbConfig::CONFIG.fetch("host_os").match?(/darwin/i) ? :renameatx_np : :renameat2

    [:openat, atomic_method].each_with_index do |native_method, index|
      with_runtime_directory do |directory|
        output_dir = File.join(directory, "unavailable-#{index}")
        error = XrplReserveStudy::RuntimePublisher::Native.stub(native_method, nil) do
          assert_raises(PublicationError, native_method) do
            publisher.publish(output_dir) { |staging| staging.write("payload.txt", "complete") }
          end
        end

        assert_match(/descriptor-safe atomic runtime publication is unavailable/, error.message)
        refute File.exist?(output_dir)
        refute Dir.children(directory).any? { |name| name.start_with?(".unavailable-#{index}.tmp-") }
      end
    end
  end

  def test_linux_cleanup_uses_linux_unlinkat_abi_and_preserves_controlled_failure
    native = XrplReserveStudy::RuntimePublisher::Native
    supports_platform_boundary = native.respond_to?(:platform, true)
    assert supports_platform_boundary, "Native must expose an internal platform boundary"
    return unless supports_platform_boundary

    host_unlinkat = native.send(:unlinkat)
    host_directory_flag = if RbConfig::CONFIG.fetch("host_os").match?(/darwin/i)
                            0x80
                          else
                            0x200
                          end
    observed_flags = []
    linux_unlinkat_boundary = lambda do |descriptor, name, flags|
      observed_flags << flags
      if flags.zero?
        host_unlinkat.call(descriptor, name, flags)
      elsif flags == 0x200
        host_unlinkat.call(descriptor, name, host_directory_flag)
      else
        Fiddle.last_error = Errno::EINVAL::Errno
        -1
      end
    end

    with_runtime_directory do |directory|
      output_dir = File.join(directory, "linux-cleanup")
      error = native.stub(:platform, :linux) do
        native.stub(:unlinkat, -> { linux_unlinkat_boundary }) do
          native.stub(
            :rename_noreplace,
            ->(*) { raise Errno::EIO, "simulated Linux publication failure" }
          ) do
            assert_raises(PublicationError) do
              publisher.publish(output_dir) { |staging| staging.write("payload.txt", "complete") }
            end
          end
        end
      end

      assert_match(/simulated Linux publication failure/, error.message)
      assert_equal [0, 0x200], observed_flags
      refute File.exist?(output_dir)
      refute Dir.children(directory).any? { |name| name.start_with?(".linux-cleanup.tmp-") }
    end
  end

  def test_linux_root_open_uses_native_nofollow_without_an_architecture_specific_directory_flag
    native = XrplReserveStudy::RuntimePublisher::Native
    actual_sysopen = IO.method(:sysopen)
    observed_flags = nil
    simulated_open = lambda do |path, flags, _mode|
      observed_flags = flags
      actual_sysopen.call(path, File::RDONLY)
    end

    with_runtime_directory do |directory|
      handle = native.stub(:ensure_supported!, -> {}) do
        native.stub(:darwin?, false) do
          native.stub(:linux?, true) do
            native.stub(:open_function, -> { simulated_open }) { native.open_directory(directory) }
          end
        end
      end
      handle.close
    end

    assert_equal File::NOFOLLOW, observed_flags & File::NOFOLLOW
    assert_equal File::NONBLOCK, observed_flags & File::NONBLOCK
    assert_equal 0, observed_flags & 0x00010000
    assert_equal 0x00080000, observed_flags & 0x00080000
  end

  def test_native_root_open_rejects_a_non_directory_descriptor
    native = XrplReserveStudy::RuntimePublisher::Native
    Dir.mktmpdir do |directory|
      path = File.join(directory, "regular-file")
      File.binwrite(path, "not a directory")

      assert_raises(Errno::ENOTDIR) { native.open_directory(path) }
    end
  end

  # Break caught: rename can publish bytes that were never durably synchronized.
  def test_each_file_and_directory_sync_failure_prevents_publication_and_cleans_staging
    native = XrplReserveStudy::RuntimePublisher::Native
    assert_respond_to native, :sync

    1.upto(7) do |failure_call|
      with_runtime_directory do |directory|
        output_dir = File.join(directory, "sync-failure-#{failure_call}")
        calls = 0
        real_sync = native.method(:sync)
        failing_sync = lambda do |descriptor|
          calls += 1
          raise Errno::EIO, "simulated sync failure" if calls == failure_call
          real_sync.call(descriptor)
        end

        error = native.stub(:sync, failing_sync) do
          assert_raises(PublicationError) do
            publisher.publish(output_dir) do |staging|
              5.times { |index| staging.write("payload-#{index}.txt", "complete") }
            end
          end
        end
        assert_match(/sync failure/, error.message)
        refute File.exist?(output_dir)
        refute Dir.children(directory).any? { |name| name.start_with?(".sync-failure-") }
      end
    end
  end

  private

  def publisher
    XrplReserveStudy::RuntimePublisher.new(
      error_class: PublicationError,
      failure_label: "test publication"
    )
  end

  def with_runtime_directory
    FileUtils.mkdir_p(RUNTIME_ROOT)
    Dir.mktmpdir("runtime-publisher-test-", RUNTIME_ROOT) { |directory| yield directory }
  end
end
