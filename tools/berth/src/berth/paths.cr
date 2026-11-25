module Berth
  # Every path the CLI uses, each overridable so specs run in a temporary
  # directory. The CLI never assumes the runtime directories exist.
  #
  # MIRROR: BerthApp/BerthApp/Models/Paths.swift (docs/contract.md, "Paths")
  module Paths
    extend self

    def root : Path
      env_path("BERTH_ROOT") || Path.home / ".berth"
    end

    def config_file : Path
      env_path("BERTH_CONFIG") || root / "config.json"
    end

    def runtime_dir : Path
      env_path("BERTH_RUNTIME_DIR") || root / "runtime"
    end

    def socket(site : String) : Path
      runtime_dir / "#{site}.sock"
    end

    def log_dir : Path
      runtime_dir / "logs"
    end

    def log(site : String) : Path
      log_dir / "#{site}.log"
    end

    def binary : Path
      env_path("BERTH_BINARY") || root / "bin" / "berth"
    end

    def template_app : Path
      root / "template" / "Berth.app"
    end

    def installed_manifest : Path
      root / "installed-manifest.json"
    end

    # Where install.sh puts the CLI, whatever BERTH_BINARY says.
    def installed_cli : Path
      root / "bin" / "berth"
    end

    def installed_sign_script : Path
      root / "libexec" / "sign-app.sh"
    end

    def applications_dir : Path
      env_path("BERTH_APPLICATIONS_DIR") || Path.home / "Applications"
    end

    # Where `berth sites build` puts the app for a site with this name.
    def site_app(name : String) : Path
      applications_dir / "#{name}.app"
    end

    # The program that launches a site app; specs put a stand-in here.
    def open_command : Path
      env_path("BERTH_OPEN") || Path.new("/usr/bin/open")
    end

    # 1Password's CLI, found on PATH; specs put a stand-in here.
    def op : Path
      env_path("BERTH_OP") || Path.new("op")
    end

    # The programs that build and inspect site apps. Specs put stand-ins here,
    # so they never sign anything or touch the real Launch Services database.
    def codesign : Path
      env_path("BERTH_CODESIGN") || Path.new("/usr/bin/codesign")
    end

    def sips : Path
      env_path("BERTH_SIPS") || Path.new("/usr/bin/sips")
    end

    def iconutil : Path
      env_path("BERTH_ICONUTIL") || Path.new("/usr/bin/iconutil")
    end

    def lsregister : Path
      env_path("BERTH_LSREGISTER") ||
        Path.new("/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/" \
                 "LaunchServices.framework/Versions/Current/Support/lsregister")
    end

    # Where `berth sites build` may find bin/lib/sign-app.sh, in the order it
    # looks: BERTH_SIGN_SCRIPT alone when set; else the checkout this binary
    # was built in (tools/berth/build/berth), then the installed copy.
    def sign_script_candidates : Array(Path)
      if script = env_path("BERTH_SIGN_SCRIPT")
        return [script]
      end
      candidates = [] of Path
      checkout_root.try { |repo| candidates << repo / "bin" / "lib" / "sign-app.sh" }
      candidates << installed_sign_script
      candidates
    end

    def sign_script : Path?
      sign_script_candidates.find { |path| File::Info.executable?(path.to_s) && File.file?(path.to_s) }
    end

    # The repository a development binary was built in, or nil for an
    # installed binary.
    private def checkout_root : Path?
      executable = Process.executable_path.try { |path| Path.new(path) }
      return nil unless executable
      build = executable.parent
      tool = build.parent
      return nil unless build.basename == "build" && tool.basename == "berth" && tool.parent.basename == "tools"
      tool.parent.parent
    end

    private def env_path(name : String) : Path?
      value = ENV[name]?
      value && !value.empty? ? Path.new(value) : nil
    end
  end
end
