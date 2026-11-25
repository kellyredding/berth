module Berth
  module Commands
    module Sites
      extend self

      HELP = <<-TEXT
        berth sites — the sites in the config, each its own Mac app

        Actions:
          list
          show SITE
          add SITE --name NAME --url URL [options]
          set SITE [options] [--no-keep] [--no-icon] [--no-badge] [--no-handles]
                   [--no-mailto] [--no-signin]
          remove SITE              Removes it from the config only
          build [SITE…|--all]      Stamp, sign and install site apps; see `berth sites build --help`

        Options:
          --name NAME              Display name and app name (~/Applications/NAME.app)
          --url URL                The https page the app opens
          --keep HOST,HOST         Hosts that stay in the app: exact, or *.example.com
                                   for any subdomain (default: the url's host)
          --icon PATH              A PNG, relative to the config file's real directory
          --badge-title REGEX      Its one capture group in the page title is the Dock badge
          --handles mailto         URL schemes the app handles
          --mailto URL             Where a mailto: link goes, with %s for the link
          --notifications on|off   Show the page's notifications (default off)
          --launch-at-login on|off Open the app at login (default off)
          --login NAME --steps JSON
                                   Add or replace a sign-in login: a JSON list of
                                   steps, each {"flow": "google"|"okta", "item": "op://…"}
                                   or {"flow": "google", "email_from": "op://…"}, with
                                   "account": "example.1password.com" (or an ID)
                                   when the item is not in op's default account, and
                                   for okta, "method": "TEXT" to choose the row of
                                   Okta's verification method list holding TEXT
          --remove-login NAME      Remove a sign-in login

        SITE is lowercase letters, digits and hyphens, and names the app's
        bundle identifier (com.kellyredding.berth.SITE). A --no-… option puts
        the key back to its default. Changes validate the whole config and
        rewrite the file (see `berth config --help`); a site's built app picks
        them up with `berth sites build`.
        TEXT

      VALUES = ["--name", "--url", "--keep", "--icon", "--badge-title", "--handles", "--mailto",
                "--notifications", "--launch-at-login", "--login", "--steps", "--remove-login"]

      # Each --no-… switch and the key it removes.
      CLEARS = {
        "--no-keep"    => "keep",
        "--no-icon"    => "icon",
        "--no-badge"   => "badge",
        "--no-handles" => "handles",
        "--no-mailto"  => "mailto",
        "--no-signin"  => "signin",
      }

      def run(argv : Array(String)) : Int32
        return Build.run(argv[1..]) if argv.first? == "build"

        args = Args.parse(argv, values: VALUES, switches: CLEARS.keys)
        Support.help(args, HELP).try { |code| return code }
        action = args.positional(0, "an action: list, show, add, set or remove")

        case action
        when "list"   then list(args)
        when "show"   then show(args)
        when "add"    then add(args)
        when "set"    then set(args)
        when "remove" then remove(args)
        else
          raise UsageError.new("unknown sites action #{action.inspect}")
        end
      end

      private def list(args : Args) : Int32
        args.at_most(1)
        no_options(args, "list")
        model = Config::Store.model
        if args.json?
          Support.print_json do |json|
            json.object do
              json.field("sites") { json.array { model.sites.each { |site| site_json(json, site) } } }
            end
          end
        elsif model.sites.empty?
          STDOUT.puts "no sites; add one with `berth sites add SITE --name NAME --url URL`"
        else
          rows = model.sites.map do |site|
            [site.id, site.name, site.url, site.signin.keys.join(", ")]
          end
          STDOUT.puts Format.table([["SITE", "NAME", "URL", "LOGINS"]] + rows)
        end
        ExitCode::OK
      end

      private def show(args : Args) : Int32
        args.at_most(2)
        no_options(args, "show")
        site = Config::Store.model.site!(args.positional(1, "a site"))
        if args.json?
          Support.print_json { |json| site_json(json, site) }
        else
          rows = [
            ["name", site.name],
            ["bundle id", site.bundle_id],
            ["url", site.url],
            ["keep", site.keep.join(", ")],
            ["icon", site.icon.try(&.to_s) || "none"],
            ["badge title", site.badge_title || "none"],
            ["handles", site.handles.empty? ? "none" : site.handles.join(", ")],
          ]
          rows << ["mailto", site.mailto.not_nil!] if site.mailto
          rows << ["notifications", Format.on_off(site.notifications)]
          rows << ["launch at login", Format.on_off(site.launch_at_login)]
          if site.signin.empty?
            rows << ["signin", "none"]
          else
            site.signin.each_with_index do |(login, steps), index|
              rows << [index == 0 ? "signin" : "", "#{login}: #{Format.steps(steps)}"]
            end
          end
          rows << ["app", site.app.to_s]
          STDOUT.puts site.id
          STDOUT.puts Format.table(rows).lines.map { |line| "  #{line}" }.join("\n")
        end
        ExitCode::OK
      end

      private def add(args : Args) : Int32
        args.at_most(2)
        id = args.positional(1, "a site")
        CLEARS.each_key { |flag| raise UsageError.new("#{flag} goes with set") if args.switch?(flag) }
        args["--name"] || raise UsageError.new("add needs --name NAME, the app's display name")
        args["--url"] || raise UsageError.new("add needs --url URL, the https page the app opens")
        raise UsageError.new("--remove-login goes with set") if args["--remove-login"]

        outcome = Config::Mutation.apply do |mutation|
          sites = mutation.sites
          raise Error.new("a site named #{id.inspect} already exists") if sites.has_key?(id)
          body = {} of String => JSON::Any
          apply(args, body)
          sites[id] = JSON::Any.new(body)
        end
        report(args, outcome, "added site #{id}", id)
      end

      private def set(args : Args) : Int32
        args.at_most(2)
        id = args.positional(1, "a site")
        changes = VALUES.any? { |flag| args[flag] } || CLEARS.keys.any? { |flag| args.switch?(flag) }
        raise UsageError.new("set needs an option; see `berth sites --help`") unless changes

        outcome = Config::Mutation.apply do |mutation|
          apply(args, mutation.site(id))
        end
        report(args, outcome, "updated site #{id}", id)
      end

      private def remove(args : Args) : Int32
        args.at_most(2)
        no_options(args, "remove")
        id = args.positional(1, "a site")
        outcome = Config::Mutation.apply do |mutation|
          mutation.site(id)
          mutation.sites.delete(id)
        end
        Support.report_mutation(args, outcome, "removed site #{id}")
      end

      # Applies the options to a site's object, each key in canonical position.
      private def apply(args : Args, body : Hash(String, JSON::Any)) : Nil
        put = ->(key : String, value : JSON::Any) { Config::Mutation.put(body, key, value, Config::SITE_KEYS) }

        CLEARS.each do |flag, key|
          next unless args.switch?(flag)
          option = "--#{key.gsub('_', '-')}"
          if args[option] || (key == "badge" && args["--badge-title"]) || (key == "signin" && args["--login"])
            raise UsageError.new("give #{flag} or the option that sets #{key}, not both")
          end
          body.delete(key)
        end

        args["--name"].try { |name| put.call("name", JSON::Any.new(name)) }
        args["--url"].try { |url| put.call("url", JSON::Any.new(url)) }
        args.list("--keep").try { |hosts| put.call("keep", strings(hosts)) }
        args["--icon"].try { |icon| put.call("icon", JSON::Any.new(icon)) }
        args["--badge-title"].try do |title|
          put.call("badge", JSON::Any.new({"title" => JSON::Any.new(title)}))
        end
        args.list("--handles").try { |schemes| put.call("handles", strings(schemes)) }
        args["--mailto"].try { |mailto| put.call("mailto", JSON::Any.new(mailto)) }
        args.bool("--notifications").try { |on| put.call("notifications", JSON::Any.new(on)) }
        args.bool("--launch-at-login").try { |on| put.call("launch_at_login", JSON::Any.new(on)) }
        apply_logins(args, body, put)
      end

      private def apply_logins(args : Args, body : Hash(String, JSON::Any),
                               put : Proc(String, JSON::Any, Nil)) : Nil
        login = args["--login"]
        steps = args["--steps"]
        raise UsageError.new("--login needs --steps JSON") if login && !steps
        raise UsageError.new("--steps goes with --login NAME") if steps && !login

        if login && steps
          signin = body["signin"]?.try(&.as_h?) || {} of String => JSON::Any
          signin[login] = parse_steps(steps)
          put.call("signin", JSON::Any.new(signin))
        end

        if removing = args["--remove-login"]
          signin = body["signin"]?.try(&.as_h?)
          unless signin && signin.has_key?(removing)
            raise NotFound.new("no login named #{removing.inspect}#{signin.try { |logins| logins.empty? ? nil : "; the logins are #{logins.keys.join(", ")}" }}")
          end
          signin.delete(removing)
          body.delete("signin") if signin.empty?
        end
      end

      private def parse_steps(text : String) : JSON::Any
        steps = begin
          Config::Reader.parse(text)
        rescue InvalidConfig
          nil
        end
        return steps if steps && steps.as_a?
        raise UsageError.new(%(--steps needs a JSON list of steps, such as '[{"flow": "google", "item": "op://Vault/Item"}]'))
      end

      private def strings(items : Array(String)) : JSON::Any
        JSON::Any.new(items.map { |item| JSON::Any.new(item) })
      end

      private def no_options(args : Args, action : String) : Nil
        if VALUES.any? { |flag| args[flag] } || CLEARS.keys.any? { |flag| args.switch?(flag) }
          raise UsageError.new("#{action} takes no options but --json")
        end
      end

      private def report(args : Args, outcome : Config::Mutation::Outcome, message : String, id : String) : Int32
        Support.report_mutation(args, outcome, message) do |json|
          if site = outcome.model.site?(id)
            json.field("site") { site_json(json, site) }
          end
        end
      end

      private def site_json(json : JSON::Builder, site : Config::Site) : Nil
        json.object do
          Config::Export.fields(json, site)
          json.field "app", site.app.to_s
        end
      end
    end
  end
end
