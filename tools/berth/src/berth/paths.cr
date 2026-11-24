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

    def applications_dir : Path
      env_path("BERTH_APPLICATIONS_DIR") || Path.home / "Applications"
    end

    # Where `berth sites build` puts the app for a site with this name.
    def site_app(name : String) : Path
      applications_dir / "#{name}.app"
    end

    private def env_path(name : String) : Path?
      value = ENV[name]?
      value && !value.empty? ? Path.new(value) : nil
    end
  end
end
