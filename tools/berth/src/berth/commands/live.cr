module Berth
  module Commands
    # Every site: whether its app is built, and what its running app reports.
    module Status
      extend self

      HELP = <<-TEXT
        berth status — every site: whether its app is built and running, and what it shows

        For each site in the config: whether its app is built
        (~/Applications/NAME.app), and whether it is running, meaning it answers
        on its socket. A running app reports its version, the page title and its
        Dock badge. No app running is not an error.
        TEXT

      # Short, since every site is asked in turn.
      TIMEOUT = 2.seconds

      record Probe, site : Config::Site, built : Bool, state : String, error : String?, status : JSON::Any? do
        def running? : Bool
          state == "running"
        end

        def to_json(json : JSON::Builder) : Nil
          json.object do
            json.field "site", site.id
            json.field "name", site.name
            json.field "app", site.app.to_s
            json.field "built", built
            json.field "running", running?
            json.field "state", state
            json.field "error", error
            json.field "status", status
          end
        end
      end

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv)
        Support.help(args, HELP).try { |code| return code }
        args.at_most(0)
        probes = Config::Store.model.sites.map { |site| probe(site) }

        if args.json?
          Support.print_json { |json| json.object { json.field "sites", probes } }
        elsif probes.empty?
          STDOUT.puts "no sites; add one with `berth sites add SITE --name NAME --url URL`"
        else
          rows = probes.map do |probe|
            [probe.site.id, probe.site.name, probe.built ? "built" : "not built", running(probe), badge(probe), shows(probe)]
          end
          STDOUT.puts Format.table([["SITE", "NAME", "APP", "RUNNING", "BADGE", "SHOWING"]] + rows)
        end
        ExitCode::OK
      end

      private def probe(site : Config::Site) : Probe
        built = Dir.exists?(site.app.to_s)
        status = SocketClient.request(site.id, "status", timeout: TIMEOUT)
        Probe.new(site, built, "running", nil, status)
      rescue silent : SocketClient::NoReply
        Probe.new(site, built || false, "no_reply", silent.reason, nil)
      rescue SocketClient::NotRunning
        Probe.new(site, built || false, "not_running", nil, nil)
      rescue error : Error
        Probe.new(site, built || false, "no_reply", error.message, nil)
      end

      private def running(probe : Probe) : String
        case probe.state
        when "running"  then "yes"
        when "no_reply" then "no reply"
        else                 "no"
        end
      end

      private def badge(probe : Probe) : String
        probe.status.try { |status| status["badge"]?.try(&.as_s?) } || ""
      end

      private def shows(probe : Probe) : String
        status = probe.status
        return "" unless status
        config = status["config"]?
        case config.try { |item| item["state"]?.try(&.as_s?) }
        when "loading"
          "loading its config…"
        when "failed"
          "its config did not load: #{first_line(config.try { |item| item["error"]?.try(&.as_s?) })}"
        else
          Format.cut(status["title"]?.try(&.as_s?) || status["url"]?.try(&.as_s?) || "", 60)
        end
      end

      private def first_line(text : String?) : String
        text.try(&.lines.first?).try(&.strip) || "no reason given"
      end
    end

    # Brings a site's app forward, or launches it, and loads a URL in it.
    module Open
      extend self

      HELP = <<-TEXT
        berth open SITE [URL] — bring a site's app forward, or launch it, and load URL

        When the site's app is running it comes forward, and loads URL when one
        is given; a URL whose host the site does not keep opens in the default
        browser instead. When the app is not running it is launched from
        ~/Applications/NAME.app, given URL if there is one. An app that is not
        built yet needs `berth sites build SITE` first.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv)
        Support.help(args, HELP).try { |code| return code }
        args.at_most(2)
        site = Config::Store.model.site!(args.positional(0, "a site"))
        url = args.positionals[1]?
        check_url(url) if url

        begin
          detail = url ? {"url" => JSON::Any.new(url)} : nil
          data = SocketClient.request(site.id, "open", detail)
          report_running(args, site, url, data)
        rescue error : SocketClient::NoReply
          # It may have got the request; launching would only bring it forward.
          raise error
        rescue SocketClient::NotRunning
          launch(args, site, url)
        end
      end

      private def check_url(url : String) : Nil
        uri = URI.parse(url)
        unless {"http", "https"}.includes?(uri.scheme.try(&.downcase)) && !uri.host.to_s.empty?
          raise UsageError.new("#{url} is not an http or https URL")
        end
      rescue URI::Error
        raise UsageError.new("#{url} is not an http or https URL")
      end

      private def report_running(args : Args, site : Config::Site, url : String?, data : JSON::Any) : Int32
        opened_in = data["opened_in"]?.try(&.as_s?) || "app"
        if args.json?
          Support.print_json do |json|
            json.object do
              json.field "ok", true
              json.field "site", site.id
              json.field "launched", false
              json.field "url", url
              json.field "opened_in", opened_in
            end
          end
        elsif url.nil?
          STDOUT.puts "brought #{site.name} forward"
        elsif opened_in == "browser"
          STDOUT.puts "#{url} is outside #{site.name}'s keep hosts; opened it in the default browser"
        else
          STDOUT.puts "opened #{url} in #{site.name}"
        end
        ExitCode::OK
      end

      private def launch(args : Args, site : Config::Site, url : String?) : Int32
        app = site.app
        unless Dir.exists?(app.to_s)
          raise NotFound.new("#{site.name}'s app is not built (no #{app}); run `berth sites build #{site.id}`")
        end
        error = IO::Memory.new
        status = Process.run(Paths.open_command.to_s, ["-a", app.to_s] + (url ? [url] : [] of String),
          output: Process::Redirect::Close, error: error)
        unless status.success?
          detail = error.to_s.strip
          raise Error.new("could not launch #{app}#{detail.empty? ? "" : ": #{detail}"}")
        end

        if args.json?
          Support.print_json do |json|
            json.object do
              json.field "ok", true
              json.field "site", site.id
              json.field "launched", true
              json.field "url", url
              json.field "opened_in", nil
            end
          end
        else
          STDOUT.puts "launched #{site.name}#{url ? " with #{url}" : ""}"
        end
        ExitCode::OK
      end
    end
  end
end
