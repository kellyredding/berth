module Berth
  module Commands
    # Reads a login's values from 1Password and has the site's running app
    # fill its sign-in. Values go from op's stdout to the app's socket as
    # bytes: never into argv, output, an error message or a string.
    module Signin
      extend self

      HELP = <<-TEXT
        berth signin SITE [--account NAME] — fill a site app's sign-in from 1Password

        Reads the login's steps from 1Password with `op` (each read may ask you
        to approve it), then has SITE's running app fill each sign-in page in
        turn: Google's email, password and code, Okta's username, password and
        code. It waits up to two minutes for the app, which may be waiting on
        you to approve a push, and reports which steps it completed, or where it
        stopped and why; you finish a stopped sign-in in the app.

        --account NAME   The site's login to use (`berth sites show SITE` lists
                         them); needed only when it has more than one.

        The app must be running: start it with `berth open SITE`.
        TEXT

      # The app replies within 120 s; this leaves it time to.
      TIMEOUT = 130.seconds

      class AppNotOpen < Error
        def initialize(message : String)
          super(message, ExitCode::NOT_RUNNING)
        end

        def code : String
          "not_running"
        end
      end

      record Values, flow : String, username : Secret, password : Secret?, code : Secret?, method : String? = nil do
        def wipe : Nil
          username.wipe
          password.try(&.wipe)
          code.try(&.wipe)
        end
      end

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv, values: ["--account"])
        Support.help(args, HELP).try { |code| return code }
        args.at_most(1)
        site = Config::Store.model.site!(args.positional(0, "a site"))
        login, steps = pick(site, args["--account"])
        ensure_running(site)

        values = [] of Values
        data = begin
          steps.each_with_index { |step, index| values << read(step, index) }
          STDERR.puts "filling #{site.name}'s sign-in (#{login}: #{steps.map(&.flow).join(", then ")}); " \
                      "approve anything the app asks for within #{TIMEOUT.total_seconds.to_i - 10} s"
          send(site, login, values)
        ensure
          values.each(&.wipe)
        end
        report(args, site, login, values, data)
      end

      private def pick(site : Config::Site, name : String?) : {String, Array(Config::Step)}
        logins = site.signin
        if logins.empty?
          raise NotFound.new("#{site.id} has no sign-in logins; add one with " \
                             "`berth sites set #{site.id} --login NAME --steps JSON`")
        end
        if name
          steps = logins[name]? || raise NotFound.new("#{site.id} has no login named #{name.inspect}; " \
                                                      "its logins are #{logins.keys.join(", ")}")
          {name, steps}
        elsif logins.size == 1
          logins.first
        else
          raise UsageError.new("#{site.id} has #{logins.size} logins; pick one with --account: #{logins.keys.join(", ")}")
        end
      end

      # Before 1Password, so nothing is read for an app that cannot take it.
      private def ensure_running(site : Config::Site) : Nil
        SocketClient.request(site.id, "status", timeout: Status::TIMEOUT)
      rescue SocketClient::NotRunning
        raise AppNotOpen.new("#{site.id}'s app is not running; run `berth open #{site.id}` first")
      end

      private def read(step : Config::Step, index : Int32) : Values
        where = "step #{index + 1} (#{step.flow})"
        if item = step.item
          username = OnePassword.read("#{item}/username", step.account, "the username of #{item}, for #{where}")
          begin
            password = OnePassword.read("#{item}/password", step.account, "the password of #{item}, for #{where}")
            code = OnePassword.otp(item, step.account, "the one-time code of #{item}, for #{where}")
          rescue error
            username.wipe
            password.try(&.wipe)
            raise error
          end
          Values.new(step.flow, username, password, code, step.method)
        else
          reference = step.email_from.not_nil!
          field = OnePassword.parts(reference).not_nil!.size == 2 ? "#{reference}/username" : reference
          Values.new(step.flow, OnePassword.read(field, step.account, "the email in #{field}, for #{where}"), nil, nil)
        end
      end

      private def send(site : Config::Site, login : String, values : Array(Values)) : JSON::Any
        line = envelope(login, values)
        begin
          SocketClient.request_line(site.id, line.to_slice, TIMEOUT)
        rescue error : SocketClient::NoReply
          raise AppNotOpen.new("#{site.id}'s app did not reply within #{TIMEOUT.total_seconds.to_i} s " \
                               "(#{error.reason}); it may still be filling the sign-in")
        rescue error : SocketClient::NotRunning
          raise AppNotOpen.new("#{site.id}'s app stopped answering; run `berth open #{site.id}` and try again")
        ensure
          line.to_slice.fill(0_u8)
        end
      end

      # The request line, values written straight from their bytes into a
      # buffer sized so it never reallocates, then zeroed once sent.
      private def envelope(login : String, values : Array(Values)) : IO::Memory
        secrets = values.sum { |value| [value.username, value.password, value.code].compact.sum(&.bytes.size) }
        methods = values.sum { |value| value.method.try(&.to_json.bytesize) || 0 }
        io = IO::Memory.new(secrets * 6 + methods + 256 * (values.size + 1))
        io << %({"v":) << SocketClient::ENVELOPE_VERSION << %(,"event":"signin.fill","ts":) << Time.utc.to_unix
        io << %(,"detail_data":{"login":) << login.to_json << %(,"steps":[)
        values.each_with_index do |value, index|
          io << ',' if index > 0
          io << %({"flow":) << value.flow.to_json << %(,"username":)
          write_string(io, value.username)
          value.password.try { |password| io << %(,"password":); write_string(io, password) }
          value.code.try { |code| io << %(,"code":); write_string(io, code) }
          value.method.try { |method| io << %(,"method":) << method.to_json }
          io << '}'
        end
        io << "]}}\n"
        io
      end

      private def write_string(io : IO, secret : Secret) : Nil
        io << '"'
        secret.bytes.each do |byte|
          case byte
          when '"'.ord, '\\'.ord
            io.write_byte('\\'.ord.to_u8)
            io.write_byte(byte)
          when 0...0x20
            io << "\\u00" << byte.to_s(16).rjust(2, '0')
          else
            io.write_byte(byte)
          end
        end
        io << '"'
      end

      private def report(args : Args, site : Config::Site, login : String, values : Array(Values), data : JSON::Any) : Int32
        completed = data["completed"]?.try(&.as_a?).try(&.map(&.as_s)) || [] of String
        stop = data["stopped_at"]?.try(&.as_h?)
        url = data["url"]?.try(&.as_s?)
        already = data["already_signed_in"]?.try(&.as_bool?) || false
        flows = values.map(&.flow)
        stopped = stop.try { |item| "#{site.name}'s sign-in stopped at step #{(item["step"]?.try(&.as_i?) || 0) + 1}, " \
                                    "#{item["flow"]?.try(&.as_s?)}: #{item["reason"]?.try(&.as_s?) || "no reason given"}" }

        if args.json?
          Support.print_json do |json|
            json.object do
              json.field "ok", stop.nil?
              json.field "site", site.id
              json.field "login", login
              json.field("steps") do
                json.array do
                  values.each do |value|
                    json.object do
                      json.field "flow", value.flow
                      json.field "password", !value.password.nil?
                      json.field "code", !value.code.nil?
                    end
                  end
                end
              end
              json.field "completed", completed
              json.field "stopped_at", stop
              json.field "url", url
              json.field "already_signed_in", already
              if stopped
                json.field "error", stopped
                json.field "code", "stopped"
              end
            end
          end
        end

        if stopped
          STDERR.puts "berth: #{stopped}"
          STDERR.puts "  completed: #{completed.join(", ")}" unless completed.empty?
          STDERR.puts "  finish it in the app"
          return ExitCode::FAILED
        end
        return ExitCode::OK if args.json?

        if already
          STDOUT.puts "#{site.name} is signed in already; nothing to do"
        else
          skipped = flows[completed.size..]? || [] of String
          STDOUT.puts "signed in to #{site.name} with #{login}: #{completed.join(", then ")}" \
                      "#{skipped.empty? ? "" : " (#{skipped.join(", ")} not needed)"}"
        end
        url.try { |page| STDOUT.puts "  now at #{page}" }
        ExitCode::OK
      end
    end
  end
end
