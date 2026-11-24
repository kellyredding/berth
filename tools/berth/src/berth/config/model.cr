module Berth
  module Config
    SECTIONS = ["version", "sites"]

    # A site's keys, in the order the CLI writes them.
    SITE_KEYS = ["name", "url", "keep", "icon", "badge", "handles", "mailto", "notifications", "launch_at_login", "signin"]

    SITE_PATTERN    = /\A[a-z0-9][a-z0-9-]*\z/
    SITE_MAX        = 32
    NAME_MAX        = 64
    BUNDLE_PREFIX   = "com.kellyredding.berth."
    HANDLED_SCHEMES = ["mailto"]
    FLOWS           = ["google", "okta"]

    enum Source
      File
      Starter

      def label : String
        to_s.downcase
      end
    end

    # One step of a sign-in: a 1Password item signed in with `flow`, or for
    # `google` only, an item whose username is handed to the page as the email.
    record Step, flow : String, item : String?, email_from : String?

    record Site,
      id : String,
      name : String,
      url : String,
      keep : Array(String),
      icon : Path?,
      badge_title : String?,
      handles : Array(String),
      mailto : String?,
      notifications : Bool,
      launch_at_login : Bool,
      signin : Hash(String, Array(Step)) do
      def bundle_id : String
        "#{BUNDLE_PREFIX}#{id}"
      end

      def app : Path
        Paths.site_app(name)
      end
    end

    # The normalized config: defaults filled in, icons resolved.
    record Model,
      version : Int64,
      source : Source,
      path : Path,
      sites : Array(Site),
      warnings : Array(String) do
      def site?(id : String) : Site?
        sites.find { |site| site.id == id }
      end

      def site!(id : String) : Site
        site?(id) || raise NotFound.new("no site named #{id.inspect}#{Model.choices(sites.map(&.id))}")
      end

      def self.choices(ids : Array(String)) : String
        ids.empty? ? "; there are no sites" : "; the sites are #{ids.join(", ")}"
      end
    end

    # Whether a `keep` pattern matches a host: exactly, or for `*.suffix`, any
    # host ending in `.suffix` (not the suffix itself).
    def self.keeps?(pattern : String, host : String) : Bool
      host = host.downcase
      if pattern.starts_with?("*.")
        host.ends_with?(pattern[1..])
      else
        host == pattern
      end
    end

    # The directory the config file really lives in, after following its
    # symlinks: where a relative `icon` is found.
    def self.directory(path : Path) : Path
      parent = Writer.resolve(path).parent
      Dir.exists?(parent.to_s) ? Path.new(File.realpath(parent.to_s)) : parent
    end
  end
end
