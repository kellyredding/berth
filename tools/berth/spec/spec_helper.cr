require "spec"
require "file_utils"

# Reach the library without running the program. Integration examples run
# the built binary instead: exit codes and streams are only observable from
# outside the process.
ENV["BERTH_SKIP_CLI"] = "1"

# In-process code that falls back on the default paths lands here, never in
# ~/.berth or ~/Applications.
SPEC_ROOT = File.tempname("berth-spec-root")
ENV["BERTH_ROOT"] = SPEC_ROOT
ENV["BERTH_APPLICATIONS_DIR"] = File.join(SPEC_ROOT, "Applications")
["BERTH_CONFIG", "BERTH_RUNTIME_DIR", "BERTH_BINARY"].each { |name| ENV.delete(name) }
at_exit { FileUtils.rm_rf(SPEC_ROOT) }

require "../src/berth"

module SpecHelper
  extend self

  BINARY   = File.expand_path("../build/berth", __DIR__)
  FIXTURES = Path.new(File.realpath(File.expand_path("../../../fixtures", __DIR__)))
  PNG      = File.read((FIXTURES / "icons" / "mail.png").to_s)

  SIGNING_ACCOUNT = "example.1password.com"
  SIGNING_ITEM    = "op://Example Vault/Example Signing"

  record Result, stdout : String, stderr : String, exit_code : Int32 do
    def json : JSON::Any
      JSON.parse(stdout)
    end
  end

  # One example's world: a private BERTH_ROOT and applications directory, and
  # stand-ins for the signing script, codesign, sips, iconutil and lsregister
  # that record their calls under `fakes/`, so nothing is signed for real and
  # the real Launch Services database is never read or changed.
  class Sandbox
    getter root : Path

    def initialize(@root : Path)
      Fakes.install(fakes)
    end

    def fakes : Path
      @root / "fakes"
    end

    # Each call to a fake, one line of its arguments per call.
    def calls(tool : String) : Array(String)
      path = fakes / "#{tool}.calls"
      File.exists?(path.to_s) ? File.read(path.to_s).lines : [] of String
    end

    # What the fake lsregister prints for `-dump`: one record per path.
    def register(entries : Array(Tuple(String, String))) : Nil
      body = entries.map_with_index do |(path, identifier), index|
        "-" * 80 + "\n" \
                   "bundle id:                  #{File.basename(path, ".app")} (0x#{(100 + index).to_s(16)})\n" \
                   "path:                       #{path} (0x#{(200 + index).to_s(16)})\n" \
                   "name:                       #{File.basename(path, ".app")}\n" \
                   "identifier:                 #{identifier}\n"
      end
      File.write((fakes / "lsregister.dump").to_s, body.join)
    end

    def template : Path
      @root / "template" / "Berth.app"
    end

    # A stand-in for the template: an Info.plist, an executable and the
    # asset catalog's icon.
    def write_template(bundle_id : String = "com.kellyredding.berth", extra : String = "") : Path
      SpecHelper.write_bundle(template, <<-XML)
        <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
        <key>CFBundleName</key><string>Berth</string>
        <key>CFBundleDisplayName</key><string>Berth</string>
        <key>CFBundleShortVersionString</key><string>0.1.0</string>
        <key>BerthBuildCommit</key><string>abc123def456</string>
        <key>CFBundleIconFile</key><string>AppIcon</string>
        <key>CFBundleIconName</key><string>AppIcon</string>
        #{extra}
        XML
      template
    end

    def config : Path
      @root / "config.json"
    end

    def write_config(body : String) : Nil
      File.write(config.to_s, body)
    end

    def read_config : String
      File.read(config.to_s)
    end

    def applications : Path
      @root / "Applications"
    end

    def write_png(relative : String) : Path
      path = @root / relative
      Dir.mkdir_p(path.parent.to_s)
      File.write(path.to_s, PNG)
      path
    end

    def env : Hash(String, String?)
      {
        "BERTH_ROOT"             => @root.to_s,
        "BERTH_CONFIG"           => nil,
        "BERTH_RUNTIME_DIR"      => nil,
        "BERTH_BINARY"           => nil,
        "BERTH_APPLICATIONS_DIR" => applications.to_s,
        "BERTH_SKIP_CLI"         => nil,
        "BERTH_SIGN_SCRIPT"      => (fakes / "sign-app.sh").to_s,
        "BERTH_CODESIGN"         => (fakes / "codesign").to_s,
        "BERTH_SIPS"             => (fakes / "sips").to_s,
        "BERTH_ICONUTIL"         => (fakes / "iconutil").to_s,
        "BERTH_LSREGISTER"       => (fakes / "lsregister").to_s,
        "FAKE_SIGN_EXIT"         => nil,
        "FAKE_SIGN_AUTHORITY"    => nil,
        # Placeholders, so a run never picks up the maintainer's own.
        "BERTH_SIGNING_OP_ACCOUNT" => SIGNING_ACCOUNT,
        "BERTH_SIGNING_OP_ITEM"    => SIGNING_ITEM,
      } of String => String?
    end
  end

  # The stand-ins. A signed bundle carries `Contents/.fake-signature`: the
  # signer ("adhoc" or an authority), then the identifier it was signed as.
  module Fakes
    extend self

    def install(dir : Path) : Nil
      Dir.mkdir_p(dir.to_s)
      SpecHelper.write_executable(dir / "sign-app.sh", <<-SH)
        #!/bin/sh
        echo "$*" >> "#{dir}/sign.calls"
        echo "${BERTH_SIGNING_OP_ACCOUNT-unset} ${BERTH_SIGNING_OP_ITEM-unset}" >> "#{dir}/sign-env.calls"
        [ -n "$FAKE_SIGN_EXIT" ] && { echo "fake sign-app.sh: exit $FAKE_SIGN_EXIT" >&2; exit "$FAKE_SIGN_EXIT"; }
        mode="$1"; shift
        signer="${FAKE_SIGN_AUTHORITY:-Berth Release Signing}"
        [ "$mode" = adhoc ] && signer=adhoc
        for app in "$@"; do
          id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
          printf '%s\\n%s\\n' "$signer" "$id" > "$app/Contents/.fake-signature"
        done
        SH
      SpecHelper.write_executable(dir / "codesign", <<-SH)
        #!/bin/sh
        echo "$*" >> "#{dir}/codesign.calls"
        for last; do :; done
        marker="$last/Contents/.fake-signature"
        if [ ! -f "$marker" ]; then echo "$last: code object is not signed at all" >&2; exit 1; fi
        [ "$1" = --verify ] && exit 0
        signer="$(sed -n 1p "$marker")"
        echo "Executable=$last/Contents/MacOS/Berth" >&2
        echo "Identifier=$(sed -n 2p "$marker")" >&2
        if [ "$signer" = adhoc ]; then echo "Signature=adhoc" >&2; else echo "Authority=$signer" >&2; fi
        SH
      SpecHelper.write_executable(dir / "sips", <<-SH)
        #!/bin/sh
        echo "$*" >> "#{dir}/sips.calls"
        for last; do :; done
        echo "png $2x$3" > "$last"
        SH
      SpecHelper.write_executable(dir / "iconutil", <<-SH)
        #!/bin/sh
        echo "$*" >> "#{dir}/iconutil.calls"
        ls "$5" > "$4"
        SH
      SpecHelper.write_executable(dir / "lsregister", <<-SH)
        #!/bin/sh
        echo "$*" >> "#{dir}/lsregister.calls"
        if [ "$1" = -dump ] && [ -f "#{dir}/lsregister.dump" ]; then cat "#{dir}/lsregister.dump"; fi
        exit 0
        SH
    end
  end

  # A bundle with an executable and an Info.plist holding `keys` (plist XML).
  def write_bundle(app : Path, keys : String) : Path
    Dir.mkdir_p((app / "Contents" / "MacOS").to_s)
    Dir.mkdir_p((app / "Contents" / "Resources").to_s)
    File.write((app / "Contents" / "MacOS" / "Berth").to_s, "binary")
    File.write((app / "Contents" / "Resources" / "AppIcon.icns").to_s, "template icon")
    File.write((app / "Contents" / "Info.plist").to_s, <<-XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      <key>CFBundleExecutable</key><string>Berth</string>
      #{keys}
      </dict>
      </plist>
      XML
    app
  end

  # A site app as `berth sites build` leaves it, signed by `signer`.
  def write_site_app(app : Path, site : String, bundle_id : String = "com.kellyredding.berth.#{site}",
                     signer : String? = "Berth Release Signing") : Path
    write_bundle(app, <<-XML)
      <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
      <key>BerthSite</key><string>#{site}</string>
      <key>CFBundleShortVersionString</key><string>0.1.0</string>
      XML
    signer.try { |name| File.write((app / "Contents" / ".fake-signature").to_s, "#{name}\n#{bundle_id}\n") }
    app
  end

  # An app's Info.plist as JSON.
  def plist(app : Path) : JSON::Any
    output = IO::Memory.new
    Process.run("/usr/bin/plutil", ["-convert", "json", "-o", "-", (app / "Contents" / "Info.plist").to_s], output: output)
    JSON.parse(output.to_s)
  end

  def sandbox(&)
    dir = File.tempname("berth-spec")
    Dir.mkdir_p(dir)
    real = Path.new(File.realpath(dir))
    begin
      yield Sandbox.new(real)
    ensure
      FileUtils.rm_rf(real.to_s)
    end
  end

  def run(sandbox : Sandbox, args : Array(String),
          extra_env : Hash(String, String?) = {} of String => String?,
          chdir : String? = nil) : Result
    unless File::Info.executable?(BINARY)
      raise "berth is not built at #{BINARY}; run `make dev` first"
    end
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, args, env: sandbox.env.merge(extra_env), output: stdout, error: stderr, chdir: chdir)
    Result.new(stdout.to_s, stderr.to_s, status.exit_code? || 128 + (status.exit_signal?.try(&.value) || 0))
  end

  # A stand-in for one site's app: answers each request with the reply line
  # given for its event (closing without a reply for any other event), and
  # records the requests. Sockets are bound under a runtime directory relative
  # to the sandbox, which the CLI is run from, because temporary directories
  # here can exceed the 104-byte socket path limit.
  class FakeApp
    RUNTIME = "runtime"

    getter requests = [] of JSON::Any
    @server : UNIXServer

    def initialize(@dir : Path, @site : String, @replies : Hash(String, String))
      Dir.mkdir_p((@dir / RUNTIME).to_s)
      @server = Dir.cd(@dir.to_s) { UNIXServer.new(socket) }
      spawn { serve }
    end

    def socket : String
      "#{RUNTIME}/#{@site}.sock"
    end

    def request : JSON::Any
      requests.size.should eq(1)
      requests.first
    end

    def close : Nil
      @server.close rescue nil
      File.delete?((@dir / socket).to_s)
    end

    private def serve : Nil
      while client = (@server.accept? rescue nil)
        begin
          line = client.gets
          next unless line
          request = JSON.parse(line)
          @requests << request
          if reply = @replies[request["event"].as_s]?
            client << reply << '\n'
          end
        rescue IO::Error
        ensure
          client.close rescue nil
        end
      end
    end
  end

  def with_app(sandbox : Sandbox, site : String, replies : Hash(String, String), &)
    app = FakeApp.new(sandbox.root, site, replies)
    begin
      yield app
    ensure
      app.close
    end
  end

  # Runs the CLI from the sandbox with the fake apps' runtime directory.
  def run_live(sandbox : Sandbox, args : Array(String), extra_env : Hash(String, String?) = {} of String => String?) : Result
    run(sandbox, args, {"BERTH_RUNTIME_DIR" => FakeApp::RUNTIME}.merge(extra_env), chdir: sandbox.root.to_s)
  end

  def write_executable(path : Path, body : String) : Path
    Dir.mkdir_p(path.parent.to_s)
    File.write(path.to_s, body)
    File.chmod(path.to_s, 0o755)
    path
  end

  # An export with `path` dropped and the fixtures directory written as
  # `fixtures/` in each icon, as fixtures/export.json writes it.
  def comparable_export(json : JSON::Any) : JSON::Any
    hash = json.as_h.reject("path")
    sites = hash["sites"].as_h.transform_values do |site|
      fields = site.as_h.dup
      if icon = fields["icon"]?.try(&.as_s?)
        fields["icon"] = JSON::Any.new(icon.sub("#{FIXTURES}/", "fixtures/"))
      end
      JSON::Any.new(fields)
    end
    hash["sites"] = JSON::Any.new(sites)
    JSON::Any.new(hash)
  end

  def validate(json : String, path : Path = Path.new("config.json")) : Berth::Config::Result
    tree = Berth::Config::Reader.parse(json)
    Berth::Config::Validator.validate(tree, Berth::Config::Source::File, path)
  end

  def errors(json : String, path : Path = Path.new("config.json")) : Array(String)
    validate(json, path).errors
  end
end
