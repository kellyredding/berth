require "../spec_helper"

private def build(sandbox : SpecHelper::Sandbox, args : Array(String),
                  extra_env : Hash(String, String?) = {} of String => String?) : SpecHelper::Result
  SpecHelper.run(sandbox, ["sites", "build"] + args, extra_env)
end

# Everything left in the applications directory, hidden staging copies included.
private def applications(sandbox : SpecHelper::Sandbox) : Array(String)
  Dir.exists?(sandbox.applications.to_s) ? Dir.children(sandbox.applications.to_s).sort : [] of String
end

private def with_icon(sandbox : SpecHelper::Sandbox) : Nil
  sandbox.write_png("icons/docs.png")
  sandbox.write_config(<<-JSON)
    {
      "sites": {
        "docs": {"name": "Docs", "url": "https://docs.example.com/", "icon": "icons/docs.png"},
        "mail": {"name": "Mail", "url": "https://mail.example.com/", "handles": ["mailto"],
                 "mailto": "https://mail.example.com/compose?to=%s"}
      }
    }
    JSON
end

describe "berth sites build" do
  it "stamps a copy of the template for each site" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      result = build(sandbox, ["--all"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq(<<-TEXT)
        built Docs: #{sandbox.applications}/Docs.app (com.kellyredding.berth.docs), signed by Berth Release Signing
        built Mail: #{sandbox.applications}/Mail.app (com.kellyredding.berth.mail), signed by Berth Release Signing

        TEXT
      result.stderr.should contain("Signing 2 site apps with Berth Release Signing: one 1Password approval covers them all.")

      docs = SpecHelper.plist(sandbox.applications / "Docs.app")
      docs["CFBundleIdentifier"].should eq("com.kellyredding.berth.docs")
      docs["CFBundleName"].should eq("Docs")
      docs["CFBundleDisplayName"].should eq("Docs")
      docs["BerthSite"].should eq("docs")
      docs["CFBundleShortVersionString"].should eq("0.1.0")
      docs["BerthBuildCommit"].should eq("abc123def456")
      docs["CFBundleExecutable"].should eq("Berth")
      docs.as_h.has_key?("CFBundleURLTypes").should be_false

      mail = SpecHelper.plist(sandbox.applications / "Mail.app")
      mail["CFBundleIdentifier"].should eq("com.kellyredding.berth.mail")
      mail["BerthSite"].should eq("mail")
      mail["CFBundleURLTypes"].should eq(JSON.parse(
        %([{"CFBundleURLName": "com.kellyredding.berth.mail", "CFBundleURLSchemes": ["mailto"]}])))

      # The template itself is never changed, and no staging copy is left.
      SpecHelper.plist(sandbox.template).as_h.has_key?("BerthSite").should be_false
      applications(sandbox).should eq(["Docs.app", "Mail.app"])
    end
  end

  it "signs every site in one call to the signing script, so one approval covers them" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      build(sandbox, ["mail", "docs", "mail"]).exit_code.should eq(0)
      calls = sandbox.calls("sign")
      calls.size.should eq(1)
      calls.first.should eq("op #{sandbox.applications}/.Mail.app.berth-new #{sandbox.applications}/.Docs.app.berth-new")
      sandbox.calls("codesign").should contain("--verify --strict #{sandbox.applications}/.Docs.app.berth-new")
    end
  end

  it "registers each app with Launch Services and unregisters development builds" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      sandbox.register([{"/src/berth/BerthApp/build/Build/Products/Release/Berth.app", "com.kellyredding.berth"},
                        {"/Applications/Other.app", "com.example.other"}])
      result = build(sandbox, ["docs"])
      result.exit_code.should eq(0), result.stderr
      sandbox.calls("lsregister").should eq([
        "-f #{sandbox.applications}/Docs.app",
        "-dump",
        "-u /src/berth/BerthApp/build/Build/Products/Release/Berth.app",
      ])
      result.stdout.should contain("unregistered the development build /src/berth/BerthApp/build/Build/Products/Release/Berth.app\n")
    end
  end

  it "converts a site's icon to a full iconset and keeps the template's icon otherwise" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      with_icon(sandbox)
      result = build(sandbox, ["--all"])
      result.exit_code.should eq(0), result.stderr

      docs = sandbox.applications / "Docs.app"
      plist = SpecHelper.plist(docs)
      plist["CFBundleIconFile"].should eq("SiteIcon")
      plist.as_h.has_key?("CFBundleIconName").should be_false
      File.read((docs / "Contents" / "Resources" / "SiteIcon.icns").to_s).lines.should eq([
        "icon_128x128.png", "icon_128x128@2x.png", "icon_16x16.png", "icon_16x16@2x.png",
        "icon_256x256.png", "icon_256x256@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
        "icon_512x512.png", "icon_512x512@2x.png",
      ])
      sizes = sandbox.calls("sips").map { |call| call.split[1].to_i }
      sizes.sort.should eq([16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])
      sandbox.calls("sips").first.should contain(" -s format png #{sandbox.root}/icons/docs.png --out ")
      sandbox.calls("iconutil").size.should eq(1)

      mail = SpecHelper.plist(sandbox.applications / "Mail.app")
      mail["CFBundleIconFile"].should eq("AppIcon")
      mail["CFBundleIconName"].should eq("AppIcon")
    end
  end

  it "replaces the site's own earlier app" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      old = SpecHelper.write_site_app(sandbox.applications / "Docs.app", "docs")
      File.write((old / "Contents" / "stale").to_s, "from the old build")
      result = build(sandbox, ["docs", "--json"])
      result.exit_code.should eq(0), result.stderr
      result.json["sites"][0]["action"].should eq("replace")
      result.json["sites"][0]["registered"].should eq(true)
      File.exists?((old / "Contents" / "stale").to_s).should be_false
      SpecHelper.plist(old)["BerthBuildCommit"].should eq("abc123def456")
      applications(sandbox).should eq(["Docs.app"])
    end
  end

  it "replaces a link at the destination without touching its target" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      target = SpecHelper.write_site_app(sandbox.root / "elsewhere" / "Docs.app", "docs")
      Dir.mkdir_p(sandbox.applications.to_s)
      File.symlink(target.to_s, (sandbox.applications / "Docs.app").to_s)

      result = build(sandbox, ["docs"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should contain("  replaced a link to #{target}; its target is untouched\n")
      File.symlink?((sandbox.applications / "Docs.app").to_s).should be_false
      SpecHelper.plist(sandbox.applications / "Docs.app")["BerthBuildCommit"].should eq("abc123def456")
      SpecHelper.plist(target).as_h.has_key?("BerthBuildCommit").should be_false
      File.read((target / "Contents" / ".fake-signature").to_s).should eq("Berth Release Signing\ncom.kellyredding.berth.docs\n")
    end
  end

  it "refuses an app at the destination that is not this site's, changing nothing" do
    {
      "com.example.other"           => "docs",
      "com.kellyredding.berth.mail" => "mail",
    }.each do |bundle_id, site|
      SpecHelper.sandbox do |sandbox|
        sandbox.write_template
        foreign = SpecHelper.write_site_app(sandbox.applications / "Docs.app", site, bundle_id)
        before = File.read((foreign / "Contents" / "Info.plist").to_s)

        result = build(sandbox, ["--all", "--json"])
        result.exit_code.should eq(1)
        result.stderr.should contain("refused: #{foreign} is not docs's Berth app (")
        result.stderr.should contain("Nothing was changed.")
        result.json["ok"].should eq(false)
        File.read((foreign / "Contents" / "Info.plist").to_s).should eq(before)
        applications(sandbox).should eq(["Docs.app"])
        sandbox.calls("sign").should be_empty
        sandbox.calls("lsregister").should be_empty
      end
    end
  end

  it "refuses a plain file or a bundle without an Info.plist at the destination" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      Dir.mkdir_p(sandbox.applications.to_s)
      File.write((sandbox.applications / "Docs.app").to_s, "not an app")
      build(sandbox, ["docs"]).stderr.should contain("(it is not an app bundle)")
      File.delete((sandbox.applications / "Docs.app").to_s)
      Dir.mkdir_p((sandbox.applications / "Docs.app" / "Contents").to_s)
      build(sandbox, ["docs"]).stderr.should contain("(it has no Info.plist)")
      sandbox.calls("sign").should be_empty
    end
  end

  it "previews the plan and changes nothing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      with_icon(sandbox)
      target = sandbox.root / "elsewhere" / "Mail.app"
      Dir.mkdir_p(sandbox.applications.to_s)
      File.symlink(target.to_s, (sandbox.applications / "Mail.app").to_s)

      result = build(sandbox, ["--all", "--preview"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq(<<-TEXT)
        Would build 2 site apps from #{sandbox.template} (version 0.1.0, commit abc123def456):
          docs: create #{sandbox.applications}/Docs.app
            as com.kellyredding.berth.docs, icon #{sandbox.root}/icons/docs.png, no URL schemes
          mail: replace #{sandbox.applications}/Mail.app, a link to #{target} (its target is left alone)
            as com.kellyredding.berth.mail, the template's icon, handles mailto
        Signed by Berth Release Signing, one 1Password approval, with #{sandbox.fakes}/sign-app.sh
        Preview only: nothing was changed.

        TEXT

      json = build(sandbox, ["--all", "--preview", "--json"]).json
      json["preview"].should eq(true)
      json["sign"].should eq(JSON.parse(%({"mode": "op", "signer": "Berth Release Signing", ) +
                                        %("script": "#{sandbox.fakes}/sign-app.sh"})))
      json["sites"].as_a.map(&.["action"].as_s).should eq(["create", "replace_link"])
      json["template"]["commit"].should eq("abc123def456")

      applications(sandbox).should eq(["Mail.app"])
      File.symlink?((sandbox.applications / "Mail.app").to_s).should be_true
      sandbox.calls("sign").should be_empty
      sandbox.calls("sips").should be_empty
      sandbox.calls("lsregister").should be_empty
    end
  end

  it "says a running app keeps its old build until restarted, and never stops it" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      SpecHelper.write_site_app(sandbox.applications / "Docs.app", "docs")
      status = %({"ok": true, "data": {"version": "0.1.0", "pid": 99, "site": "docs"}})
      SpecHelper.with_app(sandbox, "docs", {"status" => status}) do |app|
        result = SpecHelper.run_live(sandbox, ["sites", "build", "docs"])
        result.exit_code.should eq(0), result.stderr
        result.stdout.should contain("  Docs is running; it keeps its old build until you restart it\n")
        app.requests.map(&.["event"].as_s).should eq(["status"])
      end
    end
  end

  it "warns loudly when signing ad hoc" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      result = build(sandbox, ["docs", "--sign", "adhoc"])
      result.exit_code.should eq(0), result.stderr
      result.stderr.should contain("WARNING: --sign adhoc signs with no identity")
      result.stderr.should contain("forget its notification permission and login")
      result.stdout.should contain("(com.kellyredding.berth.docs), signed ad hoc\n")
      sandbox.calls("sign").should eq(["adhoc #{sandbox.applications}/.Docs.app.berth-new"])
    end
  end

  it "installs nothing when 1Password declines or the signature is not the release identity's" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      declined = build(sandbox, ["--all", "--json"], {"FAKE_SIGN_EXIT" => "4"})
      declined.exit_code.should eq(4)
      declined.json["code"].should eq("not_permitted")
      declined.stderr.should contain("1Password did not provide the signing identity; nothing was installed")
      applications(sandbox).should be_empty

      failed = build(sandbox, ["docs"], {"FAKE_SIGN_EXIT" => "1"})
      failed.exit_code.should eq(1)
      failed.stderr.should contain("signing failed (exit 1); nothing was installed")

      wrong = build(sandbox, ["docs"], {"FAKE_SIGN_AUTHORITY" => "Someone Else"})
      wrong.exit_code.should eq(1)
      wrong.stderr.should contain("Docs's new app is signed by Someone Else, not Berth Release Signing; nothing was installed")
      applications(sandbox).should be_empty
      sandbox.calls("lsregister").should be_empty
    end
  end

  it "refuses a missing template, or one that is not a Berth template" do
    SpecHelper.sandbox do |sandbox|
      missing = build(sandbox, ["docs"])
      missing.exit_code.should eq(1)
      missing.stderr.should contain("no template app at #{sandbox.template}; install Berth, or in a checkout run " \
                                    "`make -C BerthApp release` and pass --template BerthApp/build/Build/Products/Release/Berth.app")

      sandbox.write_template("com.example.other")
      build(sandbox, ["docs"]).stderr.should contain(
        "#{sandbox.template} is not a Berth template: its bundle identifier is com.example.other, not com.kellyredding.berth")

      site_app = SpecHelper.write_site_app(sandbox.root / "Docs.app", "docs")
      result = build(sandbox, ["docs", "--template", site_app.to_s])
      result.exit_code.should eq(1)
      result.stderr.should contain("#{site_app} is not a Berth template: its bundle identifier is com.kellyredding.berth.docs")
      sandbox.calls("sign").should be_empty
    end
  end

  it "takes --template relative to the current directory" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_bundle(sandbox.root / "dev" / "Berth.app",
        "<key>CFBundleIdentifier</key><string>com.kellyredding.berth</string>")
      result = SpecHelper.run(sandbox, ["sites", "build", "docs", "--template", "dev/Berth.app", "--preview"],
        chdir: sandbox.root.to_s)
      result.exit_code.should eq(0), result.stderr
      result.stdout.should contain("Would build 1 site app from #{sandbox.root}/dev/Berth.app:\n")
    end
  end

  it "refuses unknown sites and bad usage before changing anything" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      unknown = build(sandbox, ["docs", "calendar", "--json"])
      unknown.exit_code.should eq(5)
      unknown.json["code"].should eq("not_found")
      unknown.stderr.should contain(%(no site named "calendar"; the sites are docs, mail))

      build(sandbox, [] of String).exit_code.should eq(2)
      build(sandbox, ["docs", "--all"]).exit_code.should eq(2)
      build(sandbox, ["docs", "--sign", "keychain"]).stderr.should contain(%(--sign takes op or adhoc, not "keychain"))
      build(sandbox, ["docs", "--force"]).exit_code.should eq(2)

      sandbox.write_config(%({"sites": {}}))
      build(sandbox, ["--all"]).exit_code.should eq(5)
      applications(sandbox).should be_empty
      sandbox.calls("sign").should be_empty
    end
  end

  it "finds the signing script in the checkout it was built in, else in the install" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_template
      unset = {"BERTH_SIGN_SCRIPT" => nil} of String => String?
      checkout = File.expand_path("../../../../bin/lib/sign-app.sh", __DIR__)
      build(sandbox, ["docs", "--preview"], unset).stdout.should contain("with #{checkout}\n")

      installed = sandbox.root / "bin" / "berth"
      Dir.mkdir_p(installed.parent.to_s)
      File.copy(SpecHelper::BINARY, installed.to_s)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(installed.to_s, ["sites", "build", "docs", "--preview"],
        env: sandbox.env.merge(unset), output: stdout, error: stderr)
      status.exit_code.should eq(1)
      stderr.to_s.should contain("no signing script; looked for #{sandbox.root}/libexec/sign-app.sh")

      SpecHelper.write_executable(sandbox.root / "libexec" / "sign-app.sh", "#!/bin/sh\n")
      stdout = IO::Memory.new
      Process.run(installed.to_s, ["sites", "build", "docs", "--preview"], env: sandbox.env.merge(unset), output: stdout)
      stdout.to_s.should contain("with #{sandbox.root}/libexec/sign-app.sh\n")
    end
  end
end
