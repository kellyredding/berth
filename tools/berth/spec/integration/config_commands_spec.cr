require "../spec_helper"

private MAIL_CONFIG = <<-JSON
  {
    "version": 1,
    "sites": {
      "mail": {
        "name": "Mail",
        "url": "https://mail.example.com/",
        "keep": ["mail.example.com", "accounts.example.com"]
      }
    }
  }

  JSON

describe "berth version" do
  it "prints the version from the VERSION file" do
    SpecHelper.sandbox do |sandbox|
      expected = File.read(File.expand_path("../../../../VERSION", __DIR__)).strip
      SpecHelper.run(sandbox, ["version"]).stdout.should eq("berth #{expected}\n")
      SpecHelper.run(sandbox, ["--version"]).stdout.should eq("berth #{expected}\n")
      SpecHelper.run(sandbox, ["version", "--json"]).json["version"].should eq(expected)
    end
  end
end

describe "usage errors" do
  it "exit 2, with the failure as JSON on stdout under --json" do
    SpecHelper.sandbox do |sandbox|
      [
        [] of String,
        ["reticulate"],
        ["sites"],
        ["sites", "list", "--bogus"],
        ["sites", "list", "--name", "X"],
        ["sites", "frobnicate"],
        ["sites", "add", "docs", "--url", "https://docs.example.com/"],
        ["sites", "add", "docs", "--name", "Docs"],
        ["sites", "add", "docs", "--name", "Docs", "--url", "https://docs.example.com/", "--no-icon"],
        ["sites", "set", "mail"],
        ["sites", "set", "mail", "--notifications", "maybe"],
        ["sites", "set", "mail", "--keep", " , "],
        ["sites", "set", "mail", "--icon", "a.png", "--no-icon"],
        ["sites", "set", "mail", "--login", "work"],
        ["sites", "set", "mail", "--steps", "[]"],
        ["sites", "set", "mail", "--login", "work", "--steps", "{not json"],
        ["sites", "set", "mail", "--login", "work", "--steps", %({"flow": "okta"})],
        ["config", "frobnicate"],
        ["config", "show", "--site", "mail"],
        ["config", "validate", "--force"],
      ].each do |args|
        result = SpecHelper.run(sandbox, args)
        result.exit_code.should eq(2), "#{args.join(" ")} exited #{result.exit_code}: #{result.stderr}"
      end
      SpecHelper.run(sandbox, ["sites", "show", "--json"]).json["code"].should eq("usage")
      File.exists?(sandbox.config.to_s).should be_false
    end
  end
end

