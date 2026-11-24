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

  record Result, stdout : String, stderr : String, exit_code : Int32 do
    def json : JSON::Any
      JSON.parse(stdout)
    end
  end

  # One example's world: a private BERTH_ROOT and applications directory.
  class Sandbox
    getter root : Path

    def initialize(@root : Path)
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
      } of String => String?
    end
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
