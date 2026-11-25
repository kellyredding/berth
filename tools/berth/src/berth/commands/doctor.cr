module Berth
  module Commands
    # Independent checks, all reported rather than stopping at the first.
    module Doctor
      extend self

      HELP = <<-TEXT
        berth doctor — check the CLI, the install, the config and each site's app

        Reports the CLI version; the config path, where its symlink resolves,
        whether it is a file or the built-in starter, and whether it is valid
        JSON and a valid config, with its warnings.

        Then the install record install.sh leaves at
        ~/.berth/installed-manifest.json (version, commit, build time, signer)
        and, when there is one: whether ~/.berth/bin/berth is that build (its
        checksum); whether the template ~/.berth/template/Berth.app is that
        build and signed by that signer, and that Launch Services does not know
        it; and whether ~/.berth/libexec/sign-app.sh is there.

        Then, for each site, its app at ~/Applications/NAME.app: whether it is
        built and names this site, whether it was built from the installed
        template (else rebuild with `berth sites build --all`), whether it is
        signed by Berth Release Signing, whether Launch Services knows it (and
        any other copy registered under its bundle identifier), and whether it
        is running. Exits 1 when a check fails; no install record, as in a
        checkout, is a warning.
        TEXT

      enum Level
        Ok
        Info
        Warn
        Fail

        def marker : String
          case self
          in .ok?   then "ok  "
          in .info? then "info"
          in .warn? then "warn"
          in .fail? then "FAIL"
          end
        end
      end

      record Check, level : Level, name : String, detail : String do
        def to_json(json : JSON::Builder) : Nil
          json.object do
            json.field "level", level.to_s.downcase
            json.field "name", name
            json.field "detail", detail
          end
        end
      end

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv)
        Support.help(args, HELP).try { |code| return code }
        args.at_most(0)

        checks = [Check.new(Level::Ok, "cli", "berth #{VERSION}")]
        model = nil
        config = config_checks(checks) { |valid| model = valid }
        registrations = begin
          MacOS::LaunchServices.registrations
        rescue error : Error
          checks << Check.new(Level::Warn, "launch services", "could not read its registrations: #{error.message}")
          nil
        end
        install = InstallChecks.run(checks, registrations)
        apps = model.try { |valid| SiteAppChecks.run(valid, checks, registrations, install.template_commit) } ||
               [] of SiteAppChecks::Report

        if args.json?
          Support.print_json do |json|
            json.object do
              json.field "ok", checks.none?(&.level.fail?)
              json.field("cli") { json.object { json.field "version", VERSION } }
              json.field "install", install
              json.field("config") { config.call(json) }
              json.field "sites", apps
              json.field "checks", checks
            end
          end
        else
          width = checks.max_of(&.name.size)
          checks.each do |check|
            STDOUT.puts "#{check.level.marker}  #{check.name.ljust(width)}  #{check.detail}"
          end
        end

        checks.any?(&.level.fail?) ? ExitCode::FAILED : ExitCode::OK
      end

      private def config_checks(checks : Array(Check), & : Config::Model ->) : Proc(JSON::Builder, Nil)
        path = Paths.config_file
        resolved = nil
        source = nil
        errors = [] of String
        warnings = [] of String

        begin
          loaded = Config::Store.load(path)
          source = loaded.source
          resolved = loaded.resolved_path
          detail = path.to_s
          detail += " -> #{resolved}" if resolved && resolved != path.expand
          detail += " (missing: using the built-in starter)" if source.starter?
          checks << Check.new(Level::Ok, "config path", detail)

          result = loaded.validate
          errors = result.errors
          warnings = result.warnings
          if model = result.model
            yield model
            sites = model.sites.map(&.id)
            checks << Check.new(Level::Ok, "config",
              "valid: #{sites.size} site#{sites.size == 1 ? "" : "s"}#{sites.empty? ? "" : " (#{sites.join(", ")})"}")
          else
            checks << Check.new(Level::Fail, "config", "invalid: #{errors.join("; ")}")
          end
          warnings.each { |warning| checks << Check.new(Level::Warn, "config", warning) }
        rescue error : InvalidConfig
          errors = error.errors
          checks << Check.new(Level::Fail, "config", "invalid: #{errors.join("; ")}")
        rescue error : Error
          errors = [error.message || "unreadable"]
          checks << Check.new(Level::Fail, "config path", errors.first)
        end

        ->(json : JSON::Builder) do
          json.object do
            json.field "path", path.to_s
            json.field "resolved", resolved.try(&.to_s)
            json.field "source", source.try(&.label)
            json.field "valid", errors.empty?
            json.field "errors", errors
            json.field "warnings", warnings
          end
          nil
        end
      end
    end
  end
end
