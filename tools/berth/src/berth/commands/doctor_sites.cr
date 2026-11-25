module Berth
  module Commands
    module Doctor
      # Each configured site's app: built and stamped for this site, from the
      # installed template, signed with the release identity, known to Launch
      # Services, and running.
      module SiteAppChecks
        extend self

        record Report,
          site : String,
          app : String,
          built : Bool,
          link_target : String?,
          bundle_id : String?,
          berth_site : String?,
          version : String?,
          commit : String?,
          signer : String?,
          signature : String?,
          registered : Bool?,
          other_copies : Array(String),
          running : Bool do
          def to_json(json : JSON::Builder) : Nil
            json.object do
              json.field "site", site
              json.field "app", app
              json.field "built", built
              json.field "link_target", link_target
              json.field "bundle_id", bundle_id
              json.field "berth_site", berth_site
              json.field "version", version
              json.field "commit", commit
              json.field "signer", signer
              json.field "signature", signature
              json.field "registered", registered
              json.field "other_copies", other_copies
              json.field "running", running
            end
          end
        end

        # `template_commit` is the installed template's build commit, nil when
        # there is no install to compare a site app with.
        def run(model : Config::Model, checks : Array(Check),
                registrations : Array(MacOS::LaunchServices::Registration)?, template_commit : String?) : Array(Report)
          registrations.try do |found|
            MacOS::LaunchServices.development_copies(found).each do |path|
              checks << Check.new(Level::Warn, "launch services",
                "a development build is registered at #{path}; `berth sites build` unregisters it")
            end
          end
          model.sites.map { |site| check(site, registrations, template_commit, checks) }
        end

        private def check(site : Config::Site, registrations : Array(MacOS::LaunchServices::Registration)?,
                          template_commit : String?, checks : Array(Check)) : Report
          app = site.app
          link_target = File.symlink?(app.to_s) ? File.readlink(app.to_s) : nil
          built = Dir.exists?(app.to_s)
          places = [app.to_s]
          places << File.realpath(app.to_s) if built
          others = (registrations || [] of MacOS::LaunchServices::Registration)
            .select { |entry| entry.identifier == site.bundle_id && !places.includes?(entry.path) }
            .map(&.path).uniq
          running = running?(site)

          unless built
            checks << Check.new(Level::Warn, "#{site.id} app", "not built: no #{app}; run `berth sites build #{site.id}`")
            others.each { |path| checks << other_copy(site, path) }
            checks << Check.new(Level::Ok, "#{site.id} running", running) if running
            return Report.new(site.id, app.to_s, false, link_target, nil, nil, nil, nil, nil, nil, nil, others, !running.nil?)
          end

          plist = MacOS::InfoPlist.new(app)
          bundle_id = plist["CFBundleIdentifier"]
          berth_site = plist["BerthSite"]
          version = plist["CFBundleShortVersionString"]
          commit = plist["BerthBuildCommit"]
          ours = bundle_id == site.bundle_id && berth_site == site.id
          if ours
            detail = "#{app}: #{bundle_id}#{version.try { |value| ", version #{value}" }}"
            if link_target
              checks << Check.new(Level::Warn, "#{site.id} app",
                "#{detail}, through a link to #{link_target}; `berth sites build #{site.id}` replaces the link with a signed copy")
            else
              checks << Check.new(Level::Ok, "#{site.id} app", detail)
            end
          else
            checks << Check.new(Level::Fail, "#{site.id} app",
              "#{app} is not #{site.id}'s app: its bundle identifier is #{bundle_id || "missing"} and BerthSite " \
              "#{berth_site || "missing"}, not #{site.bundle_id} and #{site.id}")
          end
          if ours && template_commit
            checks << build_check(site, commit, template_commit)
          end

          signature = MacOS::Signature.read(app)
          checks << signer_check(site, signature)

          registered = registrations.try { |found| found.any? { |entry| places.includes?(entry.path) } }
          unless registered.nil?
            checks << if registered
              Check.new(Level::Ok, "#{site.id} registered", "Launch Services knows #{app}")
            else
              Check.new(Level::Warn, "#{site.id} registered",
                "Launch Services does not know #{app}; `berth sites build #{site.id}` registers it")
            end
          end
          others.each { |path| checks << other_copy(site, path) }
          checks << Check.new(running ? Level::Ok : Level::Info, "#{site.id} running", running || "not running")

          Report.new(site.id, app.to_s, true, link_target, bundle_id, berth_site, version, commit,
            signature.signer, signature.kind, registered, others, !running.nil?)
        end

        # A site app keeps the template's BerthBuildCommit, so it names the
        # template it was copied from.
        private def build_check(site : Config::Site, commit : String?, template_commit : String) : Check
          name = "#{site.id} build"
          if commit == template_commit
            Check.new(Level::Ok, name, "from the installed template (#{commit})")
          else
            Check.new(Level::Warn, name, "built from #{commit ? "the template at #{commit}" : "a template with no build commit"}, " \
                                         "not the installed one (#{template_commit}); rebuild with `berth sites build --all`")
          end
        end

        private def signer_check(site : Config::Site, signature : MacOS::Signature) : Check
          name = "#{site.id} signer"
          case signature.kind
          when "release"
            Check.new(Level::Ok, name, SiteBuild::IDENTITY)
          when "adhoc"
            Check.new(Level::Warn, name, "signed ad hoc: macOS may forget its notification permission and login " \
                                         "item; rebuild with `berth sites build #{site.id}`")
          when "invalid"
            Check.new(Level::Fail, name, "its signature does not verify: #{signature.problem}")
          else
            Check.new(Level::Warn, name, "signed by #{signature.signer}, not #{SiteBuild::IDENTITY}; " \
                                         "rebuild with `berth sites build #{site.id}`")
          end
        end

        private def other_copy(site : Config::Site, path : String) : Check
          Check.new(Level::Warn, "#{site.id} registered", "another copy of #{site.bundle_id} is registered at #{path}")
        end

        # What the running app says of itself, or nil when it does not answer.
        private def running?(site : Config::Site) : String?
          status = SocketClient.request(site.id, "status", timeout: Status::TIMEOUT)
          details = [status["pid"]?.try(&.as_i64?).try { |pid| "pid #{pid}" },
                     status["version"]?.try(&.as_s?).try { |version| "version #{version}" }].compact
          details.empty? ? "running" : "running (#{details.join(", ")})"
        rescue SocketClient::NoReply
          "connected, but it did not reply"
        rescue SocketClient::NotRunning
          nil
        rescue error : Error
          "answered with an error: #{error.message}"
        end
      end
    end
  end
end
