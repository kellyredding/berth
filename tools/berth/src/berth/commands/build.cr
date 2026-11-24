module Berth
  module Commands
    # `berth sites build`: see SiteBuild.
    module Build
      extend self

      HELP = <<-TEXT
        berth sites build [SITE…|--all] [--template PATH] [--sign op|adhoc] [--preview]
          — stamp, sign and install site apps

        Copies the Berth template once per site to ~/Applications/NAME.app,
        stamped with the site's bundle identifier (com.kellyredding.berth.SITE),
        name, URL schemes and icon, and signed. Each app is swapped in by
        rename, so a failed build leaves the old one in place, and registered
        with Launch Services. A link at the destination is replaced (its target
        is left alone); anything there that is not this site's Berth app is
        refused. Nothing is launched, quit or restarted: a running app keeps
        its old build until you restart it.

        Options:
          --all             Every site in the config
          --template PATH   The template Berth.app (default ~/.berth/template/Berth.app;
                            in a checkout, `make -C BerthApp release` builds
                            BerthApp/build/Build/Products/Release/Berth.app)
          --sign op         Sign with "Berth Release Signing" from 1Password: one
                            approval for every app in the build (the default)
          --sign adhoc      Sign with no identity, for development only: macOS may
                            forget an ad-hoc app's permissions on every rebuild
          --preview         Print what it would do and change nothing
        TEXT

      ADHOC_WARNING = <<-TEXT
        berth: WARNING: --sign adhoc signs with no identity. macOS may treat every
        rebuild as a new app and forget its notification permission and login
        item. Use it for development only; install with the default, --sign op.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv, values: ["--template", "--sign"], switches: ["--all", "--preview"])
        Support.help(args, HELP).try { |code| return code }
        signing = signing(args["--sign"])
        all = args.switch?("--all")
        ids = args.positionals.uniq
        raise UsageError.new("give sites or --all, not both") if all && !ids.empty?
        raise UsageError.new("name the sites to build, or give --all") if !all && ids.empty?

        model = Config::Store.model
        sites = all ? model.sites : ids.map { |id| model.site!(id) }
        raise NotFound.new("there are no sites to build; add one with `berth sites add`") if sites.empty?

        STDERR.puts ADHOC_WARNING if signing.adhoc?
        template = SiteBuild.template(args["--template"].try { |path| Path.new(path).expand } || Paths.template_app)
        script = Paths.sign_script || raise Error.new(
          "no signing script; looked for #{Paths.sign_script_candidates.join(", ")}. " \
          "Install Berth, or set BERTH_SIGN_SCRIPT to bin/lib/sign-app.sh")
        plans = sites.map { |site| SiteBuild.plan(site) }

        if args.switch?("--preview")
          preview(args, plans, template, signing, script)
          return ExitCode::OK
        end

        if signing.op?
          STDERR.puts "Signing #{count(plans.size)} with #{SiteBuild::IDENTITY}: one 1Password approval covers them all."
        end
        outcome = SiteBuild.build(plans, template, signing, script)
        report(args, outcome, template, signing, script)
        ExitCode::OK
      end

      private def signing(value : String?) : SiteBuild::Signing
        case value
        when nil, "op" then SiteBuild::Signing::Op
        when "adhoc"   then SiteBuild::Signing::Adhoc
        else
          raise UsageError.new("--sign takes op or adhoc, not #{value.inspect}")
        end
      end

      private def preview(args : Args, plans : Array(SiteBuild::Plan), template : SiteBuild::Template,
                          signing : SiteBuild::Signing, script : Path) : Nil
        if args.json?
          print_json(true, plans, template, signing, script) { }
          return
        end
        STDOUT.puts "Would build #{count(plans.size)} from #{template.describe}:"
        plans.each do |plan|
          STDOUT.puts "  #{plan.site.id}: #{action(plan)}"
          STDOUT.puts "    as #{plan.site.bundle_id}, #{icon(plan.site)}, #{handles(plan.site)}"
          STDOUT.puts "    #{running(plan)}" if plan.running
        end
        approval = signing.op? ? ", one 1Password approval" : ""
        STDOUT.puts "S#{signing.signed[1..]}#{approval}, with #{script}"
        STDOUT.puts "Preview only: nothing was changed."
      end

      private def report(args : Args, outcome : SiteBuild::Outcome, template : SiteBuild::Template,
                         signing : SiteBuild::Signing, script : Path) : Nil
        if args.json?
          print_json(false, outcome.plans, template, signing, script) do |json, plan|
            error = outcome.register_errors[plan.site.id]?
            json.field "registered", error.nil?
            json.field "register_error", error
          end
          return
        end
        outcome.plans.each do |plan|
          STDOUT.puts "built #{plan.site.name}: #{plan.app} (#{plan.site.bundle_id}), #{signing.signed}"
          plan.link_target.try { |target| STDOUT.puts "  replaced a link to #{target}; its target is untouched" }
          outcome.register_errors[plan.site.id]?.try do |reason|
            STDOUT.puts "  Launch Services did not register it: #{reason}"
          end
          STDOUT.puts "  #{running(plan)}" if plan.running
        end
        outcome.unregistered.each { |path| STDOUT.puts "unregistered the development build #{path}" }
        outcome.notes.each { |note| STDOUT.puts note }
      end

      private def print_json(preview : Bool, plans : Array(SiteBuild::Plan), template : SiteBuild::Template,
                             signing : SiteBuild::Signing, script : Path,
                             &extra : JSON::Builder, SiteBuild::Plan ->) : Nil
        Support.print_json do |json|
          json.object do
            json.field "ok", true
            json.field "preview", preview
            json.field "template", template
            json.field("sign") do
              json.object do
                json.field "mode", signing.label
                json.field "signer", signing.signer
                json.field "script", script.to_s
              end
            end
            json.field("sites") do
              json.array do
                plans.each do |plan|
                  json.object do
                    json.field "site", plan.site.id
                    json.field "name", plan.site.name
                    json.field "app", plan.app.to_s
                    json.field "bundle_id", plan.site.bundle_id
                    json.field "action", plan.action.label
                    json.field "link_target", plan.link_target
                    json.field "icon", plan.site.icon.try(&.to_s)
                    json.field "handles", plan.site.handles
                    json.field "running", plan.running
                    extra.call(json, plan)
                  end
                end
              end
            end
          end
        end
      end

      private def count(size : Int32) : String
        size == 1 ? "1 site app" : "#{size} site apps"
      end

      private def action(plan : SiteBuild::Plan) : String
        case plan.action
        in .create?       then "create #{plan.app}"
        in .replace?      then "replace #{plan.app}"
        in .replace_link? then "replace #{plan.app}, a link to #{plan.link_target} (its target is left alone)"
        end
      end

      private def icon(site : Config::Site) : String
        site.icon.try { |path| "icon #{path}" } || "the template's icon"
      end

      private def handles(site : Config::Site) : String
        site.handles.empty? ? "no URL schemes" : "handles #{site.handles.join(", ")}"
      end

      private def running(plan : SiteBuild::Plan) : String
        "#{plan.site.name} is running; it keeps its old build until you restart it"
      end
    end
  end
end