describe "berth config" do
  it "uses the starter when there is no file" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["config", "export", "--json"])
      result.exit_code.should eq(0)
      result.json["source"].should eq("starter")
      result.json["path"].should eq(sandbox.config.to_s)
      File.exists?(sandbox.config.to_s).should be_false

      SpecHelper.run(sandbox, ["config", "show"]).stdout.should eq(Berth::STARTER_CONFIG)
      path = SpecHelper.run(sandbox, ["config", "path", "--json"]).json
      path["exists"].should eq(false)
      path["source"].should eq("starter")
    end
  end

  it "exports the fixture as the fixture JSON, whole or for one site" do
    SpecHelper.sandbox do |sandbox|
      env = {"BERTH_CONFIG" => (SpecHelper::FIXTURES / "config.json").to_s}
      result = SpecHelper.run(sandbox, ["config", "export", "--json"], env)
      result.exit_code.should eq(0)
      expected = JSON.parse(File.read((SpecHelper::FIXTURES / "export.json").to_s))
      SpecHelper.comparable_export(result.json).should eq(SpecHelper.comparable_export(expected))

      one = SpecHelper.run(sandbox, ["config", "export", "--site", "mail", "--json"], env)
      one.exit_code.should eq(0)
      SpecHelper.comparable_export(one.json)["sites"].should eq(JSON::Any.new({"mail" => expected["sites"]["mail"]}))

      unknown = SpecHelper.run(sandbox, ["config", "export", "--site", "calendar", "--json"], env)
      unknown.exit_code.should eq(5)
      unknown.stderr.should contain(%(no site named "calendar"; the sites are mail, docs))
      unknown.json["code"].should eq("not_found")
    end
  end

  it "exits 1 with the errors on stderr for an invalid config, whichever site is asked for" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG.sub(%("version": 1), %("version": 2)).sub(%("Mail"), %("Mail/Box")))
      result = SpecHelper.run(sandbox, ["config", "export", "--site", "mail", "--json"])
      result.exit_code.should eq(1)
      result.stderr.should contain("version: must be 1")
      result.stderr.should contain(%(sites.mail.name: cannot contain "/" or ":"))
      result.json["code"].should eq("invalid_config")

      validate = SpecHelper.run(sandbox, ["config", "validate", "--json"])
      validate.exit_code.should eq(1)
      validate.json["valid"].should eq(false)
      validate.json["errors"].as_a.size.should eq(2)
    end
  end

  it "validates with warnings on stdout" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG.sub(%("Mail",), %("Mail",\n      "mailto": "https://mail.example.com/?to=%s",)))
      result = SpecHelper.run(sandbox, ["config", "validate"])
      result.exit_code.should eq(0)
      result.stdout.should eq("valid: #{sandbox.config}\nwarning: sites.mail.mailto: unused; add mailto to handles or remove it\n")
    end
  end

  it "reports a file that is not JSON with where parsing stopped, and refuses changes to it" do
    SpecHelper.sandbox do |sandbox|
      broken = %({\n  "version": 1,\n}\n)
      sandbox.write_config(broken)

      validate = SpecHelper.run(sandbox, ["config", "validate", "--json"])
      validate.exit_code.should eq(1)
      validate.json["errors"].as_a.map(&.as_s).should eq([%(not valid JSON: unexpected token '}' at line 3, column 1)])

      add = SpecHelper.run(sandbox, ["sites", "add", "docs", "--name", "Docs", "--url", "https://docs.example.com/"])
      add.exit_code.should eq(1)
      add.stderr.should contain("not valid JSON")
      sandbox.read_config.should eq(broken)
    end
  end

  it "init writes a config with no sites, refuses to overwrite, and writes the starter with --starter --force" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["config", "init"]).exit_code.should eq(0)
      sandbox.read_config.should eq(%({\n  "version": 1,\n  "sites": {}\n}\n))
      SpecHelper.run(sandbox, ["config", "validate"]).exit_code.should eq(0)

      refused = SpecHelper.run(sandbox, ["config", "init", "--starter"])
      refused.exit_code.should eq(1)
      refused.stderr.should contain("--force")

      SpecHelper.run(sandbox, ["config", "init", "--starter", "--force", "--json"]).json["ok"].should eq(true)
      sandbox.read_config.should eq(Berth::STARTER_CONFIG)
      SpecHelper.run(sandbox, ["config", "show"]).stdout.should eq(Berth::STARTER_CONFIG)
    end
  end
end

