require "../spec_helper"

describe "commands that are not built yet" do
  it "fail with exit 1 saying so, and still show their help" do
    SpecHelper.sandbox do |sandbox|
      {
        ["signin", "mail", "--account", "work"]       => "signin is not built yet",
        ["update", "--local"]                         => "update is not built yet",
        ["update", "--version", "0.1.0", "--preview"] => "update is not built yet",
      }.each do |args, message|
        result = SpecHelper.run(sandbox, args + ["--json"])
        result.exit_code.should eq(1), "#{args.join(" ")} exited #{result.exit_code}: #{result.stderr}"
        result.stderr.should contain(message)
        result.json["ok"].should eq(false)

        help = SpecHelper.run(sandbox, args + ["--help"])
        help.exit_code.should eq(0)
        help.stdout.should contain("Not built yet")
      end
      SpecHelper.run(sandbox, ["signin", "mail", "--user", "x"]).exit_code.should eq(2)
    end
  end
end

describe "berth doctor" do
  it "checks the config, says each site's app is not built, and what it does not check yet" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["doctor"])
      result.exit_code.should eq(0)
      result.stdout.should eq(<<-TEXT)
        ok    cli          berth #{Berth::VERSION}
        ok    config path  #{sandbox.config} (missing: using the built-in starter)
        ok    config       valid: 2 sites (docs, mail)
        info  install      install record and template checks are not built yet
        warn  docs app     not built: no #{sandbox.applications}/Docs.app; run `berth sites build docs`
        warn  mail app     not built: no #{sandbox.applications}/Mail.app; run `berth sites build mail`

        TEXT

      json = SpecHelper.run(sandbox, ["doctor", "--json"]).json
      json["ok"].should eq(true)
      json["config"]["source"].should eq("starter")
      json["checks"].as_a.map(&.["level"].as_s).should eq(["ok", "ok", "ok", "info", "warn", "warn"])
      json["sites"][0]["built"].should eq(false)
      json["sites"][0]["running"].should eq(false)
    end
  end

  it "checks each built site app: its stamp, signer, registration and whether it runs" do
    SpecHelper.sandbox do |sandbox|
      docs = SpecHelper.write_site_app(sandbox.applications / "Docs.app", "docs")
      mail = SpecHelper.write_site_app(sandbox.applications / "Mail.app", "mail", signer: "adhoc")
      sandbox.register([
        {docs.to_s, "com.kellyredding.berth.docs"},
        {"/Users/me/Old/Docs.app", "com.kellyredding.berth.docs"},
        {"/src/berth/BerthApp/build/Build/Products/Debug/Berth.app", "com.kellyredding.berth"},
      ])
      status = %({"ok": true, "data": {"version": "0.1.0", "pid": 4242, "site": "docs"}})
      SpecHelper.with_app(sandbox, "docs", {"status" => status}) do
        result = SpecHelper.run_live(sandbox, ["doctor"])
        result.exit_code.should eq(0), result.stderr
        lines = result.stdout.lines
        lines.should contain("warn  launch services  a development build is registered at " \
                             "/src/berth/BerthApp/build/Build/Products/Debug/Berth.app; `berth sites build` unregisters it")
        lines.should contain("ok    docs app         #{docs}: com.kellyredding.berth.docs, version 0.1.0")
        lines.should contain("ok    docs signer      Berth Release Signing")
        lines.should contain("ok    docs registered  Launch Services knows #{docs}")
        lines.should contain("warn  docs registered  another copy of com.kellyredding.berth.docs is registered at /Users/me/Old/Docs.app")
        lines.should contain("ok    docs running     running (pid 4242, version 0.1.0)")
        lines.should contain("warn  mail signer      signed ad hoc: macOS may forget its notification permission " \
                             "and login item; rebuild with `berth sites build mail`")
        lines.should contain("warn  mail registered  Launch Services does not know #{mail}; `berth sites build mail` registers it")
        lines.should contain("info  mail running     not running")

        json = SpecHelper.run_live(sandbox, ["doctor", "--json"]).json
        docs_json = json["sites"][0]
        docs_json["signature"].should eq("release")
        docs_json["registered"].should eq(true)
        docs_json["other_copies"].should eq(JSON.parse(%(["/Users/me/Old/Docs.app"])))
        docs_json["running"].should eq(true)
        json["sites"][1]["signature"].should eq("adhoc")
        json["sites"][1]["registered"].should eq(false)
      end
    end
  end

  it "fails when a site's app is another site's or its signature does not verify" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_site_app(sandbox.applications / "Docs.app", "mail", "com.kellyredding.berth.mail")
      SpecHelper.write_site_app(sandbox.applications / "Mail.app", "mail", signer: nil)
      result = SpecHelper.run(sandbox, ["doctor"])
      result.exit_code.should eq(1)
      result.stdout.should contain("FAIL  docs app         #{sandbox.applications}/Docs.app is not docs's app: its bundle " \
                                   "identifier is com.kellyredding.berth.mail and BerthSite mail, not " \
                                   "com.kellyredding.berth.docs and docs")
      result.stdout.should contain("FAIL  mail signer      its signature does not verify: " \
                                   "#{sandbox.applications}/Mail.app: code object is not signed at all")
    end
  end

  it "says when a site's app is a link, and a copy registered while it is not built" do
    SpecHelper.sandbox do |sandbox|
      target = SpecHelper.write_site_app(sandbox.root / "build" / "Docs.app", "docs")
      Dir.mkdir_p(sandbox.applications.to_s)
      File.symlink(target.to_s, (sandbox.applications / "Docs.app").to_s)
      sandbox.register([{target.to_s, "com.kellyredding.berth.docs"},
                        {"/Users/me/Old/Mail.app", "com.kellyredding.berth.mail"}])
      result = SpecHelper.run(sandbox, ["doctor"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should contain("warn  docs app         #{sandbox.applications}/Docs.app: com.kellyredding.berth.docs, " \
                                   "version 0.1.0, through a link to #{target}; `berth sites build docs` replaces " \
                                   "the link with a signed copy")
      result.stdout.should contain("ok    docs registered  Launch Services knows #{sandbox.applications}/Docs.app")
      result.stdout.should contain("warn  mail registered  another copy of com.kellyredding.berth.mail is registered " \
                                   "at /Users/me/Old/Mail.app")
    end
  end

  it "fails on an invalid config and warns about warnings" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(%({"sites": {"mail": {"name": "Mail", "url": "https://mail.example.com/", ) +
                           %("mailto": "https://mail.example.com/?to=%s"}}}))
      warned = SpecHelper.run(sandbox, ["doctor"])
      warned.exit_code.should eq(0)
      warned.stdout.should contain("warn  config       sites.mail.mailto: unused")

      sandbox.write_config(%({"sites": {"mail": {"name": "Mail"}}}))
      failed = SpecHelper.run(sandbox, ["doctor", "--json"])
      failed.exit_code.should eq(1)
      failed.json["ok"].should eq(false)
      failed.json["config"]["errors"].should eq(JSON.parse(%(["sites.mail.url: required; an https URL"])))
    end
  end

  it "reports a dangling config link as a failed check" do
    SpecHelper.sandbox do |sandbox|
      File.symlink((sandbox.root / "gone.json").to_s, sandbox.config.to_s)
      result = SpecHelper.run(sandbox, ["doctor"])
      result.exit_code.should eq(1)
      result.stdout.should contain("FAIL  config path  #{sandbox.config} is a symlink to #{sandbox.root}/gone.json, which does not exist")
    end
  end
end
