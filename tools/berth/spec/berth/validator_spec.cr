require "../spec_helper"

# One site, `mail`, with a valid name and url plus the given keys.
private def site(body : String = "", id : String = "mail") : String
  extra = body.empty? ? "" : ", #{body}"
  %({"sites": {"#{id}": {"name": "Mail", "url": "https://mail.example.com/"#{extra}}}})
end

private def signin(logins : String) : String
  site(%("signin": #{logins}))
end

describe Berth::Config::Validator do
  it "accepts an empty config" do
    result = SpecHelper.validate("{}")
    result.errors.should be_empty
    result.model!.version.should eq(1)
    result.model!.sites.should be_empty
  end

  it "fills every default for a site with only a name and url" do
    model = SpecHelper.validate(site).model!
    mail = model.site!("mail")
    mail.name.should eq("Mail")
    mail.url.should eq("https://mail.example.com/")
    mail.keep.should eq(["mail.example.com"])
    mail.icon.should be_nil
    mail.badge_title.should be_nil
    mail.handles.should be_empty
    mail.mailto.should be_nil
    mail.notifications.should be_false
    mail.launch_at_login.should be_false
    mail.signin.should be_empty
    mail.bundle_id.should eq("com.kellyredding.berth.mail")
  end

  it "reads an optional key set to null as absent" do
    nulls = %("keep": null, "icon": null, "badge": null, "handles": null, "mailto": null, ) +
            %("notifications": null, "launch_at_login": null, "signin": null)
    SpecHelper.validate(site(nulls)).model!.site!("mail").keep.should eq(["mail.example.com"])
  end

  it "needs the config, sites and each site to be objects" do
    SpecHelper.errors("[]").should eq(["the config: must be an object, got []"])
    SpecHelper.errors(%({"sites": []})).should eq(["sites: must be an object, got []"])
    SpecHelper.errors(%({"sites": {"mail": "Mail"}})).should eq([%(sites.mail: must be an object, got "Mail")])
    SpecHelper.errors(%({"sites": {"mail": null}})).should eq(["sites.mail: must be an object"])
  end

  it "needs version 1 and rejects unknown keys at every level" do
    SpecHelper.errors(%({"version": 2})).should eq(["version: must be 1, got 2"])
    SpecHelper.errors(%({"apps": {}})).should eq([%(unknown top-level key "apps")])
    SpecHelper.errors(site(%("colour": "red"))).should eq([%(sites.mail: unknown key "colour")])
    SpecHelper.errors(site(%("badge": {"title": "(\\\\d+)", "colour": "red"})))
      .should eq([%(sites.mail.badge: unknown key "colour")])
    SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": "op://V/I", "otp": true}]})))
      .should eq([%(sites.mail.signin.me[0]: unknown key "otp")])
  end

  it "reports every problem, not just the first" do
    SpecHelper.errors(%({"version": 3, "sites": {"Mail": {"url": "http://x"}}})).size.should eq(4)
  end

  describe "site names" do
    it "use lowercase letters, digits and hyphens, at most 32 characters" do
      ["Mail", "-mail", "mail_box", "mail.box", "a" * 33].each do |id|
        SpecHelper.errors(site(id: id)).first.should contain("site names use lowercase letters"), id
      end
      ["mail", "mail-2", "9to5", "a" * 32].each do |id|
        SpecHelper.errors(site(id: id)).should be_empty, id
      end
    end
  end

  describe "name" do
    it "is required and must be a safe file name" do
      SpecHelper.errors(%({"sites": {"mail": {"url": "https://mail.example.com/"}}})).first
        .should start_with("sites.mail.name: required")
      {
        %(1)             => "must be a string, got 1",
        %("")            => "cannot be empty",
        %(" Mail")       => %(" Mail" has spaces at its start or end),
        %(".Mail")       => %(cannot start with "."),
        %("Mail/Work")   => %(cannot contain "/" or ":", since it names a file),
        %("Mail:Work")   => %(cannot contain "/" or ":", since it names a file),
        %("Mail\\tbox")  => "cannot contain a control character",
        %("#{"M" * 65}") => "must be at most 64 characters",
      }.each do |name, problem|
        errors = SpecHelper.errors(%({"sites": {"mail": {"name": #{name}, "url": "https://mail.example.com/"}}}))
        errors.should eq(["sites.mail.name: #{problem}"]), name
      end
      SpecHelper.errors(%({"sites": {"mail": {"name": "Mail & Calendar — Work", "url": "https://mail.example.com/"}}})).should be_empty
    end

    it "is unique across sites, ignoring case" do
      SpecHelper.errors(%({"sites": {"mail": {"name": "Mail", "url": "https://mail.example.com/"},
        "other": {"name": "MAIL", "url": "https://other.example.com/"}}}))
        .should eq([%(sites.other.name: "MAIL" is also mail's name; two sites cannot share an app)])
    end
  end

  describe "url" do
    it "is a required https URL with a host" do
      SpecHelper.errors(%({"sites": {"mail": {"name": "Mail"}}})).should eq(["sites.mail.url: required; an https URL"])
      [%("http://mail.example.com/"), %("https://"), %("mail.example.com"), %("https://mail example.com/"), %(3)].each do |url|
        SpecHelper.errors(%({"sites": {"mail": {"name": "Mail", "url": #{url}}}}))
          .should eq(["sites.mail.url: must be an https URL, got #{url}"]), url
      end
    end
  end

  describe "keep" do
    it "accepts exact hosts and *.suffix patterns" do
      model = SpecHelper.validate(site(%("keep": ["mail.example.com", "*.sso.example.com", "localhost"]))).model!
      model.site!("mail").keep.should eq(["mail.example.com", "*.sso.example.com", "localhost"])
    end

    it "refuses patterns that are not hosts, and a suffix too broad" do
      {
        "Mail.example.com"         => "is not a host",
        "mail_example.com"         => "is not a host",
        "mail-.example.com"        => "is not a host",
        "*example.com"             => "is not a host",
        "**.example.com"           => "is not a host",
        "https://mail.example.com" => "is not a host",
        "*.com"                    => "is too broad",
      }.each do |pattern, problem|
        errors = SpecHelper.errors(site(%("keep": ["mail.example.com", #{pattern.to_json}])))
        errors.size.should eq(1), pattern
        errors.first.should start_with("sites.mail.keep[1]: #{pattern.inspect} #{problem}")
      end
    end

    it "must be a non-empty list without repeats" do
      SpecHelper.errors(site(%("keep": []))).first.should start_with("sites.mail.keep: must be a list of hosts")
      SpecHelper.errors(site(%("keep": "mail.example.com"))).first.should start_with("sites.mail.keep: must be a list of hosts")
      SpecHelper.errors(site(%("keep": ["mail.example.com", 3]))).should eq(["sites.mail.keep[1]: must be a host, got 3"])
      SpecHelper.errors(site(%("keep": ["mail.example.com", "mail.example.com"])))
        .should eq([%(sites.mail.keep: "mail.example.com" is listed more than once)])
    end

    it "must match the url's host" do
      SpecHelper.errors(site(%("keep": ["accounts.example.com"])))
        .should eq([%(sites.mail.keep: nothing matches the url's host "mail.example.com"; add it)])
      SpecHelper.errors(site(%("keep": ["*.example.com"]))).should be_empty
    end
  end

  describe "Berth::Config.keeps?" do
    it "matches exact hosts, and *.suffix against subdomains only, ignoring case" do
      Berth::Config.keeps?("mail.example.com", "mail.example.com").should be_true
      Berth::Config.keeps?("mail.example.com", "MAIL.Example.com").should be_true
      Berth::Config.keeps?("mail.example.com", "x.mail.example.com").should be_false
      Berth::Config.keeps?("*.example.com", "a.b.example.com").should be_true
      Berth::Config.keeps?("*.example.com", "example.com").should be_false
      Berth::Config.keeps?("*.example.com", "badexample.com").should be_false
    end
  end

  describe "icon" do
    it "resolves a relative path from the config file's real directory" do
      SpecHelper.sandbox do |sandbox|
        icon = sandbox.write_png("dotfiles/icons/mail.png")
        File.write((sandbox.root / "dotfiles" / "config.json").to_s, site(%("icon": "icons/mail.png")))
        File.symlink("dotfiles/config.json", sandbox.config.to_s)

        model = Berth::Config::Store.model(sandbox.config)
        model.site!("mail").icon.should eq(icon)
      end
    end

    it "accepts an absolute path" do
      SpecHelper.sandbox do |sandbox|
        icon = sandbox.write_png("elsewhere/mail.png")
        SpecHelper.validate(site(%("icon": #{icon.to_s.to_json})), sandbox.config).model!.site!("mail").icon.should eq(icon)
      end
    end

    it "must exist and be a PNG" do
      SpecHelper.sandbox do |sandbox|
        SpecHelper.errors(site(%("icon": "icons/mail.png")), sandbox.config)
          .should eq(["sites.mail.icon: no file at #{sandbox.root}/icons/mail.png"])

        File.write((sandbox.root / "mail.jpg").to_s, "\xFF\xD8\xFF\xE0 not a png")
        SpecHelper.errors(site(%("icon": "mail.jpg")), sandbox.config)
          .should eq(["sites.mail.icon: #{sandbox.root}/mail.jpg is not a PNG"])

        File.write((sandbox.root / "short.png").to_s, "\x89PN")
        SpecHelper.errors(site(%("icon": "short.png")), sandbox.config)
          .should eq(["sites.mail.icon: #{sandbox.root}/short.png is not a PNG"])

        Dir.mkdir_p((sandbox.root / "icons.png").to_s)
        SpecHelper.errors(site(%("icon": "icons.png")), sandbox.config)
          .should eq(["sites.mail.icon: no file at #{sandbox.root}/icons.png"])

        SpecHelper.errors(site(%("icon": 3)), sandbox.config).should eq(["sites.mail.icon: must be the path of a PNG file, got 3"])
      end
    end
  end

  describe "badge" do
    it "needs a title with exactly one capture group" do
      SpecHelper.validate(site(%("badge": {"title": "\\\\((\\\\d+)\\\\)"}))).model!.site!("mail").badge_title.should eq("\\((\\d+)\\)")
      SpecHelper.errors(site(%("badge": {"title": "(?<count>\\\\d+)"}))).should be_empty
      SpecHelper.errors(site(%("badge": {"title": "\\\\d+"})))
        .should eq(["sites.mail.badge.title: needs exactly one capture group, the badge text; it has 0"])
      SpecHelper.errors(site(%("badge": {"title": "(\\\\w+) \\\\((\\\\d+)\\\\)"})))
        .should eq(["sites.mail.badge.title: needs exactly one capture group, the badge text; it has 2"])
    end

    it "must compile" do
      error = SpecHelper.errors(site(%|"badge": {"title": "(\\\\d+"}|)).first
      error.should start_with("sites.mail.badge.title: does not compile: ")
    end

    it "must be an object with a string title" do
      SpecHelper.errors(site(%("badge": "(\\\\d+)"))).should eq([%(sites.mail.badge: must be an object, got "(\\\\d+)")])
      SpecHelper.errors(site(%("badge": {}))).should eq(["sites.mail.badge: needs a title, a regular expression with one capture group"])
      SpecHelper.errors(site(%("badge": {"title": 1}))).should eq(["sites.mail.badge.title: must be a regular expression, got 1"])
    end
  end

  describe "handles and mailto" do
    mailto = %("mailto": "https://mail.example.com/compose?to=%s")

    it "handles mailto with a compose URL" do
      mail = SpecHelper.validate(site(%("handles": ["mailto"], #{mailto}))).model!.site!("mail")
      mail.handles.should eq(["mailto"])
      mail.mailto.should eq("https://mail.example.com/compose?to=%s")
    end

    it "accepts only known schemes, once each" do
      SpecHelper.errors(site(%("handles": ["webcal"]))).should eq([%(sites.mail.handles[0]: must be one of mailto, got "webcal")])
      SpecHelper.errors(site(%("handles": ["mailto", "mailto"], #{mailto})))
        .should eq([%(sites.mail.handles: "mailto" is listed more than once)])
      SpecHelper.errors(site(%("handles": "mailto"))).first.should start_with("sites.mail.handles: must be a list of URL schemes")
    end

    it "needs mailto when handles has mailto" do
      SpecHelper.errors(site(%("handles": ["mailto"]))).first.should start_with(%(sites.mail.mailto: required when handles has "mailto"))
    end

    it "needs mailto to be an https URL with %s exactly once" do
      ["https://mail.example.com/compose", "https://mail.example.com/compose?to=%s&cc=%s",
       "http://mail.example.com/compose?to=%s", "compose?to=%s"].each do |url|
        SpecHelper.errors(site(%("handles": ["mailto"], "mailto": #{url.to_json})))
          .should eq(["sites.mail.mailto: must be an https URL with %s exactly once, where the mailto: link goes, got #{url.to_json}"]), url
      end
      SpecHelper.errors(site(%("handles": ["mailto"], "mailto": "https://mail.example.com/#compose/%s?x=%40"))).should be_empty
    end

    it "warns about a mailto that handles does not use" do
      result = SpecHelper.validate(site(mailto))
      result.errors.should be_empty
      result.warnings.should eq(["sites.mail.mailto: unused; add mailto to handles or remove it"])
    end
  end

  describe "notifications and launch_at_login" do
    it "are booleans" do
      mail = SpecHelper.validate(site(%("notifications": true, "launch_at_login": true))).model!.site!("mail")
      mail.notifications.should be_true
      mail.launch_at_login.should be_true
      SpecHelper.errors(site(%("notifications": "on"))).should eq([%(sites.mail.notifications: must be true or false, got "on")])
      SpecHelper.errors(site(%("launch_at_login": 1))).should eq(["sites.mail.launch_at_login: must be true or false, got 1"])
    end
  end

  describe "signin" do
    it "reads named logins of ordered steps" do
      mail = SpecHelper.validate(signin(<<-JSON)).model!.site!("mail")
        {
          "personal": [{"flow": "google", "item": "op://Personal/Example Mail"}],
          "work": [
            {"flow": "google", "email_from": "op://Work/Example SSO/username"},
            {"flow": "okta", "item": "op://Work/Example SSO"}
          ]
        }
        JSON
      mail.signin.keys.should eq(["personal", "work"])
      mail.signin["personal"].should eq([Berth::Config::Step.new("google", "op://Personal/Example Mail", nil)])
      mail.signin["work"].should eq([
        Berth::Config::Step.new("google", nil, "op://Work/Example SSO/username"),
        Berth::Config::Step.new("okta", "op://Work/Example SSO", nil),
      ])
    end

    it "names logins like sites, each a non-empty list" do
      SpecHelper.errors(signin(%({"Work": [{"flow": "okta", "item": "op://V/I"}]})))
        .should eq(["sites.mail.signin.Work: login names use lowercase letters, digits and hyphens, starting with a letter or digit"])
      SpecHelper.errors(signin(%({"work": []}))).first.should start_with("sites.mail.signin.work: must be a list of sign-in steps")
      SpecHelper.errors(signin(%({"work": {"flow": "okta"}}))).first.should start_with("sites.mail.signin.work: must be a list of sign-in steps")
      SpecHelper.errors(signin(%(["work"]))).should eq([%(sites.mail.signin: must be an object, got ["work"])])
      SpecHelper.errors(signin(%({}))).should be_empty
    end

    it "needs each step's flow to be google or okta" do
      SpecHelper.errors(signin(%({"work": [{"flow": "saml", "item": "op://V/I"}]})))
        .should eq([%(sites.mail.signin.work[0].flow: must be one of google, okta, got "saml")])
      SpecHelper.errors(signin(%({"work": [{"item": "op://V/I"}]})))
        .should eq(["sites.mail.signin.work[0].flow: must be one of google, okta, got nothing"])
      SpecHelper.errors(signin(%({"work": ["op://V/I"]})))
        .should eq([%(sites.mail.signin.work[0]: must be an object, got "op://V/I")])
    end

    it "needs exactly one of item and email_from, with email_from only for google" do
      SpecHelper.errors(signin(%({"work": [{"flow": "google", "item": "op://V/I", "email_from": "op://V/I"}, {"flow": "okta", "item": "op://V/I"}]})))
        .should eq(["sites.mail.signin.work[0]: give item or email_from, not both"])
      SpecHelper.errors(signin(%({"work": [{"flow": "okta"}]})))
        .should eq(["sites.mail.signin.work[0]: needs an item (sign in with it) or email_from (give only its email)"])
      SpecHelper.errors(signin(%({"work": [{"flow": "okta", "email_from": "op://V/I"}, {"flow": "okta", "item": "op://V/I"}]})))
        .should eq(["sites.mail.signin.work[0].email_from: only a google step can give only the email"])
    end

    it "needs a step after an email_from step" do
      SpecHelper.errors(signin(%({"work": [{"flow": "google", "email_from": "op://V/I"}]})))
        .should eq(["sites.mail.signin.work[0]: an email_from step hands off to the next step's sign-in, so a step must follow it"])
    end

    it "needs an item to be op://VAULT/ITEM, since it reads the item's username, password and code" do
      ["op://V/I", "op://Private Vault/Some Item"].each do |reference|
        SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": #{reference.to_json}}]}))).should be_empty, reference
      end
      ["op://V", "op://V/", "op:///I", "op://V/I/password", "op://V/I/Section/field", "op://V/ /f", "V/I", "https://V/I"].each do |reference|
        SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": #{reference.to_json}}]})))
          .should eq(["sites.mail.signin.me[0].item: must be a 1Password item, op://VAULT/ITEM, got #{reference.to_json}"]), reference
      end
    end

    it "needs an email_from to be op://VAULT/ITEM, optionally with a field" do
      ["op://V/I", "op://V/I/username", "op://V/I/Section/email"].each do |reference|
        SpecHelper.errors(signin(%({"me": [{"flow": "google", "email_from": #{reference.to_json}}, {"flow": "okta", "item": "op://V/I"}]})))
          .should be_empty, reference
      end
      ["op://V", "op:///I", "op://V/ /f", "op://V/I/S/f/x", "V/I"].each do |reference|
        SpecHelper.errors(signin(%({"me": [{"flow": "google", "email_from": #{reference.to_json}}, {"flow": "okta", "item": "op://V/I"}]})))
          .should eq(["sites.mail.signin.me[0].email_from: must be a 1Password reference, op://VAULT/ITEM " \
                      "(optionally /FIELD or /SECTION/FIELD), got #{reference.to_json}"]), reference
      end
      SpecHelper.errors(signin(%({"me": [{"flow": "google", "email_from": 7}, {"flow": "okta", "item": "op://V/I"}]})))
        .first.should start_with("sites.mail.signin.me[0].email_from: must be a 1Password reference")
    end

    it "reads an optional 1Password account for each step" do
      mail = SpecHelper.validate(signin(<<-JSON)).model!.site!("mail")
        {
          "work": [
            {"flow": "google", "email_from": "op://Work/SSO", "account": "example.1password.com"},
            {"flow": "okta", "item": "op://Work/SSO", "account": "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}
          ],
          "personal": [{"flow": "google", "item": "op://Personal/Mail", "account": null}]
        }
        JSON
      mail.signin["work"].should eq([
        Berth::Config::Step.new("google", nil, "op://Work/SSO", "example.1password.com"),
        Berth::Config::Step.new("okta", "op://Work/SSO", nil, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
      ])
      mail.signin["personal"].first.account.should be_nil
    end

    it "needs an account to be a sign-in address or an ID" do
      ["https://example.1password.com", "my 1password", "", ".example.com", "example.com-", "a" * 129, "me@example.com"].each do |account|
        SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": "op://V/I", "account": #{account.to_json}}]})))
          .should eq(["sites.mail.signin.me[0].account: must be a 1Password account, its sign-in address " \
                      "(such as example.1password.com) or its ID, got #{account.to_json}"]), account
      end
      SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": "op://V/I", "account": 7}]})))
        .first.should start_with("sites.mail.signin.me[0].account: must be a 1Password account")
    end

    it "reads an optional verification method for an okta step" do
      mail = SpecHelper.validate(signin(<<-JSON)).model!.site!("mail")
        {
          "work": [
            {"flow": "google", "email_from": "op://Work/SSO"},
            {"flow": "okta", "item": "op://Work/SSO", "method": "Example Authenticator"}
          ],
          "personal": [{"flow": "okta", "item": "op://Personal/SSO", "method": null}]
        }
        JSON
      mail.signin["work"].last.should eq(Berth::Config::Step.new("okta", "op://Work/SSO", nil, nil, "Example Authenticator"))
      mail.signin["personal"].first.method.should be_nil
      SpecHelper.errors(signin(%({"me": [{"flow": "okta", "item": "op://V/I", "method": #{("m" * 64).to_json}}]}))).should be_empty
    end

    it "needs a method to be non-empty text of at most 64 characters" do
      [JSON::Any.new(""), JSON::Any.new("   "), JSON::Any.new("m" * 65), JSON::Any.new(7_i64), JSON::Any.new(true),
       JSON.parse(%(["Example Authenticator"]))].each do |method|
        SpecHelper.errors(signin(%({"me": [{"flow": "okta", "item": "op://V/I", "method": #{method.to_json}}]})))
          .should eq(["sites.mail.signin.me[0].method: must be the text of a verification method in Okta's list, " \
                      "1 to 64 characters, got #{method.to_json}"]), method.to_json
      end
    end

    it "refuses a method on a google step, since only Okta lists methods" do
      SpecHelper.errors(signin(%({"me": [{"flow": "google", "item": "op://V/I", "method": "Example Authenticator"}]})))
        .should eq(["sites.mail.signin.me[0].method: only an okta step chooses a verification method; Okta alone lists them"])
      SpecHelper.errors(signin(%({"me": [{"flow": "google", "email_from": "op://V/I", "method": "Example Authenticator"},
                                         {"flow": "okta", "item": "op://V/I"}]})))
        .should eq(["sites.mail.signin.me[0].method: only an okta step chooses a verification method; Okta alone lists them"])
    end
  end
end

describe Berth::Config::Reader do
  it "reads strict JSON and reports where it stops parsing" do
    {
      ""                             => "line 1, column 1",
      %({"sites": [})                => "line 1, column 12",
      %({\n  "version": 1,\n}\n)     => "line 3, column 1",
      %(// mine\n{"version": 1}\n)   => "line 1, column 1",
      %({"version": 1 /* mine */}\n) => "line 1, column 15",
    }.each do |text, location|
      error = expect_raises(Berth::InvalidConfig) { Berth::Config::Reader.parse(text) }
      error.errors.size.should eq(1)
      error.errors.first.should start_with("not valid JSON: ")
      error.errors.first.should contain(location), "#{text.inspect}: #{error.errors.first}"
    end
  end

  it "rejects a repeated key at any depth, naming where" do
    error = expect_raises(Berth::InvalidConfig) do
      Berth::Config::Reader.parse(%({\n  "sites": {\n    "mail": {"name": "A",\n      "name": "B"}\n  }\n}\n))
    end
    error.errors.should eq([%(not valid JSON: duplicate key "name" at line 4, column 7)])
  end

  it "keeps key order" do
    Berth::Config::Reader.parse(%({"b": 1, "a": {"z": 1, "y": 2}})).to_json.should eq(%({"b":1,"a":{"z":1,"y":2}}))
  end
end
