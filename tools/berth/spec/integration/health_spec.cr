require "../spec_helper"

describe "commands that are not built yet" do
  it "fail with exit 1 saying so, and still show their help" do
    SpecHelper.sandbox do |sandbox|
      {
        ["status"]                                    => "status is not built yet",
        ["open", "mail"]                              => "open is not built yet",
        ["open", "mail", "https://mail.example.com/"] => "open is not built yet",
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
  it "checks the config and says what it does not check yet" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["doctor"])
      result.exit_code.should eq(0)
      result.stdout.should match(/^ok    config path  #{Regex.escape(sandbox.config.to_s)} \(missing: using the built-in starter\)$/m)
      result.stdout.should match(/^ok    config       valid: 2 sites \(docs, mail\)$/m)
      result.stdout.should match(/^info  apps         install, template and site-app checks are not built yet$/m)

      json = SpecHelper.run(sandbox, ["doctor", "--json"]).json
      json["ok"].should eq(true)
      json["config"]["source"].should eq("starter")
      json["checks"].as_a.map(&.["level"].as_s).should eq(["ok", "ok", "ok", "info"])
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
