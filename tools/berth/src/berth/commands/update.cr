require "file_utils"

module Berth
  module Commands
    # `berth update`: installs a release, or a checkout, through install.sh,
    # then rebuilds every site app from the new template with the newly
    # installed CLI.
    module Update
      extend self

      INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/kellyredding/berth/main/install.sh"
      ARCHIVE            = "berth-darwin-arm64.tar.gz"
      SWITCHES           = ["--local", "--preview", "--force", "--no-sites"]

      HELP = <<-TEXT
        berth update — install the latest release, or a Berth checkout, then rebuild your site apps

        Usage:
          berth update                   Install the latest release
          berth update --version X.Y.Z   Install that release
          berth update --local [PATH]    Package and install a Berth checkout
                                         (PATH, else the repository you are in),
                                         uncommitted changes included

        Options:
          --preview    Show what would change, and change nothing
          --force      Reinstall a release even when it is already installed
          --no-sites   Install only; leave the site apps as they are

        Replaces ~/.berth/bin/berth, the template ~/.berth/template/Berth.app and
        ~/.berth/libexec/sign-app.sh; never your config or ~/Applications.

        Then, when something was installed, it runs the new CLI's
        `berth sites build --all`, which signs every site app with the Berth
        release identity from 1Password: one approval for the whole build. That
        needs BERTH_SIGNING_OP_ACCOUNT and BERTH_SIGNING_OP_ITEM in your shell
        profile; without them the install still finishes, and it says to set
        them and run `berth sites build --all`. It never signs ad hoc, and never
        restarts a site app: a running one keeps its old build until you
        restart it.

        Releases install through #{INSTALL_SCRIPT_URL}
        --local runs the checkout's bin/package, which signs with the same
        identity, then its install.sh. Exits with the installer's, the
        packager's or the build's exit code when one fails.
        TEXT

      record Options,
        local : Bool = false,
        local_path : String? = nil,
        version : String? = nil,
        preview : Bool = false,
        force : Bool = false,
        sites : Bool = true

      def run(argv : Array(String)) : Int32
        args = arguments(argv)
        Support.help(args, HELP).try { |code| return code }
        options = options(args)
        before = install_record
        code = options.local ? run_local(options) : run_release(options)
        return code unless code == ExitCode::OK
        rebuild_sites(options, before)
      end

      def parse(argv : Array(String)) : Options
        options(arguments(argv))
      end

      # Flags for install.sh, in its own spelling.
      def install_args(options : Options) : Array(String)
        args = [] of String
        options.version.try { |version| args.concat(["--version", version]) }
        args << "--preview" if options.preview
        args << "--force" if options.force
        args
      end

      # The checkout to package: PATH, else the git root of the working
      # directory. Nil when that is not a Berth checkout.
      def resolve_repo(path : String?, cwd : String = Dir.current) : Path?
        start = path ? File.expand_path(path, cwd, home: true) : cwd
        return nil unless Dir.exists?(start)

        output = IO::Memory.new
        status = Process.run("git", ["-C", start, "rev-parse", "--show-toplevel"],
          output: output, error: Process::Redirect::Close)
        return nil unless status.success?

        root = Path.new(output.to_s.strip)
        berth_repo?(root) ? root : nil
      rescue File::Error
        nil
      end

      # Trellis's and Galaxy's checkouts have a bin/package and an install.sh
      # too, so those alone would let --local install another tool's archive.
      def berth_repo?(root : Path) : Bool
        File.file?(root / "bin" / "package") && File.file?(root / "install.sh") &&
          File.file?(root / "BerthApp" / "project.yml")
      end

      private def arguments(argv : Array(String)) : Args
        Args.parse(argv, values: ["--version"], switches: SWITCHES)
      end

      private def options(args : Args) : Options
        if args.json?
          raise UsageError.new("update prints the installer's progress; it has no --json output")
        end
        args.at_most(1)
        local = args.switch?("--local")
        path = args.positionals.first?
        if path && !local
          raise UsageError.new("unexpected argument #{path.inspect}; a checkout path goes with --local")
        end

        version = args["--version"].try do |raw|
          bare = raw.lchop('v')
          unless bare.matches?(/\A\d+\.\d+\.\d+\z/)
            raise UsageError.new("--version needs a version like 0.1.0, got #{raw.inspect}")
          end
          bare
        end
        if local && version
          raise UsageError.new("--local packages a checkout; it cannot be combined with --version")
        end

        Options.new(local: local, local_path: path, version: version,
          preview: args.switch?("--preview"), force: args.switch?("--force"),
          sites: !args.switch?("--no-sites"))
      end

      # The script is fetched before bash runs it: piped straight into bash, a
      # failed download is an empty script, which bash runs and exits 0.
      private def run_release(options : Options) : Int32
        script = IO::Memory.new
        fetched = execute("curl", ["-fsSL", INSTALL_SCRIPT_URL], output: script)
        unless fetched.success?
          raise Error.new("could not download the installer from #{INSTALL_SCRIPT_URL} (#{describe(fetched)})")
        end
        script.rewind
        Support.exit_code_for(execute("bash", ["-s", "--"] + install_args(options), input: script,
          env: installer_env(options)))
      end

      # install.sh's closing advice to rebuild the site apps is this command's
      # next step, unless --no-sites skips it.
      private def installer_env(options : Options) : Hash(String, String?)
        {"BERTH_INSTALL_FROM_UPDATE" => options.sites ? "1" : nil} of String => String?
      end

      private def run_local(options : Options) : Int32
        repo = resolve_repo(options.local_path)
        unless repo
          where = options.local_path || Dir.current
          raise Error.new("#{where} is not inside a Berth checkout (no bin/package, install.sh and BerthApp/project.yml)")
        end

        out_dir = Path.new(File.tempname("berth-local-", nil))
        begin
          packaged = execute((repo / "bin" / "package").to_s, ["--local", "--out", out_dir.to_s])
          return Support.exit_code_for(packaged) unless packaged.success?

          archive = out_dir / ARCHIVE
          raise Error.new("bin/package wrote no #{ARCHIVE} in #{out_dir}") unless File.file?(archive)
          installer = ["--from", archive.to_s] + install_args(options)
          Support.exit_code_for(execute("bash", [(repo / "install.sh").to_s] + installer, env: installer_env(options)))
        ensure
          FileUtils.rm_rf(out_dir.to_s)
        end
      end

      # The install record's text and time, to tell an install that changed
      # something from one that found Berth up to date.
      private def install_record : Tuple(String, Time)?
        path = Paths.installed_manifest.to_s
        info = File.info?(path)
        info ? {File.read(path), info.modification_time} : nil
      rescue File::Error
        nil
      end

      # Run by the CLI just installed, as a child: it carries the new
      # template's rules, and this binary may be the one it replaced.
      private def rebuild_sites(options : Options, before : Tuple(String, Time)?) : Int32
        return ExitCode::OK if options.preview
        unless options.sites
          STDERR.puts "berth: site apps not rebuilt (--no-sites); rebuild them with `berth sites build --all`."
          return ExitCode::OK
        end
        if install_record == before
          STDERR.puts "berth: nothing was installed, so site apps were not rebuilt."
          return ExitCode::OK
        end
        if no_sites?
          STDERR.puts "berth: the config has no sites, so there are no site apps to rebuild."
          return ExitCode::OK
        end
        begin
          SiteBuild.require_signing_env
        rescue error : SigningNotConfigured
          STDERR.puts "berth: installed, but site apps were not rebuilt: signing them needs the Berth release " \
                      "identity from 1Password, named by #{SiteBuild::ACCOUNT_VARIABLE} and #{SiteBuild::ITEM_VARIABLE}."
          error.details.each { |line| STDERR.puts line }
          STDERR.puts "Set them in your shell profile, then run `berth sites build --all`."
          return ExitCode::OK
        end

        cli = Paths.installed_cli
        STDERR.puts "\nRebuilding every site app from the new template with #{cli} sites build --all"
        Support.exit_code_for(execute(cli.to_s, ["sites", "build", "--all"]))
      end

      # An unreadable config is left to the build, which explains it.
      private def no_sites? : Bool
        Config::Store.model.sites.empty?
      rescue Error
        false
      end

      private def execute(command : String, args : Array(String),
                          input : Process::Stdio = Process::Redirect::Inherit,
                          output : Process::Stdio = Process::Redirect::Inherit,
                          env : Hash(String, String?)? = nil) : Process::Status
        Process.run(command, args, env: env, input: input, output: output, error: Process::Redirect::Inherit)
      rescue error : File::Error
        raise Error.new("could not run #{command}: #{error.message}")
      end

      private def describe(status : Process::Status) : String
        if code = status.exit_code?
          "exit #{code}"
        elsif signal = status.exit_signal?
          "signal #{signal}"
        else
          status.to_s
        end
      end
    end
  end
end
