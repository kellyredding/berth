require "../spec_helper"

describe Berth::Config::Export do
  it "exports fixtures/config.json as fixtures/export.json" do
    model = Berth::Config::Store.model(SpecHelper::FIXTURES / "config.json")
    exported = JSON.parse(Berth::Config::Export.to_json(model))
    expected = JSON.parse(File.read((SpecHelper::FIXTURES / "export.json").to_s))

    SpecHelper.comparable_export(exported).should eq(SpecHelper.comparable_export(expected))
  end

  it "exports only the site asked for, and refuses an unknown one as not found" do
    model = Berth::Config::Store.model(SpecHelper::FIXTURES / "config.json")
    exported = JSON.parse(Berth::Config::Export.to_json(model, "docs"))
    exported["sites"].as_h.keys.should eq(["docs"])
    exported["source"].should eq("file")

    error = expect_raises(Berth::NotFound) { Berth::Config::Export.to_json(model, "calendar") }
    error.message.should eq(%(no site named "calendar"; the sites are mail, docs))
    error.exit_code.should eq(5)
  end

  it "reports the configured path, not the symlink's target, and the icon from the real directory" do
    SpecHelper.sandbox do |sandbox|
      icon = sandbox.write_png("dotfiles/icons/docs.png")
      File.write((sandbox.root / "dotfiles" / "berth.json").to_s,
        %({"sites": {"docs": {"name": "Docs", "url": "https://docs.example.com/", "icon": "icons/docs.png"}}}))
      File.symlink("dotfiles/berth.json", sandbox.config.to_s)

      exported = JSON.parse(Berth::Config::Export.to_json(Berth::Config::Store.model(sandbox.config)))
      exported["path"].should eq(sandbox.config.to_s)
      exported["sites"]["docs"]["icon"].should eq(icon.to_s)
    end
  end

  it "carries warnings" do
    model = SpecHelper.validate(%({"sites": {"mail": {"name": "Mail", "url": "https://mail.example.com/",
      "mailto": "https://mail.example.com/?to=%s"}}})).model!
    JSON.parse(Berth::Config::Export.to_json(model))["warnings"]
      .should eq(JSON.parse(%(["sites.mail.mailto: unused; add mailto to handles or remove it"])))
  end
end

describe "the starter config" do
  it "validates without warnings and exports as the starter source" do
    SpecHelper.sandbox do |sandbox|
      loaded = Berth::Config::Store.load(sandbox.config)
      loaded.source.should eq(Berth::Config::Source::Starter)

      result = loaded.validate
      result.errors.should be_empty
      result.warnings.should be_empty

      exported = JSON.parse(Berth::Config::Export.to_json(result.model!))
      exported["source"].should eq("starter")
      exported["sites"].as_h.keys.should eq(["docs", "mail"])
      exported["sites"]["mail"]["handles"].should eq(JSON.parse(%(["mailto"])))
    end
  end

  it "uses only example.com sites" do
    model = Berth::Config::Store.model(Path.new("/nonexistent/berth/config.json"))
    model.sites.each do |site|
      (site.keep + [URI.parse(site.url).host.not_nil!]).each do |host|
        host.should match(/(\A|\.)example\.com\z/)
      end
    end
  end
end

describe Berth::Paths do
  it "defaults under ~/.berth and ~/Applications" do
    with_env({"BERTH_ROOT" => nil, "BERTH_CONFIG" => nil, "BERTH_RUNTIME_DIR" => nil,
              "BERTH_BINARY" => nil, "BERTH_APPLICATIONS_DIR" => nil}) do
      root = Path.home / ".berth"
      Berth::Paths.root.should eq(root)
      Berth::Paths.config_file.should eq(root / "config.json")
      Berth::Paths.socket("mail").should eq(root / "runtime" / "mail.sock")
      Berth::Paths.log("mail").should eq(root / "runtime" / "logs" / "mail.log")
      Berth::Paths.binary.should eq(root / "bin" / "berth")
      Berth::Paths.template_app.should eq(root / "template" / "Berth.app")
      Berth::Paths.installed_manifest.should eq(root / "installed-manifest.json")
      Berth::Paths.site_app("Mail").should eq(Path.home / "Applications" / "Mail.app")
    end
  end

  it "takes every override" do
    with_env({"BERTH_ROOT" => "/r", "BERTH_CONFIG" => "/c/config.json", "BERTH_RUNTIME_DIR" => "/run",
              "BERTH_BINARY" => "/b/berth", "BERTH_APPLICATIONS_DIR" => "/apps"}) do
      Berth::Paths.config_file.should eq(Path.new("/c/config.json"))
      Berth::Paths.socket("mail").should eq(Path.new("/run/mail.sock"))
      Berth::Paths.binary.should eq(Path.new("/b/berth"))
      Berth::Paths.template_app.should eq(Path.new("/r/template/Berth.app"))
      Berth::Paths.site_app("Mail").should eq(Path.new("/apps/Mail.app"))
    end
  end
end

private def with_env(values : Hash(String, String?), &)
  saved = values.keys.to_h { |name| {name, ENV[name]?} }
  values.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  begin
    yield
  ensure
    saved.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
  end
end