describe "berth sites" do
  it "lists and shows the sites" do
    SpecHelper.sandbox do |sandbox|
      env = {"BERTH_CONFIG" => (SpecHelper::FIXTURES / "config.json").to_s}
      list = SpecHelper.run(sandbox, ["sites", "list"], env)
      list.exit_code.should eq(0)
      list.stdout.should eq(<<-TEXT)
        SITE  NAME  URL                        LOGINS
        mail  Mail  https://mail.example.com/  personal, work
        docs  Docs  https://docs.example.com/

        TEXT

      listed = SpecHelper.run(sandbox, ["sites", "list", "--json"], env).json["sites"].as_a
      listed.map(&.["site"].as_s).should eq(["mail", "docs"])
      listed[0]["app"].should eq((sandbox.applications / "Mail.app").to_s)

      show = SpecHelper.run(sandbox, ["sites", "show", "mail"], env)
      show.exit_code.should eq(0)
      show.stdout.should contain("  bundle id        com.kellyredding.berth.mail\n")
      show.stdout.should contain("  icon             #{SpecHelper::FIXTURES}/icons/mail.png\n")
      show.stdout.should contain("  signin           personal: google (op://Personal/Example Mail)\n")
      show.stdout.should contain("                   work: google email from op://Work/Example SSO, then okta (op://Work/Example SSO)\n")
      show.stdout.should contain("  app              #{sandbox.applications}/Mail.app\n")

      shown = SpecHelper.run(sandbox, ["sites", "show", "docs", "--json"], env).json
      shown["keep"].should eq(JSON.parse(%(["docs.example.com"])))
      shown["badge"].raw.should be_nil

      missing = SpecHelper.run(sandbox, ["sites", "show", "calendar", "--json"], env)
      missing.exit_code.should eq(5)
      missing.json["code"].should eq("not_found")
    end
  end

  it "says how to add a site when there are none" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["config", "init"]).exit_code.should eq(0)
      SpecHelper.run(sandbox, ["sites", "list"]).stdout.should contain("no sites; add one with `berth sites add")
      SpecHelper.run(sandbox, ["sites", "show", "mail"]).stderr.should contain(%(no site named "mail"; there are no sites))
    end
  end

  it "adds a site with its keys in canonical order, writing the starter plus the site when there is no file" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_png("icons/wiki.png")
      result = SpecHelper.run(sandbox, ["sites", "add", "wiki", "--launch-at-login", "on", "--icon", "icons/wiki.png",
                                        "--url", "https://wiki.example.com/", "--name", "Wiki", "--json"])
      result.exit_code.should eq(0), result.stderr
      result.json["site"]["icon"].should eq((sandbox.root / "icons" / "wiki.png").to_s)
      result.json["site"]["keep"].should eq(JSON.parse(%(["wiki.example.com"])))

      written = sandbox.read_config
      written.should start_with(Berth::STARTER_CONFIG.rchop("\n  }\n}\n"))
      written.should end_with(<<-JSON)
          "wiki": {
            "name": "Wiki",
            "url": "https://wiki.example.com/",
            "icon": "icons/wiki.png",
            "launch_at_login": true
          }
        }
      }

      JSON

      again = SpecHelper.run(sandbox, ["sites", "add", "wiki", "--name", "Wiki 2", "--url", "https://wiki.example.com/"])
      again.exit_code.should eq(1)
      again.stderr.should contain(%(a site named "wiki" already exists))
    end
  end

  it "refuses an invalid result and leaves the file untouched" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG)
      {
        ["sites", "add", "Docs", "--name", "Docs", "--url", "https://docs.example.com/"]                          => "sites.Docs: site names use",
        ["sites", "add", "docs", "--name", "MAIL", "--url", "https://docs.example.com/"]                          => "two sites cannot share an app",
        ["sites", "add", "docs", "--name", "Docs", "--url", "http://docs.example.com/"]                           => "sites.docs.url: must be an https URL",
        ["sites", "set", "mail", "--keep", "*.com"]                                                               => "is too broad",
        ["sites", "set", "mail", "--keep", "accounts.example.com"]                                                => "nothing matches the url's host",
        ["sites", "set", "mail", "--icon", "missing.png"]                                                         => "sites.mail.icon: no file at",
        ["sites", "set", "mail", "--badge-title", "\\d+"]                                                         => "needs exactly one capture group",
        ["sites", "set", "mail", "--handles", "mailto"]                                                           => "sites.mail.mailto: required",
        ["sites", "set", "mail", "--handles", "webcal"]                                                           => "must be one of mailto",
        ["sites", "set", "mail", "--login", "work", "--steps", %([{"flow": "google", "email_from": "op://V/I"}])] => "a step must follow it",
        ["sites", "set", "mail", "--login", "work", "--steps", %([{"flow": "okta", "item": "Work/SSO"}])]         => "must be a 1Password reference",
      }.each do |args, message|
        result = SpecHelper.run(sandbox, args)
        result.exit_code.should eq(1), "#{args.join(" ")} exited #{result.exit_code}: #{result.stderr}"
        result.stderr.should contain("nothing was written")
        result.stderr.should contain(message)
        sandbox.read_config.should eq(MAIL_CONFIG)
      end
    end
  end

  it "sets each key, and puts keys back to their defaults with --no-…" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG)
      icon = sandbox.write_png("icons/mail.png")
      result = SpecHelper.run(sandbox, ["sites", "set", "mail", "--icon", "icons/mail.png", "--badge-title", "\\((\\d+)\\)",
                                        "--handles", "mailto", "--mailto", "https://mail.example.com/compose?to=%s",
                                        "--notifications", "on", "--launch-at-login", "off", "--name", "Webmail",
                                        "--url", "https://mail.example.com/u/0/", "--keep", "mail.example.com, *.example.com"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq("updated site mail\n")
      sandbox.read_config.should eq(<<-JSON)
        {
          "version": 1,
          "sites": {
            "mail": {
              "name": "Webmail",
              "url": "https://mail.example.com/u/0/",
              "keep": ["mail.example.com", "*.example.com"],
              "icon": "icons/mail.png",
              "badge": {
                "title": "\\\\((\\\\d+)\\\\)"
              },
              "handles": ["mailto"],
              "mailto": "https://mail.example.com/compose?to=%s",
              "notifications": true,
              "launch_at_login": false
            }
          }
        }

        JSON

      shown = SpecHelper.run(sandbox, ["sites", "show", "mail", "--json"]).json
      shown["icon"].should eq(icon.to_s)
      shown["badge"]["title"].should eq("\\((\\d+)\\)")
      shown["app"].should eq((sandbox.applications / "Webmail.app").to_s)

      cleared = SpecHelper.run(sandbox, ["sites", "set", "mail", "--no-keep", "--no-icon", "--no-badge", "--no-handles", "--no-mailto"])
      cleared.exit_code.should eq(0), cleared.stderr
      export = SpecHelper.run(sandbox, ["config", "export", "--json"]).json["sites"]["mail"]
      export["keep"].should eq(JSON.parse(%(["mail.example.com"])))
      export["icon"].raw.should be_nil
      export["badge"].raw.should be_nil
      export["handles"].as_a.should be_empty
      export["mailto"].raw.should be_nil
      export["notifications"].should eq(true)
    end
  end

  it "adds, replaces and removes sign-in logins" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG)
      work = %([{"flow": "google", "email_from": "op://Work/SSO"}, {"flow": "okta", "item": "op://Work/SSO"}])
      SpecHelper.run(sandbox, ["sites", "set", "mail", "--login", "work", "--steps", work]).exit_code.should eq(0)
      SpecHelper.run(sandbox, ["sites", "set", "mail", "--login", "personal", "--steps",
                               %([{"flow": "google", "item": "op://Personal/Mail"}])]).exit_code.should eq(0)
      sandbox.read_config.should contain(<<-JSON)
              "signin": {
                "work": [
                  {"flow": "google", "email_from": "op://Work/SSO"},
                  {"flow": "okta", "item": "op://Work/SSO"}
                ],
                "personal": [
                  {"flow": "google", "item": "op://Personal/Mail"}
                ]
              }
        JSON

      SpecHelper.run(sandbox, ["sites", "set", "mail", "--login", "work", "--steps",
                               %([{"flow": "okta", "item": "op://Work/Okta"}])]).exit_code.should eq(0)
      logins = SpecHelper.run(sandbox, ["sites", "show", "mail", "--json"]).json["signin"]
      logins.as_h.keys.should eq(["work", "personal"])
      logins["work"].should eq(JSON.parse(%([{"flow": "okta", "item": "op://Work/Okta", "email_from": null}])))

      missing = SpecHelper.run(sandbox, ["sites", "set", "mail", "--remove-login", "school"])
      missing.exit_code.should eq(5)
      missing.stderr.should contain(%(no login named "school"; the logins are work, personal))

      SpecHelper.run(sandbox, ["sites", "set", "mail", "--remove-login", "work"]).exit_code.should eq(0)
      SpecHelper.run(sandbox, ["sites", "set", "mail", "--remove-login", "personal"]).exit_code.should eq(0)
      sandbox.read_config.should eq(MAIL_CONFIG)

      SpecHelper.run(sandbox, ["sites", "set", "mail", "--login", "me", "--steps", %([{"flow": "okta", "item": "op://V/I"}])]).exit_code.should eq(0)
      SpecHelper.run(sandbox, ["sites", "set", "mail", "--no-signin"]).exit_code.should eq(0)
      sandbox.read_config.should eq(MAIL_CONFIG)
    end
  end

  it "removes a site, and refuses an unknown one as not found" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(MAIL_CONFIG)
      SpecHelper.run(sandbox, ["sites", "set", "docs", "--name", "Docs"]).exit_code.should eq(5)
      SpecHelper.run(sandbox, ["sites", "remove", "docs"]).exit_code.should eq(5)

      removed = SpecHelper.run(sandbox, ["sites", "remove", "mail", "--json"])
      removed.exit_code.should eq(0)
      removed.json["message"].should eq("removed site mail")
      sandbox.read_config.should eq(%({\n  "version": 1,\n  "sites": {}\n}\n))
    end
  end
end

describe "symlink safety" do
  it "rewrites the file a symlinked config points to, keeps the link, and finds icons beside the real file" do
    SpecHelper.sandbox do |sandbox|
      dotfiles = sandbox.root / "dotfiles" / "berth"
      Dir.mkdir_p(dotfiles.to_s)
      real = dotfiles / "config.json"
      File.write(real.to_s, MAIL_CONFIG)
      icon = sandbox.write_png("dotfiles/berth/icons/mail.png")
      File.symlink(real.to_s, sandbox.config.to_s)

      result = SpecHelper.run(sandbox, ["sites", "set", "mail", "--icon", "icons/mail.png"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should contain("wrote #{real}")

      File.symlink?(sandbox.config.to_s).should be_true
      File.readlink(sandbox.config.to_s).should eq(real.to_s)
      File.read(real.to_s).should contain(%("icon": "icons/mail.png"))
      Dir.children(dotfiles.to_s).sort.should eq(["config.json", "icons"])

      SpecHelper.run(sandbox, ["config", "export", "--json"]).json["sites"]["mail"]["icon"].should eq(icon.to_s)
      path = SpecHelper.run(sandbox, ["config", "path", "--json"]).json
      path["path"].should eq(sandbox.config.to_s)
      path["resolved"].should eq(real.to_s)
    end
  end

  it "leaves a symlinked config untouched when a change is refused, and reports a dangling link" do
    SpecHelper.sandbox do |sandbox|
      real = sandbox.root / "elsewhere.json"
      File.write(real.to_s, MAIL_CONFIG)
      File.symlink(real.to_s, sandbox.config.to_s)

      SpecHelper.run(sandbox, ["sites", "set", "mail", "--url", "http://mail.example.com/"]).exit_code.should eq(1)
      File.symlink?(sandbox.config.to_s).should be_true
      File.read(real.to_s).should eq(MAIL_CONFIG)

      File.delete(real.to_s)
      dangling = SpecHelper.run(sandbox, ["sites", "list"])
      dangling.exit_code.should eq(1)
      dangling.stderr.should contain("is a symlink to #{real}, which does not exist")
    end
  end
end
