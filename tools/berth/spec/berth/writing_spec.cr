require "../spec_helper"

describe Berth::Config::Emitter do
  it "writes the starter and the fixture back exactly as they are" do
    [Berth::STARTER_CONFIG, File.read((SpecHelper::FIXTURES / "config.json").to_s)].each do |text|
      Berth::Config::Emitter.emit(Berth::Config::Reader.parse(text).as_h).should eq(text)
    end
  end

  it "puts version first, keeps every other key's order, and writes each flat step on one line" do
    tree = Berth::Config::Reader.parse(<<-JSON)
      {
        "sites": {
          "zed": {"url": "https://zed.example.com/", "name": "Zed", "keep": [], "badge": {"title": "(x)"}},
          "alpha": {"signin": {"me": [{"flow": "okta", "item": "op://V/I"}, {"nested": {"a": 1}}]}}
        },
        "version": 1
      }
      JSON

    Berth::Config::Emitter.emit(tree.as_h).should eq(<<-JSON)
      {
        "version": 1,
        "sites": {
          "zed": {
            "url": "https://zed.example.com/",
            "name": "Zed",
            "keep": [],
            "badge": {
              "title": "(x)"
            }
          },
          "alpha": {
            "signin": {
              "me": [
                {"flow": "okta", "item": "op://V/I"},
                {
                  "nested": {
                    "a": 1
                  }
                }
              ]
            }
          }
        }
      }

      JSON
  end

  it "escapes strings and keeps every value's type" do
    tree = JSON.parse(%({"sites": {"\\"q\\"": "a\\\\b", "1": "true", "n": null, "f": false, "list": [1, "x", null], "steps": [{"a": "\\u0007"}]}}))
    emitted = Berth::Config::Emitter.emit(tree.as_h)
    Berth::Config::Reader.parse(emitted).should eq(tree)
  end
end

describe Berth::Config::Mutation do
  it "puts a new key in canonical position and an existing one in place" do
    hash = {"name" => JSON::Any.new("A"), "icon" => JSON::Any.new("i.png"), "extra" => JSON::Any.new(1)}
    Berth::Config::Mutation.put(hash, "keep", JSON::Any.new("k"), Berth::Config::SITE_KEYS)
    Berth::Config::Mutation.put(hash, "url", JSON::Any.new("u"), Berth::Config::SITE_KEYS)
    Berth::Config::Mutation.put(hash, "signin", JSON::Any.new("s"), Berth::Config::SITE_KEYS)
    Berth::Config::Mutation.put(hash, "name", JSON::Any.new("B"), Berth::Config::SITE_KEYS)
    hash.keys.should eq(["name", "url", "keep", "icon", "signin", "extra"])
    hash["name"].should eq("B")
  end
end

describe Berth::Config::Writer do
  it "replaces the file a symlink points to and leaves the link in place" do
    SpecHelper.sandbox do |sandbox|
      Dir.mkdir_p((sandbox.root / "dotfiles").to_s)
      real = sandbox.root / "dotfiles" / "berth.json"
      File.write(real.to_s, "old\n")
      File.symlink("dotfiles/berth.json", sandbox.config.to_s)

      written = Berth::Config::Writer.write(sandbox.config, "new\n")

      written.should eq(real)
      File.symlink?(sandbox.config.to_s).should be_true
      File.read(real.to_s).should eq("new\n")
      Dir.children((sandbox.root / "dotfiles").to_s).should eq(["berth.json"])
    end
  end

  it "follows a chain of links" do
    SpecHelper.sandbox do |sandbox|
      real = sandbox.root / "real.json"
      File.write(real.to_s, "old\n")
      File.symlink(real.to_s, (sandbox.root / "middle.json").to_s)
      File.symlink((sandbox.root / "middle.json").to_s, sandbox.config.to_s)

      Berth::Config::Writer.write(sandbox.config, "new\n").should eq(real)
      File.symlink?((sandbox.root / "middle.json").to_s).should be_true
    end
  end

  it "resolves a relative link's .. from the link's real directory" do
    SpecHelper.sandbox do |sandbox|
      Dir.mkdir_p((sandbox.root / "dotfiles" / "berth").to_s)
      Dir.mkdir_p((sandbox.root / "dotfiles" / "shared").to_s)
      real = sandbox.root / "dotfiles" / "shared" / "config.json"
      File.write(real.to_s, "old\n")
      File.symlink("dotfiles/berth", (sandbox.root / "home").to_s)
      File.symlink("../shared/config.json", (sandbox.root / "home" / "config.json").to_s)

      Berth::Config::Writer.write(sandbox.root / "home" / "config.json", "new\n").should eq(real)
      File.read(real.to_s).should eq("new\n")
      Dir.exists?((sandbox.root / "shared").to_s).should be_false
    end
  end

  it "reports a symlink loop and a dangling link into a directory it cannot create" do
    SpecHelper.sandbox do |sandbox|
      File.write((sandbox.root / "blocker").to_s, "")
      File.symlink("blocker/sub/config.json", sandbox.config.to_s)
      expect_raises(Berth::Error, /could not write/) do
        Berth::Config::Writer.write(sandbox.config, "new\n")
      end

      File.symlink("b.json", (sandbox.root / "a.json").to_s)
      File.symlink("a.json", (sandbox.root / "b.json").to_s)
      expect_raises(Berth::Error, /symlink loop/) do
        Berth::Config::Writer.write(sandbox.root / "a.json", "new\n")
      end
    end
  end

  it "creates parent directories for a first file and keeps an existing file's mode" do
    SpecHelper.sandbox do |sandbox|
      path = sandbox.root / "a" / "b" / "config.json"
      Berth::Config::Writer.write(path, "one\n")
      File.read(path.to_s).should eq("one\n")

      File.chmod(path.to_s, 0o600)
      Berth::Config::Writer.write(path, "two\n")
      File.info(path.to_s).permissions.value.should eq(0o600)
    end
  end
end
