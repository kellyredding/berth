require "../spec_helper"

# Every check doctor reported, as {level, name, detail}.
private def checks(result : SpecHelper::Result) : Array(Tuple(String, String, String))
  result.json["checks"].as_a.map { |check| {check["level"].as_s, check["name"].as_s, check["detail"].as_s} }
end

private def named(result : SpecHelper::Result, name : String) : Array(Tuple(String, String))
  checks(result).select { |check| check[1] == name }.map { |check| {check[0], check[2]} }
end

describe "berth doctor's install checks" do
  it "checks the record, the CLI's checksum, the template's commit, signer and registration, and sign-app.sh" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox)
      sandbox.register([{"/Applications/Other.app", "com.example.other"}])
      result = SpecHelper.run(sandbox, ["doctor", "--json"])
      result.exit_code.should eq(0), result.stdout

      named(result, "install").should eq([{"ok", "Berth 0.1.0 (abc123def456), built 2026-01-02T03:04:05Z, " \
                                                 "signed by Berth Release Signing"}])
      named(result, "installed cli").should eq([{"ok", "#{sandbox.root}/bin/berth is the recorded build"}])
      named(result, "template").should eq([{"ok", "#{sandbox.template}: Berth 0.1.0 (abc123def456)"}])
      named(result, "template signer").should eq([{"ok", "Berth Release Signing"}])
      named(result, "template registered").should eq([{"ok", "no: Launch Services does not know the template"}])
      named(result, "sign script").should eq([{"ok", "#{sandbox.root}/libexec/sign-app.sh"}])

      install = result.json["install"]
      install["manifest"]["commit"].should eq("abc123def456")
      install["cli"]["matches"].should eq(true)
      install["template"]["commit"].should eq("abc123def456")
      install["template"]["registered"].should eq(false)
      install["sign_script"]["present"].should eq(true)
    end
  end

  it "says which site apps were built from the installed template, and to rebuild the others" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox)
      SpecHelper.write_site_app(sandbox.applications / "Docs.app", "docs", commit: "abc123def456")
      SpecHelper.write_site_app(sandbox.applications / "Mail.app", "mail", commit: "0ld0ld0ld0ld")
      result = SpecHelper.run(sandbox, ["doctor", "--json"])
      result.exit_code.should eq(0), result.stdout

      named(result, "docs build").should eq([{"ok", "from the installed template (abc123def456)"}])
      named(result, "mail build").should eq([{"warn", "built from the template at 0ld0ld0ld0ld, not the installed one " \
                                                      "(abc123def456); rebuild with `berth sites build --all`"}])
      result.json["sites"][1]["commit"].should eq("0ld0ld0ld0ld")

      SpecHelper.write_site_app(sandbox.applications / "Mail.app", "mail")
      text = SpecHelper.run(sandbox, ["doctor"]).stdout
      text.should contain("built from a template with no build commit, not the installed one (abc123def456); " \
                          "rebuild with `berth sites build --all`")
    end
  end

  it "does not compare site apps with a template when there is no install record" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_site_app(sandbox.applications / "Docs.app", "docs", commit: "0ld0ld0ld0ld")
      result = SpecHelper.run(sandbox, ["doctor", "--json"])
      named(result, "docs build").should be_empty
      named(result, "template").should be_empty
    end
  end

  it "fails on a CLI that is not the recorded build, a template from another commit, and no sign-app.sh" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox, {"commit" => "fedcba987654"})
      File.write((sandbox.root / "bin" / "berth").to_s, "#!/bin/sh\necho changed\n")
      File.delete((sandbox.root / "libexec" / "sign-app.sh").to_s)
      result = SpecHelper.run(sandbox, ["doctor", "--json"])
      result.exit_code.should eq(1)
      result.json["ok"].should eq(false)

      named(result, "installed cli").should eq([{"fail", "#{sandbox.root}/bin/berth is not the build the " \
                                                         "install record names; `berth update` reinstalls it"}])
      named(result, "template").should eq([{"fail", "#{sandbox.template} is from abc123def456, the install record " \
                                                    "from fedcba987654; `berth update` reinstalls both"}])
      named(result, "sign script").should eq([{"fail", "#{sandbox.root}/libexec/sign-app.sh is missing; `berth sites " \
                                                       "build --sign op` needs it, and `berth update` reinstalls it"}])
    end
  end

  it "fails on a template signed ad hoc, by another signer, or not at all" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox, template_signer: "adhoc")
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template signer").should eq(
        [{"fail", "signed ad hoc, so every site app built from it would be too; `berth update` reinstalls it"}])

      SpecHelper.sign(sandbox.template, "Someone Else", "com.kellyredding.berth")
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template signer").should eq(
        [{"fail", "signed by Someone Else, the install record says Berth Release Signing"}])

      File.delete((sandbox.template / "Contents" / ".fake-signature").to_s)
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template signer").should eq(
        [{"fail", "its signature does not verify: #{sandbox.template}: code object is not signed at all"}])
    end
  end

  it "fails on a missing template, a link in its place, or a site app there" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox)
      FileUtils.rm_rf(sandbox.template.to_s)
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template").should eq(
        [{"fail", "#{sandbox.template} is missing; `berth update` installs it"}])

      elsewhere = SpecHelper.write_bundle(sandbox.root / "elsewhere" / "Berth.app", "")
      File.symlink(elsewhere.to_s, sandbox.template.to_s)
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template").should eq(
        [{"fail", "#{sandbox.template} is a link to #{elsewhere}, not an installed copy; `berth update` installs one"}])

      File.delete(sandbox.template.to_s)
      SpecHelper.write_site_app(sandbox.template, "docs", commit: "abc123def456")
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "template").should eq(
        [{"fail", "#{sandbox.template} is not the Berth template (com.kellyredding.berth, naming no site); " \
                  "`berth update` replaces it"}])
    end
  end

  it "warns when Launch Services knows the template, which must never open or be offered links" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.write_install(sandbox)
      staged = "#{sandbox.root}/template/.Berth.app.berth-new"
      sandbox.register([{sandbox.template.to_s, "com.kellyredding.berth"}, {staged, "com.kellyredding.berth"}])
      result = SpecHelper.run(sandbox, ["doctor", "--json"])
      result.exit_code.should eq(0)
      named(result, "template registered").should eq([
        {"warn", "Launch Services knows the template at #{sandbox.template}, which must never open or be offered links; " \
                 "`berth update` unregisters it, as does `lsregister -u #{sandbox.template}`"},
        {"warn", "Launch Services knows the template at #{staged}, which must never open or be offered links; " \
                 "`berth update` unregisters it, as does `lsregister -u #{staged}`"},
      ])
      result.json["install"]["template"]["registered"].should eq(true)
    end
  end

  it "warns on an unreadable install record, and one with no checksum" do
    SpecHelper.sandbox do |sandbox|
      File.write((sandbox.root / "installed-manifest.json").to_s, "not json")
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "install").should eq(
        [{"warn", "unreadable install record at #{sandbox.root}/installed-manifest.json; `berth update` installs " \
                  "a release and writes one"}])

      record = SpecHelper.write_install(sandbox)
      record.delete("berth_sha256")
      File.write((sandbox.root / "installed-manifest.json").to_s, record.to_pretty_json)
      named(SpecHelper.run(sandbox, ["doctor", "--json"]), "installed cli").should eq(
        [{"warn", "the install record has no checksum to compare #{sandbox.root}/bin/berth with"}])
    end
  end
end
