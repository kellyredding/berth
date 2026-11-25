module Berth
  module Commands
    module Doctor
      # What install.sh left: its record, the CLI, the template and the
      # signing script, each checked against the record.
      module InstallChecks
        extend self

        record Report,
          manifest_path : String,
          manifest : JSON::Any?,
          cli : Hash(String, String | Bool | Nil)?,
          template : Hash(String, String | Bool | Nil)?,
          sign_script : Hash(String, String | Bool)?,
          template_commit : String? do
          def to_json(json : JSON::Builder) : Nil
            json.object do
              json.field "manifest_path", manifest_path
              json.field "manifest", manifest
              json.field "cli", cli
              json.field "template", template
              json.field "sign_script", sign_script
            end
          end
        end

        def run(checks : Array(Check), registrations : Array(MacOS::LaunchServices::Registration)?) : Report
          path = Paths.installed_manifest
          manifest = read_manifest(path)
          unless manifest
            problem = File.exists?(path.to_s) ? "unreadable install record at #{path}" : "no install record at #{path}"
            checks << Check.new(Level::Warn, "install", "#{problem}; `berth update` installs a release and writes one")
            return Report.new(path.to_s, nil, nil, nil, nil, nil)
          end

          checks << Check.new(Level::Ok, "install", describe(manifest))
          cli = cli_check(checks, manifest)
          template, commit = template_checks(checks, manifest, registrations)
          sign_script = sign_script_check(checks)
          Report.new(path.to_s, manifest, cli, template, sign_script, commit)
        end

        private def cli_check(checks : Array(Check), manifest : JSON::Any) : Hash(String, String | Bool | Nil)
          binary = Paths.installed_cli
          expected = field(manifest, "berth_sha256")
          sha256 = File.file?(binary.to_s) ? sha256_of(binary) : nil
          if sha256.nil?
            checks << Check.new(Level::Fail, "installed cli", "#{binary} is missing; `berth update` installs it")
          elsif expected.nil?
            checks << Check.new(Level::Warn, "installed cli", "the install record has no checksum to compare #{binary} with")
          elsif sha256 == expected
            checks << Check.new(Level::Ok, "installed cli", "#{binary} is the recorded build")
          else
            checks << Check.new(Level::Fail, "installed cli",
              "#{binary} is not the build the install record names; `berth update` reinstalls it")
          end
          {"path" => binary.to_s, "sha256" => sha256, "matches" => !sha256.nil? && sha256 == expected}
        end

        # The template's build commit, which every site app built from it
        # carries, is returned for the site checks.
        private def template_checks(checks : Array(Check), manifest : JSON::Any,
                                    registrations : Array(MacOS::LaunchServices::Registration)?) : Tuple(Hash(String, String | Bool | Nil)?, String?)
          template = Paths.template_app
          if File.symlink?(template.to_s)
            checks << Check.new(Level::Fail, "template",
              "#{template} is a link to #{File.readlink(template.to_s)}, not an installed copy; `berth update` installs one")
            return {nil, nil}
          end
          unless Dir.exists?(template.to_s)
            checks << Check.new(Level::Fail, "template", "#{template} is missing; `berth update` installs it")
            return {nil, nil}
          end

          plist = MacOS::InfoPlist.new(template)
          version = plist["CFBundleShortVersionString"]
          commit = plist["BerthBuildCommit"]
          recorded = field(manifest, "commit")
          if plist["CFBundleIdentifier"] != SiteBuild::TEMPLATE_ID || plist["BerthSite"]
            checks << Check.new(Level::Fail, "template",
              "#{template} is not the Berth template (#{SiteBuild::TEMPLATE_ID}, naming no site); `berth update` replaces it")
          elsif commit.nil?
            checks << Check.new(Level::Fail, "template",
              "#{template} carries no build commit, so install.sh did not install it; `berth update` replaces it")
          elsif recorded && commit != recorded
            checks << Check.new(Level::Fail, "template",
              "#{template} is from #{commit}, the install record from #{recorded}; `berth update` reinstalls both")
          else
            checks << Check.new(Level::Ok, "template", "#{template}: Berth #{version || "unknown version"} (#{commit})")
          end

          signature = MacOS::Signature.read(template)
          expected = field(manifest, "signer")
          if !signature.verified
            checks << Check.new(Level::Fail, "template signer", "its signature does not verify: #{signature.problem}")
          elsif signature.authority.nil?
            checks << Check.new(Level::Fail, "template signer",
              "signed #{signature.signer}, so every site app built from it would be too; `berth update` reinstalls it")
          elsif expected && signature.authority != expected
            checks << Check.new(Level::Fail, "template signer",
              "signed by #{signature.signer}, the install record says #{expected}")
          else
            checks << Check.new(Level::Ok, "template signer", signature.signer)
          end

          registered = registrations.try { |found| registered_paths(found, template) }
          registered.try do |paths|
            if paths.empty?
              checks << Check.new(Level::Ok, "template registered", "no: Launch Services does not know the template")
            else
              paths.each do |path|
                checks << Check.new(Level::Warn, "template registered",
                  "Launch Services knows the template at #{path}, which must never open or be offered links; " \
                  "`berth update` unregisters it, as does `lsregister -u #{path}`")
              end
            end
          end

          report = {"path" => template.to_s, "version" => version, "commit" => commit, "signer" => signature.signer,
                    "registered" => registered.try { |paths| !paths.empty? }} of String => String | Bool | Nil
          {report, commit}
        end

        # The template itself, or anything install.sh stages beside it.
        private def registered_paths(registrations : Array(MacOS::LaunchServices::Registration), template : Path) : Array(String)
          places = [template.to_s, File.realpath(template.to_s)]
          dirs = places.map { |place| "#{Path.new(place).parent}/" }
          registrations.map(&.path).select do |path|
            places.includes?(path) || dirs.any? { |dir| path.starts_with?(dir) }
          end.uniq
        end

        private def sign_script_check(checks : Array(Check)) : Hash(String, String | Bool)
          script = Paths.installed_sign_script
          present = File.file?(script.to_s) && File::Info.executable?(script.to_s)
          if present
            checks << Check.new(Level::Ok, "sign script", script.to_s)
          else
            checks << Check.new(Level::Fail, "sign script",
              "#{script} is missing; `berth sites build --sign op` needs it, and `berth update` reinstalls it")
          end
          {"path" => script.to_s, "present" => present}
        end

        # Not Digest::SHA256: it links Homebrew's OpenSSL, which bin/package
        # refuses to ship.
        private def sha256_of(path : Path) : String?
          output = IO::Memory.new
          status = Process.run("/usr/bin/shasum", ["-a", "256", path.to_s],
            output: output, error: Process::Redirect::Close)
          status.success? ? output.to_s.split.first? : nil
        end

        private def read_manifest(path : Path) : JSON::Any?
          return nil unless File.file?(path.to_s)
          manifest = JSON.parse(File.read(path.to_s))
          manifest.as_h? ? manifest : nil
        rescue JSON::ParseException | File::Error
          nil
        end

        private def field(manifest : JSON::Any, name : String) : String?
          manifest[name]?.try(&.as_s?)
        end

        private def describe(manifest : JSON::Any) : String
          build = [field(manifest, "commit") || "unknown commit"]
          build << "uncommitted changes" if manifest["dirty"]?.try(&.as_bool?)
          detail = "Berth #{field(manifest, "version") || "unknown"} (#{build.join(", ")})"
          field(manifest, "built_at").try { |built| detail += ", built #{built}" }
          signer = field(manifest, "signer")
          detail + (signer ? ", signed by #{signer}" : ", signer not recorded")
        end
      end
    end
  end
end
