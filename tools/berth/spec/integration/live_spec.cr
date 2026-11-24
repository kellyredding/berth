require "../spec_helper"

private def ok(data : String) : String
  %({"ok": true, "data": #{data}})
end

private def status_reply(title : String? = "Example Domain", badge : String? = nil,
                         config : String = %("loaded": true, "state": "loaded", "error": null)) : String
  ok(%({"version": "0.1.0", "pid": 99, "site": "docs", "url": "https://docs.example.com/", ) +
     %("title": #{title.to_json}, "badge": #{badge.to_json}, "config": {#{config}}}))
end

# A stand-in for /usr/bin/open that records its arguments beside itself.
private def fake_open(sandbox : SpecHelper::Sandbox, exit_code : Int32 = 0) : Hash(String, String?)
  script = SpecHelper.write_executable(sandbox.root / "bin" / "open", <<-SH)
    #!/bin/sh
    printf '%s\\n' "$@" > "#{sandbox.root}/open.args"
    [ #{exit_code} -eq 0 ] || echo "open could not launch it" >&2
    exit #{exit_code}
    SH
  {"BERTH_OPEN" => script.to_s} of String => String?
end

private def open_args(sandbox : SpecHelper::Sandbox) : Array(String)?
  path = sandbox.root / "open.args"
  File.exists?(path.to_s) ? File.read(path.to_s).lines : nil
end

private def build_app(sandbox : SpecHelper::Sandbox, name : String) : Path
  app = sandbox.applications / "#{name}.app"
  Dir.mkdir_p(app.to_s)
  app
end

describe "berth status" do
  it "lists every site as not running when no app answers, without failing" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run_live(sandbox, ["status"])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq(<<-TEXT)
        SITE  NAME  APP        RUNNING  BADGE  SHOWING
        docs  Docs  not built  no
        mail  Mail  not built  no

        TEXT

      json = SpecHelper.run_live(sandbox, ["status", "--json"]).json["sites"].as_a
      json.map(&.["site"].as_s).should eq(["docs", "mail"])
      json[0]["running"].should eq(false)
      json[0]["state"].should eq("not_running")
      json[0]["status"].raw.should be_nil
      json[0]["app"].should eq((sandbox.applications / "Docs.app").to_s)
    end
  end

  it "shows a running app's title and badge, and sends a bare status envelope" do
    SpecHelper.sandbox do |sandbox|
      build_app(sandbox, "Docs")
      SpecHelper.with_app(sandbox, "docs", {"status" => status_reply("Inbox (3) - Docs", "3")}) do |app|
        result = SpecHelper.run_live(sandbox, ["status"])
        result.exit_code.should eq(0), result.stderr
        result.stdout.should contain("docs  Docs  built      yes      3      Inbox (3) - Docs\n")
        result.stdout.should contain("mail  Mail  not built  no\n")

        request = app.requests.first
        request["v"].should eq(1)
        request["event"].should eq("status")
        request["ts"].as_i64.should be_close(Time.utc.to_unix, 60)
        request.as_h.has_key?("detail_data").should be_false

        json = SpecHelper.run_live(sandbox, ["status", "--json"]).json["sites"][0]
        json["built"].should eq(true)
        json["running"].should eq(true)
        json["status"]["badge"].should eq("3")
        json["status"]["title"].should eq("Inbox (3) - Docs")
      end
    end
  end

  it "says when a running app is still loading its config, or could not" do
    SpecHelper.sandbox do |sandbox|
      {
        %("loaded": false, "state": "loading", "error": null)                     => "loading its config…",
        %("loaded": false, "state": "failed", "error": "berth: invalid\\n  more") => "its config did not load: berth: invalid",
      }.each do |config, shown|
        SpecHelper.with_app(sandbox, "docs", {"status" => status_reply(nil, nil, config)}) do
          SpecHelper.run_live(sandbox, ["status"]).stdout.should contain("docs  Docs  not built  yes             #{shown}\n")
        end
      end
    end
  end

  it "tells no reply apart from not running" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "docs", {} of String => String) do
        result = SpecHelper.run_live(sandbox, ["status"])
        result.exit_code.should eq(0)
        result.stdout.should contain("docs  Docs  not built  no reply")
        json = SpecHelper.run_live(sandbox, ["status", "--json"]).json["sites"][0]
        json["state"].should eq("no_reply")
        json["running"].should eq(false)
        json["error"].as_s.should contain("no reply at runtime/docs.sock")
      end
    end
  end
end

describe "berth open" do
  it "loads a URL in a running app" do
    SpecHelper.sandbox do |sandbox|
      reply = ok(%({"url": "https://docs.example.com/page", "opened_in": "app"}))
      SpecHelper.with_app(sandbox, "docs", {"open" => reply}) do |app|
        result = SpecHelper.run_live(sandbox, ["open", "docs", "https://docs.example.com/page"], fake_open(sandbox))
        result.exit_code.should eq(0), result.stderr
        result.stdout.should eq("opened https://docs.example.com/page in Docs\n")
        app.request["detail_data"].should eq(JSON.parse(%({"url": "https://docs.example.com/page"})))
        open_args(sandbox).should be_nil
      end
    end
  end

  it "says when the app sent an out-of-scope URL to the browser" do
    SpecHelper.sandbox do |sandbox|
      reply = ok(%({"url": "https://news.example.org/", "opened_in": "browser"}))
      SpecHelper.with_app(sandbox, "docs", {"open" => reply}) do
        result = SpecHelper.run_live(sandbox, ["open", "docs", "https://news.example.org/"])
        result.stdout.should eq("https://news.example.org/ is outside Docs's keep hosts; opened it in the default browser\n")
        json = SpecHelper.run_live(sandbox, ["open", "docs", "https://news.example.org/", "--json"]).json
        json["launched"].should eq(false)
        json["opened_in"].should eq("browser")
      end
    end
  end

  it "brings a running app forward when no URL is given" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "docs", {"open" => ok(%({"url": null, "opened_in": "app"}))}) do |app|
        result = SpecHelper.run_live(sandbox, ["open", "docs"])
        result.exit_code.should eq(0)
        result.stdout.should eq("brought Docs forward\n")
        app.request.as_h.has_key?("detail_data").should be_false
      end
    end
  end

  it "launches a built app that is not running, with the URL" do
    SpecHelper.sandbox do |sandbox|
      app = build_app(sandbox, "Docs")
      result = SpecHelper.run_live(sandbox, ["open", "docs", "https://docs.example.com/x"], fake_open(sandbox))
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq("launched Docs with https://docs.example.com/x\n")
      open_args(sandbox).should eq(["-a", app.to_s, "https://docs.example.com/x"])

      json = SpecHelper.run_live(sandbox, ["open", "docs", "--json"], fake_open(sandbox)).json
      json["launched"].should eq(true)
      open_args(sandbox).should eq(["-a", app.to_s])
    end
  end

  it "reports a launch that fails" do
    SpecHelper.sandbox do |sandbox|
      build_app(sandbox, "Docs")
      result = SpecHelper.run_live(sandbox, ["open", "docs"], fake_open(sandbox, exit_code: 1))
      result.exit_code.should eq(1)
      result.stderr.should contain("could not launch #{sandbox.applications}/Docs.app: open could not launch it")
    end
  end

  it "says to build an app that is not built" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run_live(sandbox, ["open", "docs", "--json"], fake_open(sandbox))
      result.exit_code.should eq(5)
      result.stderr.should contain("Docs's app is not built (no #{sandbox.applications}/Docs.app); run `berth sites build docs`")
      result.json["code"].should eq("not_found")
      open_args(sandbox).should be_nil
    end
  end

  it "does not launch a second copy of an app that took the request without replying" do
    SpecHelper.sandbox do |sandbox|
      build_app(sandbox, "Docs")
      SpecHelper.with_app(sandbox, "docs", {} of String => String) do
        result = SpecHelper.run_live(sandbox, ["open", "docs", "--json"], fake_open(sandbox))
        result.exit_code.should eq(3)
        result.json["code"].should eq("not_running")
        result.stderr.should contain("docs's app is not running (no reply at runtime/docs.sock)")
        open_args(sandbox).should be_nil
      end
    end
  end

  it "maps a refusal to its exit code" do
    SpecHelper.sandbox do |sandbox|
      refusal = %({"ok": false, "error": "no config is loaded", "code": "unavailable"})
      SpecHelper.with_app(sandbox, "docs", {"open" => refusal}) do
        result = SpecHelper.run_live(sandbox, ["open", "docs", "https://docs.example.com/", "--json"])
        result.exit_code.should eq(1)
        result.stderr.should contain("no config is loaded")
        result.json["code"].should eq("unavailable")
      end
    end
  end

  it "refuses a URL that is not a web page, and an unknown site, without contacting the app" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "docs", {"open" => ok("{}")}) do |app|
        SpecHelper.run_live(sandbox, ["open", "docs", "mailto:someone@example.com"]).exit_code.should eq(2)
        SpecHelper.run_live(sandbox, ["open", "docs", "docs.example.com"]).exit_code.should eq(2)
        SpecHelper.run_live(sandbox, ["open"]).exit_code.should eq(2)
        SpecHelper.run_live(sandbox, ["open", "docs", "https://docs.example.com/", "extra"]).exit_code.should eq(2)
        SpecHelper.run_live(sandbox, ["open", "calendar"]).exit_code.should eq(5)
        app.requests.should be_empty
      end
    end
  end
end

describe "config writes" do
  it "ask every site's running app to reload, and say nothing of the others" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "docs", {"reload" => ok(%({"loaded": true, "error": null}))}) do |app|
        result = SpecHelper.run_live(sandbox, ["sites", "set", "docs", "--notifications", "on"])
        result.exit_code.should eq(0), result.stderr
        result.stdout.should eq("updated site docs\n  docs's app reloaded the config\n")
        app.request["event"].should eq("reload")
        app.request.as_h.has_key?("detail_data").should be_false

        json = SpecHelper.run_live(sandbox, ["sites", "set", "docs", "--notifications", "off", "--json"]).json
        json["reload"].should eq(JSON.parse(%({"docs": {"sent": true, "loaded": true, "error": null}, ) +
                                            %("mail": {"sent": false, "loaded": null, "error": null}})))
      end
    end
  end

  it "report an app that could not load the result, or did not confirm" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "docs", {"reload" => ok(%({"loaded": false, "error": "berth timed out"}))}) do
        result = SpecHelper.run_live(sandbox, ["sites", "set", "docs", "--notifications", "on"])
        result.exit_code.should eq(0)
        result.stdout.should contain("docs's app could not reload the config: berth timed out")
      end
      SpecHelper.with_app(sandbox, "mail", {} of String => String) do
        result = SpecHelper.run_live(sandbox, ["sites", "set", "mail", "--notifications", "off"])
        result.exit_code.should eq(0)
        result.stdout.should contain("mail's app didn't confirm the reload (no reply at runtime/mail.sock)")
      end
    end
  end

  it "tell a removed site's app too, and init tells the apps it affects" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.with_app(sandbox, "mail", {"reload" => ok(%({"loaded": false, "error": "no site named mail"}))}) do |app|
        SpecHelper.run_live(sandbox, ["sites", "remove", "mail"]).exit_code.should eq(0)
        app.request["event"].should eq("reload")

        init = SpecHelper.run_live(sandbox, ["config", "init", "--force", "--json"])
        init.exit_code.should eq(0), init.stderr
        init.json["reload"].as_h.keys.should eq(["docs"])
      end
    end
  end
end
