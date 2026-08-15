# frozen_string_literal: true

require "digest"
require "fiddle"
require "rbconfig"
require "securerandom"

module XrplReserveStudy
  class RuntimePublisher
    REPOSITORY_ROOT = File.expand_path("../..", __dir__)
    RUNTIME_ROOT = File.join(REPOSITORY_ROOT, "capacity", "runtime")

    module Native
      class UnsupportedPlatformError < StandardError; end

      DARWIN_AT_REMOVEDIR = 0x80
      LINUX_AT_REMOVEDIR = 0x200
      RENAME_NOREPLACE = 0x01
      RENAME_EXCL = 0x04

      class << self
        def open_directory(path)
          ensure_supported!
          descriptor = call(
            open_function,
            path,
            File::RDONLY | File::NOFOLLOW | File::NONBLOCK | cloexec_flag,
            0,
            operation: "open"
          )
          directory_io_for(descriptor)
        end

        def open_directory_at(parent_descriptor, name)
          ensure_supported!
          descriptor = call(
            openat,
            parent_descriptor,
            name,
            File::RDONLY | File::NOFOLLOW | File::NONBLOCK | cloexec_flag,
            0,
            operation: "openat"
          )
          directory_io_for(descriptor)
        end

        def make_directory_at(parent_descriptor, name)
          ensure_supported!
          call(mkdirat, parent_descriptor, name, 0o700, operation: "mkdirat")
        end

        def open_file_at(parent_descriptor, name, mode)
          ensure_supported!
          descriptor = call(
            openat,
            parent_descriptor,
            name,
            File::CREAT | File::EXCL | File::NOFOLLOW | File::WRONLY | cloexec_flag,
            0,
            operation: "openat"
          )
          call(fchmod, descriptor, 0o644, operation: "fchmod")
          io = io_for(descriptor, mode)
          io.binmode
          io
        rescue Exception
          if io
            io.close unless io.closed?
          elsif descriptor && descriptor >= 0
            IO.new(descriptor).close
          end
          raise
        end

        def open_read_at(parent_descriptor, name)
          ensure_supported!
          descriptor = call(
            openat,
            parent_descriptor,
            name,
            File::RDONLY | File::NOFOLLOW | File::NONBLOCK | cloexec_flag,
            0,
            operation: "openat"
          )
          io = regular_io_for(descriptor)
          io.binmode
          io
        end

        def remove_file_at(parent_descriptor, name)
          ensure_supported!
          call(unlinkat, parent_descriptor, name, 0, operation: "unlinkat")
        end

        def remove_directory_at(parent_descriptor, name)
          ensure_supported!
          call(unlinkat, parent_descriptor, name, remove_directory_flag, operation: "unlinkat")
        end

        def rename_noreplace(parent_descriptor, source_name, destination_name)
          ensure_supported!
          function, flag = noreplace_function
          call(
            function,
            parent_descriptor,
            source_name,
            parent_descriptor,
            destination_name,
            flag,
            operation: noreplace_function_name
          )
        end

        def sync(descriptor)
          ensure_supported!
          call(fsync_function, descriptor, operation: "fsync")
        end

        private

        def ensure_supported!
          flags_available = %i[NOFOLLOW NONBLOCK].all? { |name| File::Constants.const_defined?(name) }
          return if supported_platform? && flags_available && required_functions.all?

          raise UnsupportedPlatformError,
                "descriptor-safe atomic runtime publication is unavailable on #{RUBY_PLATFORM}"
        end

        def supported_platform?
          darwin? || linux?
        end

        def platform
          return :darwin if darwin?
          return :linux if linux?

          :unsupported
        end

        def remove_directory_flag
          case platform
          when :darwin
            DARWIN_AT_REMOVEDIR
          when :linux
            LINUX_AT_REMOVEDIR
          else
            raise UnsupportedPlatformError, "AT_REMOVEDIR is unavailable on #{RUBY_PLATFORM}"
          end
        end

        def darwin?
          RbConfig::CONFIG.fetch("host_os").match?(/darwin/i)
        end

        def linux?
          RbConfig::CONFIG.fetch("host_os").match?(/linux/i)
        end

        def cloexec_flag
          return 0x01000000 if darwin?
          return 0x00080000 if linux?

          raise UnsupportedPlatformError, "O_CLOEXEC is unavailable on #{RUBY_PLATFORM}"
        end

        def required_functions
          [open_function, openat, mkdirat, unlinkat, fchmod, fsync_function, noreplace_function.first]
        end

        def noreplace_function
          if darwin?
            [renameatx_np, RENAME_EXCL]
          elsif linux?
            [renameat2, RENAME_NOREPLACE]
          else
            [nil, nil]
          end
        end

        def noreplace_function_name
          darwin? ? "renameatx_np" : "renameat2"
        end

        def open_function
          @open_function ||= function(
            "open", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT]
          )
        end

        def openat
          @openat ||= function("openat", [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT])
        end

        def mkdirat
          @mkdirat ||= function("mkdirat", [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT])
        end

        def unlinkat
          @unlinkat ||= function("unlinkat", [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT])
        end

        def fchmod
          @fchmod ||= function("fchmod", [Fiddle::TYPE_INT, Fiddle::TYPE_INT])
        end

        def fsync_function
          @fsync_function ||= function("fsync", [Fiddle::TYPE_INT])
        end

        def renameat2
          @renameat2 ||= function(
            "renameat2",
            [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]
          )
        end

        def renameatx_np
          @renameatx_np ||= function(
            "renameatx_np",
            [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]
          )
        end

        def function(name, argument_types)
          address = Fiddle::Handle::DEFAULT[name]
          Fiddle::Function.new(address, argument_types, Fiddle::TYPE_INT)
        rescue Fiddle::DLError
          nil
        end

        def call(function, *arguments, operation:)
          raise UnsupportedPlatformError, "#{operation} is unavailable on #{RUBY_PLATFORM}" unless function

          result = function.call(*arguments)
          raise SystemCallError.new(operation, Fiddle.last_error) if result == -1

          result
        end

        def io_for(descriptor, mode)
          IO.new(descriptor, mode, autoclose: true)
        rescue Exception
          IO.new(descriptor).close if descriptor && descriptor >= 0
          raise
        end

        def directory_io_for(descriptor)
          io = io_for(descriptor, "r")
          return io if io.stat.directory?

          io.close
          raise Errno::ENOTDIR, "descriptor does not reference a directory"
        rescue Exception
          io.close if io && !io.closed?
          raise
        end

        def regular_io_for(descriptor)
          io = io_for(descriptor, "r")
          return io if io.stat.file?

          io.close
          raise Errno::EINVAL, "descriptor does not reference a regular file"
        rescue Exception
          io.close if io && !io.closed?
          raise
        end
      end
    end

    class DirectoryHandle
      attr_reader :io

      def self.open(path)
        new(Native.open_directory(path))
      end

      def initialize(io)
        @io = io
      end

      def descriptor
        @io.fileno
      end

      def identity
        stat = @io.stat
        [stat.dev, stat.ino]
      end

      def open_child(name, create:)
        validate_component!(name)
        self.class.new(Native.open_directory_at(descriptor, name))
      rescue Errno::ENOENT
        raise unless create

        begin
          Native.make_directory_at(descriptor, name)
        rescue Errno::EEXIST
          # A concurrent creator is safe only if the no-follow open below proves it is a directory.
        end
        self.class.new(Native.open_directory_at(descriptor, name))
      end

      def make_staging_directory(destination_name)
        128.times do
          name = ".#{destination_name}.tmp-#{SecureRandom.hex(12)}"
          begin
            Native.make_directory_at(descriptor, name)
            return StagingDirectory.new(self, name, open_child(name, create: false))
          rescue Errno::EEXIST
            next
          end
        end
        raise Errno::EEXIST, "could not allocate unique staging directory"
      end

      def rename_noreplace(source_name, destination_name)
        validate_component!(source_name)
        validate_component!(destination_name)
        Native.rename_noreplace(descriptor, source_name, destination_name)
      end

      def remove_directory(name)
        validate_component!(name)
        Native.remove_directory_at(descriptor, name)
      end

      def close
        @io.close unless @io.closed?
      end

      def sync
        Native.sync(descriptor)
      end

      private

      def validate_component!(name)
        valid = name.is_a?(String) && !name.empty? && name != "." && name != ".." &&
          !name.include?(File::SEPARATOR) && !name.include?("\0")
        raise ArgumentError, "unsafe path component" unless valid
      end
    end

    class StagingDirectory
      attr_reader :handle, :name

      def initialize(parent, name, handle)
        @parent = parent
        @name = name
        @handle = handle
        @created_files = []
        @published = false
        @published_name = nil
      end

      def write(name, bytes)
        open(name) do |file|
          file.write(bytes)
          file.flush
          Native.sync(file.fileno)
        end
      end

      def open(name)
        validate_filename!(name)
        file = Native.open_file_at(@handle.descriptor, name, "w")
        @created_files << name
        return file unless block_given?

        begin
          yield file
        ensure
          file.close unless file.closed?
        end
      rescue Exception
        begin
          Native.remove_file_at(@handle.descriptor, name) unless @created_files.include?(name)
        rescue Errno::ENOENT
          nil
        end
        raise
      end

      def sha256(name)
        validate_filename!(name)
        digest = Digest::SHA256.new
        file = Native.open_read_at(@handle.descriptor, name)
        begin
          buffer = +""
          digest.update(buffer) while file.read(64 * 1024, buffer)
        ensure
          file.close unless file.closed?
        end
        digest.hexdigest
      end

      def identity
        @handle.identity
      end

      def mark_published
        @published = true
      end

      def mark_renamed(destination_name)
        @published_name = destination_name
      end

      def cleanup
        return if @published

        @created_files.reverse_each do |file_name|
          begin
            Native.remove_file_at(@handle.descriptor, file_name)
          rescue Errno::ENOENT
            nil
          end
        end
        removal_name = @published_name || @name
        bound = begin
          @parent.open_child(removal_name, create: false)
        rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
          nil
        end
        same_entry = bound && bound.identity == identity
        bound&.close
        @handle.close
        if same_entry
          begin
            @parent.remove_directory(removal_name)
          rescue Errno::ENOENT
            nil
          end
        end
      end

      def close
        @handle.close
      end

      private

      def validate_filename!(name)
        valid = name.is_a?(String) && !name.empty? && name != "." && name != ".." &&
          !name.include?(File::SEPARATOR) && !name.include?("\0")
        raise ArgumentError, "unsafe output filename" unless valid
      end
    end

    def initialize(error_class:, failure_label:)
      @error_class = error_class
      @failure_label = failure_label
    end

    def publish(output_dir)
      expanded_output_dir, relative_components = runtime_relative_components!(output_dir)
      handles, chain_names = open_parent_chain(relative_components[0...-1])
      parent = handles.last
      destination_name = relative_components.last
      staging = parent.make_staging_directory(destination_name)

      result = yield staging
      verify_chain!(handles, chain_names)
      verify_staging_binding!(parent, staging)
      staging.handle.sync
      parent.rename_noreplace(staging.name, destination_name)
      staging.mark_renamed(destination_name)
      verify_chain!(handles, chain_names)
      verify_published_binding!(parent, destination_name, staging)
      parent.sync
      staging.mark_published
      result
    rescue @error_class
      raise
    rescue Errno::EEXIST, Errno::ENOTEMPTY
      raise @error_class, "output directory already exists: #{expanded_output_dir}"
    rescue Errno::ELOOP, Errno::ENOTDIR
      raise @error_class, "output directory must resolve within #{File.expand_path(RUNTIME_ROOT)}"
    rescue SystemCallError, Native::UnsupportedPlatformError, ArgumentError => e
      raise @error_class, "could not write #{@failure_label}: #{e.message}"
    ensure
      begin
        staging.cleanup if staging
      ensure
        staging.close if staging
        handles&.reverse_each(&:close)
      end
    end

    private

    def runtime_relative_components!(output_dir)
      configured_root = File.expand_path(RUNTIME_ROOT)
      raise @error_class, "runtime root must not be a symlink: #{configured_root}" if File.symlink?(configured_root)

      expanded_output_dir = File.expand_path(output_dir)
      unless descendant_of?(expanded_output_dir, configured_root)
        raise @error_class, "output directory must be within #{configured_root}"
      end

      relative = expanded_output_dir.delete_prefix("#{configured_root}#{File::SEPARATOR}")
      if relative == expanded_output_dir || relative.empty?
        raise @error_class, "output directory already exists: #{expanded_output_dir}"
      end

      [expanded_output_dir, relative.split(File::SEPARATOR)]
    end

    def open_parent_chain(output_parent_components)
      repository = DirectoryHandle.open(File.realpath(REPOSITORY_ROOT))
      handles = [repository]
      names = %w[capacity runtime].concat(output_parent_components)
      names.each do |component|
        handles << handles.last.open_child(component, create: true)
      end
      [handles, names]
    rescue Exception
      handles&.reverse_each(&:close)
      raise
    end

    def verify_chain!(handles, names)
      reopened = []
      current = handles.first
      handles.drop(1).each_with_index do |expected, index|
        component = names.fetch(index)
        actual = current.open_child(component, create: false)
        reopened << actual
        unless actual.identity == expected.identity
          raise @error_class, "output directory ancestry changed during publication"
        end
        current = actual
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      raise @error_class, "output directory ancestry changed during publication"
    ensure
      reopened&.reverse_each(&:close)
    end

    def verify_staging_binding!(parent, staging)
      bound = parent.open_child(staging.name, create: false)
      raise @error_class, "staging directory changed during publication" unless bound.identity == staging.identity
    ensure
      bound&.close
    end

    def verify_published_binding!(parent, destination_name, staging)
      bound = parent.open_child(destination_name, create: false)
      raise @error_class, "published directory changed during publication" unless bound.identity == staging.identity
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      raise @error_class, "published directory changed during publication"
    ensure
      bound&.close
    end

    def descendant_of?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
