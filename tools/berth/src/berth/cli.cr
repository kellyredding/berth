module Berth
  module CLI
    extend self

    USAGE = <<-TEXT
      berth — web pages as standalone Mac apps

      Usage: berth <command> [options]      (every command but update takes --json)

      Sites (the config; no app needed):
        sites list                      Every site, its name and URL
        sites show SITE                 One site's settings and sign-in logins
        sites add SITE --name NAME --url URL [options]
        sites set SITE [options]        Change a site; see `berth sites --help`
        sites remove SITE
        config path|show|validate|export --json [--site SITE]|init [--starter] [--force]

      Site apps:
        status                          Every site: built, running, title and badge
        open SITE [URL]                 Launch or focus a site app; load URL
        sites build [SITE…|--all] [--template PATH] [--sign op|adhoc] [--preview]
                                        Stamp, sign and install site apps
        signin SITE [--account NAME]    Fill a running app's sign-in from 1Password

      Health:
        doctor                          Check the config and each site's app
        version                         Print the version
        update [--version X.Y.Z | --local [PATH]] [--preview] [--force]

      SITE is a site's name in the config (`mail`), not its display name.

      Exit codes: 0 ok, 1 failed, 2 usage, 3 site app not running,
      4 not permitted, 5 no such site or login, or its app is not built.

      Run `berth <command> --help` for a command's options.
      TEXT

    def run(argv : Array(String)) : NoReturn
      exit(dispatch(argv))
    end

    def dispatch(argv : Array(String)) : Int32
      json = argv.includes?("--json")
      command = argv.first?
      rest = argv.size > 1 ? argv[1..] : [] of String

      guard(json) do
        case command
        when nil
          STDERR.puts USAGE
          ExitCode::USAGE
        when "help", "--help", "-h"
          STDOUT.puts USAGE
          ExitCode::OK
        when "version", "--version", "-V"
          Commands::Version.run(rest)
        when "doctor"
          Commands::Doctor.run(rest)
        when "sites"
          Commands::Sites.run(rest)
        when "config"
          Commands::ConfigFile.run(rest)
        when "status"
          Commands::Status.run(rest)
        when "open"
          Commands::Open.run(rest)
        when "signin"
          Commands::Signin.run(rest)
        when "update"
          Commands::Update.run(rest)
        else
          raise UsageError.new("unknown command #{command.inspect}")
        end
      end
    end

    # Every anticipated failure becomes a message on stderr and its exit code;
    # with --json the same failure is also printed as a JSON object on stdout.
    def guard(json : Bool, &) : Int32
      yield
    rescue error : Berth::Error
      STDERR.puts "berth: #{error.message}"
      error.details.each { |line| STDERR.puts line }
      STDERR.puts "Run `berth --help` for usage." if error.is_a?(UsageError)
      STDOUT.puts error.to_pretty_json if json
      error.exit_code
    end
  end
end
