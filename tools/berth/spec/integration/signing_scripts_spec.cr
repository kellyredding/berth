require "../spec_helper"

private REPO = File.expand_path("../../../..", __DIR__)

# Runs a script from bin/ with only the signing variables given. PATH holds
# no `op`, so a check that let a run through would fail rather than reach
# 1Password.
private def script(path : String, args : Array(String), signing : Hash(String, String?)) : SpecHelper::Result
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  env = {"PATH" => "/usr/bin:/bin", "BERTH_SIGNING_OP_ACCOUNT" => nil, "BERTH_SIGNING_OP_ITEM" => nil}.merge(signing)
  status = Process.run(File.join(REPO, path), args, env: env, output: stdout, error: stderr)
  SpecHelper::Result.new(stdout.to_s, stderr.to_s, status.exit_code? || 1)
end

describe "the signing scripts" do
  account_guidance = "BERTH_SIGNING_OP_ACCOUNT is not set. Set it in your shell profile to the 1Password account " \
                     "that holds the signing identity, its sign-in address or account ID:\n" \
                     "  export BERTH_SIGNING_OP_ACCOUNT='<account>.1password.com'\n"
  item_guidance = "BERTH_SIGNING_OP_ITEM is not set. Set it in your shell profile to the signing identity's " \
                  "1Password item:\n  export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'\n"
  malformed_guidance = "BERTH_SIGNING_OP_ITEM must be the signing identity's 1Password item, op://VAULT/ITEM, " \
                       "with no field:\n  export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'\n"
  account = {"BERTH_SIGNING_OP_ACCOUNT" => SpecHelper::SIGNING_ACCOUNT} of String => String?
  item = {"BERTH_SIGNING_OP_ITEM" => SpecHelper::SIGNING_ITEM} of String => String?

  # bin/package refuses before it builds anything; past the check, PATH has
  # no op, so it stops there too.
  {
    "sign-app.sh op"          => {"bin/lib/sign-app.sh", ["op", "/nonexistent/Docs.app"]},
    "signing-identity show"   => {"bin/signing-identity", ["show"]},
    "signing-identity create" => {"bin/signing-identity", ["create"]},
    "package"                 => {"bin/package", ["--out", "/nonexistent/dist"]},
  }.each do |name, (path, args)|
    it "#{name} exits 2 naming each variable that is unset or empty" do
      both = script(path, args, {} of String => String?)
      both.exit_code.should eq(2)
      both.stderr.should contain(account_guidance)
      both.stderr.should contain(item_guidance)

      no_account = script(path, args, item.merge({"BERTH_SIGNING_OP_ACCOUNT" => ""}))
      no_account.exit_code.should eq(2)
      no_account.stderr.should contain(account_guidance)
      no_account.stderr.should_not contain("BERTH_SIGNING_OP_ITEM")

      no_item = script(path, args, account)
      no_item.exit_code.should eq(2)
      no_item.stderr.should contain(item_guidance)
      no_item.stderr.should_not contain("BERTH_SIGNING_OP_ACCOUNT")
    end

    it "#{name} exits 2 on an item that is not op://VAULT/ITEM, without quoting it" do
      ["Example Vault/Example Signing", "op://Example Vault", "op://Example Vault/Example Signing/signing/p12",
       "op:// /Example Signing", "op://Example Vault/"].each do |reference|
        result = script(path, args, account.merge({"BERTH_SIGNING_OP_ITEM" => reference}))
        result.exit_code.should eq(2), reference
        result.stderr.should contain(malformed_guidance)
        result.stderr.should_not contain("Example")
      end
    end

    it "#{name} gets past the check when both are set" do
      result = script(path, args, account.merge(item))
      result.exit_code.should_not eq(2)
      result.stderr.should_not contain("BERTH_SIGNING_OP")
    end
  end

  it "package refuses --sign adhoc without --local, and any other signing, before building" do
    adhoc = script("bin/package", ["--sign", "adhoc"], {} of String => String?)
    adhoc.exit_code.should eq(2)
    adhoc.stderr.should eq("bin/package: a release must be signed with the release identity (--sign op); " \
                           "--sign adhoc goes with --local.\n")
    other = script("bin/package", ["--local", "--sign", "keychain"], {} of String => String?)
    other.exit_code.should eq(2)
    other.stderr.should eq("bin/package: --sign takes op or adhoc, not 'keychain'.\n")
  end

  # A missing target stops it before codesign, so nothing is signed.
  it "sign-app.sh adhoc needs neither variable" do
    result = script("bin/lib/sign-app.sh", ["adhoc", "/nonexistent/Docs.app"], {} of String => String?)
    result.exit_code.should eq(1)
    result.stderr.should eq("sign-app.sh: no such file: /nonexistent/Docs.app\n")
  end
end
