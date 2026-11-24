module Berth
  # The macOS programs the CLI runs to build and inspect site apps. Each one
  # specs replace has an override in Paths.
  module MacOS
    extend self

    PLUTIL = "/usr/bin/plutil"
    DITTO  = "/usr/bin/ditto"

    record Output, success : Bool, stdout : String, stderr : String do
      # The most useful line to quote when it failed.
      def reason : String
        text = stderr.strip.empty? ? stdout.strip : stderr.strip
        text.empty? ? "no output" : text.lines.last
      end
    end

    def run(program : String | Path, args : Array(String)) : Output
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(program.to_s, args, output: stdout, error: stderr)
      Output.new(status.success?, stdout.to_s, stderr.to_s)
    rescue error : File::Error | IO::Error
      Output.new(false, "", "could not run #{program}: #{error.message}")
    end

    # Runs it, raising with `what` and the program's own reason on failure.
    def run!(program : String | Path, args : Array(String), what : String) : String
      output = run(program, args)
      raise Error.new("#{what}: #{output.reason}") unless output.success
      output.stdout
    end

    # One app bundle's Info.plist, read and written with plutil, which takes
    # each value as its own argument. PlistBuddy parses its values out of a
    # command string, and a site name holding a quote breaks that parse.
    struct InfoPlist
      getter path : Path

      def initialize(app : Path)
        @path = app / "Contents" / "Info.plist"
      end

      def exists? : Bool
        File.file?(@path.to_s)
      end

      def [](key : String) : String?
        output = MacOS.run(PLUTIL, ["-extract", key, "raw", "-o", "-", @path.to_s])
        output.success ? output.stdout.chomp : nil
      end

      def []=(key : String, value : String) : String
        MacOS.run!(PLUTIL, ["-replace", key, "-string", value, @path.to_s], "could not set #{key} in #{@path}")
        value
      end

      def set_json(key : String, value : String) : Nil
        MacOS.run!(PLUTIL, ["-replace", key, "-json", value, @path.to_s], "could not set #{key} in #{@path}")
      end

      def delete(key : String) : Nil
        MacOS.run(PLUTIL, ["-remove", key, @path.to_s]) if self[key]
      end
    end

    # What `codesign` says of a bundle.
    record Signature, verified : Bool, identifier : String?, authority : String?, adhoc : Bool, problem : String? do
      def self.read(app : Path) : Signature
        verify = MacOS.run(Paths.codesign, ["--verify", "--strict", app.to_s])
        display = MacOS.run(Paths.codesign, ["-dv", "--verbose=2", app.to_s])
        text = display.stderr
        new(
          verify.success,
          text[/^Identifier=([^\n]+)$/m, 1]?,
          text[/^Authority=([^\n]+)$/m, 1]?,
          text.matches?(/^Signature=adhoc$/m),
          verify.success ? nil : verify.reason,
        )
      end

      def release? : Bool
        authority == SiteBuild::IDENTITY
      end

      def signer : String
        authority || (adhoc ? "ad hoc" : "unsigned")
      end

      def kind : String
        if !verified
          "invalid"
        elsif release?
          "release"
        elsif adhoc
          "adhoc"
        else
          "other"
        end
      end
    end

    # Launch Services, through lsregister.
    module LaunchServices
      extend self

      record Registration, path : String, identifier : String

      # A Berth.app left in an Xcode build folder; Launch Services can pick it
      # over an installed copy, so builds unregister it and doctor warns.
      DEVELOPMENT_COPY = %r{/Build/Products/[^/]+/Berth\.app\z}

      def register(app : Path) : String?
        output = MacOS.run(Paths.lsregister, ["-f", app.to_s])
        output.success ? nil : output.reason
      end

      def unregister(path : String) : Nil
        MacOS.run(Paths.lsregister, ["-u", path])
      end

      # Every registered bundle with its identifier, from `lsregister -dump`:
      # records split by dashed lines, a bundle's opening with `bundle id:`.
      def registrations : Array(Registration)
        found = [] of Registration
        in_bundle = false
        path = nil
        identifier = nil
        process = Process.new(Paths.lsregister.to_s, ["-dump"], output: Process::Redirect::Pipe,
          error: Process::Redirect::Close)
        begin
          process.output.each_line do |line|
            if line.starts_with?("----")
              in_bundle = false
            elsif line.starts_with?("bundle id:")
              in_bundle = true
              path = nil
              identifier = nil
            elsif in_bundle && path.nil? && (match = line.match(/\Apath:\s+(.+?) \(0x[0-9a-f]+\)\z/))
              path = match[1]
            elsif in_bundle && identifier.nil? && (match = line.match(/\Aidentifier:\s+(\S+)/))
              identifier = match[1]
              path.try { |found_path| found << Registration.new(found_path, match[1]) }
            end
          end
        ensure
          status = process.wait
        end
        raise Error.new("lsregister -dump failed") unless status.success?
        found
      rescue error : File::Error | IO::Error
        raise Error.new("could not run #{Paths.lsregister}: #{error.message}")
      end

      def development_copies(registrations : Array(Registration)) : Array(String)
        registrations.map(&.path).select(&.matches?(DEVELOPMENT_COPY)).uniq
      end
    end
  end
end
