module Berth
  module Commands
    # Independent checks, all reported rather than stopping at the first.
    module Doctor
      extend self

      HELP = <<-TEXT
        berth doctor — check the CLI and the config

        Reports the CLI version; the config path, where its symlink resolves,
        whether it is a file or the built-in starter, and whether it is valid
        JSON and a valid config, with its warnings. Exits 1 when a check fails.

        The install record, the template app and each site app (its build,
        signer and Launch Services registration) are not checked yet: those
        checks arrive with the apps.
        TEXT

      PENDING = "install, template and site-app checks are not built yet"

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
        config = config_checks(checks)
        checks << Check.new(Level::Info, "apps", PENDING)

        if args.json?
          Support.print_json do |json|
            json.object do
              json.field "ok", checks.none?(&.level.fail?)
              json.field("cli") { json.object { json.field "version", VERSION } }
              json.field("config") { config.call(json) }
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

      private def config_checks(checks : Array(Check)) : Proc(JSON::Builder, Nil)
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
