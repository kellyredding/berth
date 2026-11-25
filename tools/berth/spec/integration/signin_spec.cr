require "../spec_helper"

# What the fake op hands out. The password carries a quote and a backslash,
# so the request proves they were escaped, not dropped.
private EMAIL    = "someone@example.com"
private PASSWORD = %(Pw"7f\\3a-SECRET-9c)
private CODE     = "482913"
private SECRETS  = [EMAIL, PASSWORD, "SECRET-9c", CODE]

private CONFIG = <<-JSON
  {
    "sites": {
      "mail": {
        "name": "Mail",
        "url": "https://mail.example.com/",
        "signin": {
          "personal": [{"flow": "google", "item": "op://Personal/Example Mail"}],
          "work": [
            {"flow": "google", "email_from": "op://Work/Example SSO", "account": "example.1password.com"},
            {"flow": "okta", "item": "op://Work/Example SSO", "account": "example.1password.com", "method": "Example Authenticator"}
          ]
        }
      },
      "docs": {"name": "Docs", "url": "https://docs.example.com/"}
    }
  }
  JSON

private ONE_LOGIN = <<-JSON
  {"sites": {"mail": {"name": "Mail", "url": "https://mail.example.com/",
    "signin": {"personal": [{"flow": "google", "item": "op://Personal/Example Mail"}]}}}}
  JSON

private STATUS = %({"ok": true, "data": {"version": "0.1.0", "pid": 7, "site": "mail"}})

private def filled(completed : Array(String), stopped_at : String = "null", already : Bool = false) : String
  %({"ok": true, "data": {"completed": #{completed.to_json}, "stopped_at": #{stopped_at}, ) +
    %("url": "https://mail.example.com/mail/", "already_signed_in": #{already}}})
end

# A stand-in for op that records its arguments and answers `op read` and
# `op item get --otp` with the values above. FAKE_OP_FAIL makes every call
# fail with that message; FAKE_OP_TIMEOUTS=N makes the first N time out;
# FAKE_OP_NO_OTP makes --otp fail as for an item without a code.
private def fake_op(sandbox : SpecHelper::Sandbox, extra : Hash(String, String?) = {} of String => String?) : Hash(String, String?)
  dir = sandbox.fakes
  script = SpecHelper.write_executable(dir / "op", <<-SH)
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{dir}/op.calls"
    if [ -n "$FAKE_OP_TIMEOUTS" ]; then
      fx_count="$(cat "#{dir}/op.timeouts" 2>/dev/null || echo 0)"
      if [ "$fx_count" -lt "$FAKE_OP_TIMEOUTS" ]; then
        echo $((fx_count + 1)) > "#{dir}/op.timeouts"
        echo "[ERROR] 2026/11/25 08:00:00 authorization timeout" >&2
        exit 1
      fi
    fi
    if [ -n "$FAKE_OP_FAIL" ]; then echo "[ERROR] 2026/11/25 08:00:00 $FAKE_OP_FAIL" >&2; exit 1; fi
    case " $* " in
      *" --otp "*)
        if [ -n "$FAKE_OP_NO_OTP" ]; then echo "[ERROR] 2026/11/25 08:00:00 no one-time password field" >&2; exit 1; fi
        echo "#{CODE}"
        exit 0 ;;
    esac
    for fx_last; do :; done
    case "$fx_last" in
      */password) printf '%s' '#{PASSWORD}' ;;
      *) echo "#{EMAIL}" ;;
    esac
    SH
  {"BERTH_OP" => script.to_s, "FAKE_OP_FAIL" => nil, "FAKE_OP_TIMEOUTS" => nil, "FAKE_OP_NO_OTP" => nil}.merge(extra)
end

private def op_calls(sandbox : SpecHelper::Sandbox) : Array(String)
  sandbox.calls("op")
end

# No secret in what the CLI printed, in --json, or in any argv it passed.
private def no_secrets(sandbox : SpecHelper::Sandbox, *results : SpecHelper::Result) : Nil
  texts = results.flat_map { |result| [result.stdout, result.stderr] } + op_calls(sandbox)
  SECRETS.each do |secret|
    texts.each { |text| text.should_not contain(secret) }
  end
end

private def signin_request(app : SpecHelper::FakeApp) : JSON::Any
  request = app.requests.find { |item| item["event"] == "signin.fill" }
  request.should_not be_nil
  request.not_nil!["detail_data"]
end

describe "berth signin" do
  it "reads the only login from 1Password and sends it to the running app, printing no secret" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(ONE_LOGIN)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"])}) do |app|
        result = SpecHelper.run_live(sandbox, ["signin", "mail"], fake_op(sandbox))
        result.exit_code.should eq(0), result.stderr
        result.stdout.should eq("signed in to Mail with personal: google\n  now at https://mail.example.com/mail/\n")
        result.stderr.should contain("filling Mail's sign-in (personal: google)")

        op_calls(sandbox).should eq([
          "read --no-newline op://Personal/Example Mail/username",
          "read --no-newline op://Personal/Example Mail/password",
          "item get Example Mail --vault Personal --otp",
        ])
        app.requests.map(&.["event"].as_s).should eq(["status", "signin.fill"])
        detail = signin_request(app)
        detail.should eq(JSON.parse({"login" => "personal", "steps" => [
          {"flow" => "google", "username" => EMAIL, "password" => PASSWORD, "code" => CODE},
        ]}.to_json))
        no_secrets(sandbox, result)
      end
    end
  end

  it "needs --account when the site has several logins, and refuses an unknown one" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS}) do |app|
        several = SpecHelper.run_live(sandbox, ["signin", "mail", "--json"], fake_op(sandbox))
        several.exit_code.should eq(2)
        several.stderr.should contain("mail has 2 logins; pick one with --account: personal, work")
        several.json["code"].should eq("usage")

        unknown = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "school", "--json"], fake_op(sandbox))
        unknown.exit_code.should eq(5)
        unknown.stderr.should contain(%(mail has no login named "school"; its logins are personal, work))
        unknown.json["code"].should eq("not_found")

        none = SpecHelper.run_live(sandbox, ["signin", "docs"], fake_op(sandbox))
        none.exit_code.should eq(5)
        none.stderr.should contain("docs has no sign-in logins; add one with `berth sites set docs --login NAME --steps JSON`")

        SpecHelper.run_live(sandbox, ["signin", "calendar"], fake_op(sandbox)).exit_code.should eq(5)
        SpecHelper.run_live(sandbox, ["signin"], fake_op(sandbox)).exit_code.should eq(2)
        SpecHelper.run_live(sandbox, ["signin", "mail", "--user", "x"], fake_op(sandbox)).exit_code.should eq(2)
        op_calls(sandbox).should be_empty
        app.requests.should be_empty
      end
    end
  end

  it "picks a login with --account, reading each step from its 1Password account and sending its method" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google", "okta"])}) do |app|
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work"], fake_op(sandbox))
        result.exit_code.should eq(0), result.stderr
        result.stdout.should start_with("signed in to Mail with work: google, then okta\n")

        op_calls(sandbox).should eq([
          "--account example.1password.com read --no-newline op://Work/Example SSO/username",
          "--account example.1password.com read --no-newline op://Work/Example SSO/username",
          "--account example.1password.com read --no-newline op://Work/Example SSO/password",
          "--account example.1password.com item get Example SSO --vault Work --otp",
        ])
        signin_request(app).should eq(JSON.parse({"login" => "work", "steps" => [
          {"flow" => "google", "username" => EMAIL},
          {"flow" => "okta", "username" => EMAIL, "password" => PASSWORD, "code" => CODE, "method" => "Example Authenticator"},
        ]}.to_json))
        no_secrets(sandbox, result)
      end
    end
  end

  it "sends a step's method as given, and none for a step that names none" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG.sub(%("method": "Example Authenticator"), %("method": "Enter a \\"code\\" — Example")))
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google", "okta"])}) do |app|
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work"], fake_op(sandbox))
        result.exit_code.should eq(0), result.stderr
        steps = signin_request(app)["steps"]
        steps[0].as_h.has_key?("method").should be_false
        steps[1]["method"].should eq(%(Enter a "code" — Example))
      end
    end
  end

  it "reads an email_from field as given, and sends no code for an item without one" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG.sub(%("email_from": "op://Work/Example SSO"), %("email_from": "op://Work/Example SSO/email")))
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google", "okta"])}) do |app|
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work", "--json"],
          fake_op(sandbox, {"FAKE_OP_NO_OTP" => "1"}))
        result.exit_code.should eq(0), result.stderr
        op_calls(sandbox).first.should eq("--account example.1password.com read --no-newline op://Work/Example SSO/email")
        signin_request(app)["steps"][1].as_h.keys.should eq(["flow", "username", "password", "method"])
        result.json["steps"].should eq(JSON.parse(%([{"flow": "google", "password": false, "code": false},
                                                     {"flow": "okta", "password": true, "code": false}])))
        no_secrets(sandbox, result)
      end
    end
  end

  it "prints only the outcome with --json, never a value" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"])}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal", "--json"], fake_op(sandbox))
        result.exit_code.should eq(0), result.stderr
        result.json.should eq(JSON.parse(<<-JSON))
          {"ok": true, "site": "mail", "login": "personal",
           "steps": [{"flow": "google", "password": true, "code": true}],
           "completed": ["google"], "stopped_at": null, "url": "https://mail.example.com/mail/",
           "already_signed_in": false}
          JSON
        no_secrets(sandbox, result)
      end
    end
  end

  it "says where the app stopped and why, and exits 1" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      stop = %({"step": 1, "flow": "okta", "reason": "waiting for you: approve the Okta sign-in"})
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"], stop)}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work"], fake_op(sandbox))
        result.exit_code.should eq(1)
        result.stdout.should be_empty
        result.stderr.should contain("berth: Mail's sign-in stopped at step 2, okta: waiting for you: approve the Okta sign-in\n" \
                                     "  completed: google\n  finish it in the app\n")

        json = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work", "--json"], fake_op(sandbox))
        json.exit_code.should eq(1)
        json.json["ok"].should eq(false)
        json.json["code"].should eq("stopped")
        json.json["stopped_at"].should eq(JSON.parse(stop))
        json.json["completed"].should eq(JSON.parse(%(["google"])))
        no_secrets(sandbox, result, json)
      end
    end
  end

  it "says when there was nothing to do, or a later step was not needed" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled([] of String, already: true)}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"], fake_op(sandbox))
        result.exit_code.should eq(0)
        result.stdout.should start_with("Mail is signed in already; nothing to do\n")
      end
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"])}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work"], fake_op(sandbox))
        result.stdout.should start_with("signed in to Mail with work: google (okta not needed)\n")
      end
    end
  end

  it "refuses when the site's app is not running, before reading 1Password" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "work", "--json"], fake_op(sandbox))
      result.exit_code.should eq(3)
      result.stderr.should contain("mail's app is not running; run `berth open mail` first")
      result.json["code"].should eq("not_running")
      op_calls(sandbox).should be_empty
    end
  end

  it "exits 4 when 1Password declines or op is not there, and sends nothing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"])}) do |app|
        declined = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal", "--json"],
          fake_op(sandbox, {"FAKE_OP_FAIL" => "authorization prompt dismissed, please try again"}))
        declined.exit_code.should eq(4)
        declined.stderr.should contain("1Password declined to give the username of op://Personal/Example Mail, for step 1 (google) " \
                                       "(op: authorization prompt dismissed, please try again)")
        declined.json["code"].should eq("not_permitted")
        op_calls(sandbox).size.should eq(1)

        missing = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"],
          {"BERTH_OP" => (sandbox.root / "no-such-op").to_s})
        missing.exit_code.should eq(4)
        missing.stderr.should contain("1Password's CLI is not available")

        app.requests.map(&.["event"].as_s).should eq(["status", "status"])
      end
    end
  end

  it "fails on an item 1Password does not have, and other refusals are not permitted" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS}) do
        gone = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"],
          fake_op(sandbox, {"FAKE_OP_FAIL" => %("Example Mail" isn't an item in the "Personal" vault.)}))
        gone.exit_code.should eq(1)
        gone.stderr.should contain(%(1Password could not find the username of op://Personal/Example Mail, for step 1 (google)))

        locked = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"],
          fake_op(sandbox, {"FAKE_OP_FAIL" => "account is not signed in"}))
        locked.exit_code.should eq(4)
        locked.stderr.should contain("(op: account is not signed in)")
      end
    end
  end

  it "retries while 1Password's approval is still pending" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => filled(["google"])}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"],
          fake_op(sandbox, {"FAKE_OP_TIMEOUTS" => "1"}))
        result.exit_code.should eq(0), result.stderr
        result.stderr.should contain("waiting for 1Password: approve its prompt (op: authorization timeout)")
        op_calls(sandbox).size.should eq(4)
        no_secrets(sandbox, result)
      end
    end
  end

  it "reports a refusal from the app, and an app that never replies" do
    SpecHelper.sandbox do |sandbox|
      sandbox.write_config(CONFIG)
      busy = %({"ok": false, "error": "a sign-in is already being filled in this app", "code": "unavailable"})
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS, "signin.fill" => busy}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal"], fake_op(sandbox))
        result.exit_code.should eq(1)
        result.stderr.should contain("a sign-in is already being filled in this app")
        no_secrets(sandbox, result)
      end
      SpecHelper.with_app(sandbox, "mail", {"status" => STATUS}) do
        result = SpecHelper.run_live(sandbox, ["signin", "mail", "--account", "personal", "--json"], fake_op(sandbox))
        result.exit_code.should eq(3)
        result.stderr.should contain("mail's app did not reply within 130 s (no reply at runtime/mail.sock); " \
                                     "it may still be filling the sign-in")
        result.json["code"].should eq("not_running")
        no_secrets(sandbox, result)
      end
    end
  end
end

describe Berth::Secret do
  it "never prints its value, and wipes its bytes" do
    secret = Berth::Secret.new("hunter2".to_slice.dup)
    "#{secret}".should eq("[secret]")
    secret.inspect.should eq("[secret]")
    Berth::Commands::Signin::Values.new("okta", secret, nil, nil).inspect.should_not contain("hunter2")
    secret.wipe
    secret.bytes.all?(&.zero?).should be_true
  end
end
