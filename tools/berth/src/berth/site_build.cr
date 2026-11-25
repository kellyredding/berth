require "file_utils"

module Berth
  # `berth sites build`: copies the template once per site beside its app,
  # stamps the copy's Info.plist and icon, signs every copy in one session,
  # then swaps each into place by rename and registers it with Launch
  # Services. No destination changes until every copy is signed and verified.
  # It never launches, quits or restarts an app.
  module SiteBuild
    extend self

    TEMPLATE_ID = "com.kellyredding.berth"
    # The release certificate's common name (bin/signing-identity), which a
    # signed app shows as its Authority. Not the 1Password item's title.
    IDENTITY  = "Berth Release Signing"
    ICON_FILE = "SiteIcon"

    # Where `sign-app.sh op` finds the identity in 1Password. It inherits them
    # from this process; nothing in the repository names either.
    ACCOUNT_VARIABLE = "BERTH_SIGNING_OP_ACCOUNT"
    ITEM_VARIABLE    = "BERTH_SIGNING_OP_ITEM"

    # The files of a full iconset, and each one's size in pixels.
    ICONSET = {
      "icon_16x16.png"      => 16,
      "icon_16x16@2x.png"   => 32,
      "icon_32x32.png"      => 32,
      "icon_32x32@2x.png"   => 64,
      "icon_128x128.png"    => 128,
      "icon_128x128@2x.png" => 256,
      "icon_256x256.png"    => 256,
      "icon_256x256@2x.png" => 512,
      "icon_512x512.png"    => 512,
      "icon_512x512@2x.png" => 1024,
    }

    enum Signing
      Op
      Adhoc

      def label : String
        to_s.downcase
      end

      def signer : String
        op? ? IDENTITY : "ad hoc"
      end

      def signed : String
        op? ? "signed by #{IDENTITY}" : "signed ad hoc"
      end
    end

    record Template, path : Path, version : String?, commit : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", path.to_s
          json.field "version", version
          json.field "commit", commit
        end
      end

      def describe : String
        details = [version.try { |value| "version #{value}" }, commit.try { |value| "commit #{value}" }].compact
        details.empty? ? path.to_s : "#{path} (#{details.join(", ")})"
      end
    end

    enum Action
      Create
      Replace
      ReplaceLink

      def label : String
        to_s.underscore
      end
    end

    record Plan, site : Config::Site, action : Action, link_target : String?, running : Bool do
      def app : Path
        site.app
      end

      # Beside the app, so the swap is a rename on one volume. Launch Services
      # registers it anyway (seen on macOS 26.6), so `swap` unregisters it.
      def staging : Path
        app.parent / ".#{app.basename}.berth-new"
      end

      def old : Path
        app.parent / ".#{app.basename}.berth-old"
      end
    end

    record Outcome, plans : Array(Plan), register_errors : Hash(String, String), unregistered : Array(String),
      notes : Array(String)

    # The template at `path`, refused unless it is a Berth template: the
    # template's bundle identifier and no site of its own.
    def template(path : Path) : Template
      unless Dir.exists?(path.to_s)
        raise Error.new("no template app at #{path}; install Berth, or in a checkout run " \
                        "`make -C BerthApp release` and pass --template BerthApp/build/Build/Products/Release/Berth.app")
      end
      plist = MacOS::InfoPlist.new(path)
      raise Error.new("#{path} is not a Berth template: it has no Info.plist") unless plist.exists?
      id = plist["CFBundleIdentifier"]
      unless id == TEMPLATE_ID
        raise Error.new("#{path} is not a Berth template: its bundle identifier is #{id || "missing"}, not #{TEMPLATE_ID}")
      end
      if site = plist["BerthSite"]
        raise Error.new("#{path} is not a Berth template: it is a site app (BerthSite #{site})")
      end
      Template.new(path, plist["CFBundleShortVersionString"], plist["BerthBuildCommit"])
    end

    # Refuses `--sign op` when either variable is unset, empty or malformed,
    # naming each, before anything is copied.
    def require_signing_env : Nil
      problems = [] of String
      account = ENV[ACCOUNT_VARIABLE]?
      if account.nil? || account.empty?
        problems << "#{ACCOUNT_VARIABLE} is not set: the 1Password account that holds the signing identity, " \
                    "its sign-in address or account ID\n  export #{ACCOUNT_VARIABLE}='<account>.1password.com'"
      end
      item = ENV[ITEM_VARIABLE]?
      if item.nil? || item.empty?
        problems << "#{ITEM_VARIABLE} is not set: the signing identity's 1Password item\n" \
                    "  export #{ITEM_VARIABLE}='op://<vault>/<item>'"
      elsif OnePassword.parts(item).try(&.size) != 2
        problems << "#{ITEM_VARIABLE} must be the signing identity's 1Password item, op://VAULT/ITEM, with no field\n" \
                    "  export #{ITEM_VARIABLE}='op://<vault>/<item>'"
      end
      return if problems.empty?
      raise SigningNotConfigured.new(
        "--sign op reads the signing identity from 1Password, named by #{ACCOUNT_VARIABLE} and #{ITEM_VARIABLE}; " \
        "set them in your shell profile (--sign adhoc needs neither, for development only)", problems)
    end

    # What building `site` would do to its app, refusing a destination that
    # is not this site's Berth app.
    def plan(site : Config::Site) : Plan
      app = site.app
      info = File.info?(app.to_s, follow_symlinks: false)
      if info.nil?
        Plan.new(site, Action::Create, nil, running?(site))
      elsif info.symlink?
        Plan.new(site, Action::ReplaceLink, File.readlink(app.to_s), running?(site))
      else
        refuse_foreign(site, app, info)
        Plan.new(site, Action::Replace, nil, running?(site))
      end
    end

    def build(plans : Array(Plan), template : Template, signing : Signing, script : Path) : Outcome
      Dir.mkdir_p(Paths.applications_dir.to_s)
      begin
        plans.each { |plan| stage(plan, template) }
        sign(plans, signing, script)
        plans.each { |plan| verify(plan, signing) }
        plans.each { |plan| swap(plan) }
      ensure
        plans.each { |plan| FileUtils.rm_rf(plan.staging.to_s) }
      end

      register_errors = {} of String => String
      plans.each do |plan|
        MacOS::LaunchServices.register(plan.app).try { |reason| register_errors[plan.site.id] = reason }
      end
      notes = [] of String
      unregistered = begin
        copies = MacOS::LaunchServices.development_copies(MacOS::LaunchServices.registrations)
        copies.each { |path| MacOS::LaunchServices.unregister(path) }
        copies
      rescue error : Error
        notes << "could not look for development builds registered with Launch Services: #{error.message}"
        [] of String
      end
      Outcome.new(plans, register_errors, unregistered, notes)
    end

    # The Info.plist keys that make a copy of the template one site's app.
    # The template's version and BerthBuildCommit are left as they are.
    def stamp(site : Config::Site, app : Path) : Nil
      plist = MacOS::InfoPlist.new(app)
      plist["CFBundleIdentifier"] = site.bundle_id
      plist["CFBundleName"] = site.name
      plist["CFBundleDisplayName"] = site.name
      plist["BerthSite"] = site.id
      plist.delete("CFBundleURLTypes")
      unless site.handles.empty?
        types = [{"CFBundleURLName"    => JSON::Any.new(site.bundle_id),
                  "CFBundleURLSchemes" => JSON::Any.new(site.handles.map { |scheme| JSON::Any.new(scheme) })}]
        plist.set_json("CFBundleURLTypes", types.to_json)
      end
      if icon = site.icon
        write_icon(icon, app / "Contents" / "Resources" / "#{ICON_FILE}.icns")
        plist["CFBundleIconFile"] = ICON_FILE
        # MEASURED (macOS 26.6): while this names the template's asset-catalog
        # icon, Finder and the Dock show that one, not CFBundleIconFile's.
        plist.delete("CFBundleIconName")
      end
    end

    def running?(site : Config::Site) : Bool
      SocketClient.request(site.id, "status", timeout: Commands::Status::TIMEOUT)
      true
    rescue SocketClient::NoReply
      true
    rescue SocketClient::NotRunning
      false
    rescue Error
      true
    end

    private def refuse_foreign(site : Config::Site, app : Path, info : File::Info) : Nil
      problem = foreign_problem(site, app, info)
      return unless problem
      raise Error.new("refused: #{app} is not #{site.id}'s Berth app (#{problem}); " \
                      "move it aside and build again. Nothing was changed.")
    end

    private def foreign_problem(site : Config::Site, app : Path, info : File::Info) : String?
      return "it is not an app bundle" unless info.directory?
      plist = MacOS::InfoPlist.new(app)
      return "it has no Info.plist" unless plist.exists?
      id = plist["CFBundleIdentifier"]
      unless id && id.starts_with?(Config::BUNDLE_PREFIX)
        return "its bundle identifier is #{id || "missing"}"
      end
      berth_site = plist["BerthSite"]
      return nil if berth_site == site.id
      berth_site ? "it is the app for the site #{berth_site}" : "it names no site"
    end

    private def stage(plan : Plan, template : Template) : Nil
      FileUtils.rm_rf(plan.staging.to_s)
      # Without extended attributes: a quarantine flag or Finder info left on
      # the copy makes codesign refuse it.
      MacOS.run!(MacOS::DITTO, ["--noextattr", "--noqtn", template.path.to_s, plan.staging.to_s],
        "could not copy the template to #{plan.staging}")
      stamp(plan.site, plan.staging)
    end

    private def write_icon(png : Path, icns : Path) : Nil
      work = Path.new(File.tempname("berth-icon"))
      iconset = work / "icon.iconset"
      Dir.mkdir_p(iconset.to_s)
      ICONSET.each do |name, size|
        MacOS.run!(Paths.sips, ["-z", size.to_s, size.to_s, "-s", "format", "png", png.to_s, "--out", (iconset / name).to_s],
          "could not resize #{png} to #{size} px")
      end
      Dir.mkdir_p(icns.parent.to_s)
      MacOS.run!(Paths.iconutil, ["-c", "icns", "-o", icns.to_s, iconset.to_s], "could not make an icon from #{png}")
    ensure
      work.try { |dir| FileUtils.rm_rf(dir.to_s) }
    end

    # One run of the script for every app, so the release identity costs one
    # 1Password approval. Its output goes to stderr, keeping stdout for
    # --json, and it may ask the user to approve.
    private def sign(plans : Array(Plan), signing : Signing, script : Path) : Nil
      status = Process.run(script.to_s, [signing.label] + plans.map(&.staging.to_s),
        input: Process::Redirect::Inherit, output: STDERR, error: STDERR)
      return if status.success?
      if status.exit_code? == ExitCode::NOT_PERMITTED
        raise NotPermitted.new("1Password did not provide the signing identity; nothing was installed")
      end
      raise Error.new("signing failed (#{describe(status)}); nothing was installed")
    rescue error : File::Error | IO::Error
      raise Error.new("could not run #{script}: #{error.message}")
    end

    private def verify(plan : Plan, signing : Signing) : Nil
      site = plan.site
      signature = MacOS::Signature.read(plan.staging)
      problem = if !signature.verified
                  "does not verify: #{signature.problem}"
                elsif signature.identifier != site.bundle_id
                  "is signed as #{signature.identifier || "nothing"}, not #{site.bundle_id}"
                elsif signing.op? && !signature.release?
                  "is signed by #{signature.signer}, not #{IDENTITY}"
                elsif signing.adhoc? && !signature.adhoc
                  "is signed by #{signature.signer}, not ad hoc"
                end
      raise Error.new("#{site.name}'s new app #{problem}; nothing was installed") if problem
    end

    # A running app keeps its old bundle open, so it runs on until restarted.
    private def swap(plan : Plan) : Nil
      app = plan.app
      FileUtils.rm_rf(plan.old.to_s)
      info = File.info?(app.to_s, follow_symlinks: false)
      moved_aside = false
      link_target = nil
      if info && info.symlink?
        # The link itself; whatever it points to is left alone.
        link_target = File.readlink(app.to_s)
        File.delete(app.to_s)
      elsif info
        refuse_foreign(plan.site, app, info)
        File.rename(app.to_s, plan.old.to_s)
        moved_aside = true
      end
      begin
        File.rename(plan.staging.to_s, app.to_s)
      rescue error : File::Error
        File.rename(plan.old.to_s, app.to_s) if moved_aside
        link_target.try { |target| File.symlink(target, app.to_s) }
        raise Error.new("could not move #{plan.site.name}'s new app into place: #{error.message}")
      end
      FileUtils.rm_rf(plan.old.to_s) if moved_aside
      [plan.staging, plan.old].each { |gone| MacOS::LaunchServices.unregister(gone.to_s) }
    end

    private def describe(status : Process::Status) : String
      if code = status.exit_code?
        "exit #{code}"
      else
        "signal #{status.exit_signal?.try(&.to_s) || "unknown"}"
      end
    end
  end
end
