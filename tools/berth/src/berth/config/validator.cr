module Berth
  module Config
    record Result, model : Model?, errors : Array(String), warnings : Array(String) do
      def valid? : Bool
        errors.empty?
      end

      def model! : Model
        model || raise InvalidConfig.new("the config is invalid", errors)
      end
    end

    # Checks a config tree against docs/contract.md ("Validation") and builds
    # the normalized model. Every problem is reported, not just the first.
    class Validator
      PNG_SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      LABEL         = /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?/
      HOST          = /\A#{LABEL}(?:\.#{LABEL})*\z/

      def self.validate(tree : JSON::Any, source : Source, path : Path) : Result
        new(tree, source, path).run
      end

      @errors = [] of String
      @warnings = [] of String

      def initialize(@tree : JSON::Any, @source : Source, @path : Path)
        @directory = Config.directory(@path)
      end

      def run : Result
        root = object(@tree, "the config") || {} of String => JSON::Any
        root.each_key do |key|
          error("unknown top-level key #{key.inspect}") unless SECTIONS.includes?(key)
        end

        version = check_version(root["version"]?)
        sites = (object(root["sites"]?, "sites") || {} of String => JSON::Any).compact_map do |id, value|
          check_site(id, value)
        end

        names = {} of String => String
        sites.each do |site|
          if earlier = names[site.name.downcase]?
            error("sites.#{site.id}.name: #{site.name.inspect} is also #{earlier}'s name; " \
                  "two sites cannot share an app")
          else
            names[site.name.downcase] = site.id
          end
        end

        unless @errors.empty?
          return Result.new(nil, @errors, @warnings)
        end
        Result.new(Model.new(version, @source, @path, sites, @warnings), @errors, @warnings)
      end

      private def check_version(value : JSON::Any?) : Int64
        return 1_i64 if value.nil?
        error("version: must be 1, got #{show(value)}") unless value.raw == 1_i64
        1_i64
      end

      private def check_site(id : String, value : JSON::Any) : Site?
        where = "sites.#{id}"
        unless id.matches?(SITE_PATTERN) && id.size <= SITE_MAX
          error("#{where}: site names use lowercase letters, digits and hyphens, " \
                "starting with a letter or digit, at most #{SITE_MAX} characters")
        end
        body = object(value, where)
        if body.nil?
          error("#{where}: must be an object") if value.raw.nil?
          return nil
        end
        allowed_keys(where, body, SITE_KEYS)

        name = check_name("#{where}.name", present(body, "name"))
        url = check_url("#{where}.url", present(body, "url"), required: true)
        host = url.try { |text| URI.parse(text).host.try(&.downcase) }
        keep = check_keep("#{where}.keep", present(body, "keep"), host)
        icon = check_icon("#{where}.icon", present(body, "icon"))
        badge = check_badge("#{where}.badge", present(body, "badge"))
        handles = check_handles("#{where}.handles", present(body, "handles"))
        mailto = check_mailto("#{where}.mailto", present(body, "mailto"), handles.includes?("mailto"))
        notifications = flag("#{where}.notifications", present(body, "notifications"))
        launch_at_login = flag("#{where}.launch_at_login", present(body, "launch_at_login"))
        signin = check_signin("#{where}.signin", present(body, "signin"))

        return nil unless name && url && host
        Site.new(
          id: id,
          name: name,
          url: url,
          keep: keep || [host],
          icon: icon,
          badge_title: badge,
          handles: handles,
          mailto: mailto,
          notifications: notifications,
          launch_at_login: launch_at_login,
          signin: signin,
        )
      end

      # The value under `key`, with `null` read as absent.
      private def present(body : Hash(String, JSON::Any), key : String) : JSON::Any?
        value = body[key]?
        value.nil? || value.raw.nil? ? nil : value
      end

      private def check_name(where : String, value : JSON::Any?) : String?
        if value.nil?
          error("#{where}: required; the app's display and file name, such as \"Mail\"")
          return nil
        end
        name = value.as_s?
        problem =
          if name.nil?
            "must be a string, got #{show(value)}"
          elsif name.strip.empty?
            "cannot be empty"
          elsif name != name.strip
            "#{name.inspect} has spaces at its start or end"
          elsif name.size > NAME_MAX
            "must be at most #{NAME_MAX} characters"
          elsif name.starts_with?('.')
            "cannot start with \".\""
          elsif name.includes?('/') || name.includes?(':')
            "cannot contain \"/\" or \":\", since it names a file"
          elsif name.each_char.any?(&.control?)
            "cannot contain a control character"
          end
        if problem
          error("#{where}: #{problem}")
          return nil
        end
        name
      end

      private def check_url(where : String, value : JSON::Any?, required : Bool) : String?
        if value.nil?
          error("#{where}: required; an https URL") if required
          return nil
        end
        text = value.as_s?
        unless text && https?(text)
          error("#{where}: must be an https URL, got #{show(value)}")
          return nil
        end
        text
      end

      private def https?(text : String) : Bool
        return false if text.matches?(/\s/)
        uri = URI.parse(text)
        uri.scheme == "https" && !uri.host.to_s.empty?
      rescue URI::Error
        false
      end

      private def check_keep(where : String, value : JSON::Any?, host : String?) : Array(String)?
        return nil if value.nil?
        list = value.as_a?
        if list.nil? || list.empty?
          error("#{where}: must be a list of hosts, such as [\"mail.example.com\", \"*.example.com\"], got #{show(value)}")
          return nil
        end
        patterns = [] of String
        list.each_with_index do |item, index|
          pattern = item.as_s?
          if pattern.nil?
            error("#{where}[#{index}]: must be a host, got #{show(item)}")
          elsif problem = host_pattern_problem(pattern)
            error("#{where}[#{index}]: #{problem}")
          elsif patterns.includes?(pattern)
            error("#{where}: #{pattern.inspect} is listed more than once")
          else
            patterns << pattern
          end
        end
        if host && patterns.size == list.size && patterns.none? { |pattern| Config.keeps?(pattern, host) }
          error("#{where}: nothing matches the url's host #{host.inspect}; add it")
        end
        patterns
      end

      private def host_pattern_problem(pattern : String) : String?
        suffix = pattern.starts_with?("*.") ? pattern[2..] : nil
        host = suffix || pattern
        unless host.matches?(HOST)
          return "#{pattern.inspect} is not a host or *.suffix pattern " \
                 "(lowercase letters, digits, hyphens and dots)"
        end
        if suffix && !suffix.includes?('.')
          return "#{pattern.inspect} is too broad; a *. pattern needs a suffix of at least two labels"
        end
        nil
      end

      private def check_icon(where : String, value : JSON::Any?) : Path?
        return nil if value.nil?
        text = value.as_s?
        if text.nil? || text.empty?
          error("#{where}: must be the path of a PNG file, got #{show(value)}")
          return nil
        end
        path = Path.new(text).expand(@directory)
        unless File.file?(path.to_s)
          error("#{where}: no file at #{path}")
          return nil
        end
        unless png?(path)
          error("#{where}: #{path} is not a PNG")
          return nil
        end
        path
      end

      private def png?(path : Path) : Bool
        header = Bytes.new(PNG_SIGNATURE.size)
        !File.open(path.to_s, &.read_fully?(header)).nil? && header == PNG_SIGNATURE
      rescue File::Error
        false
      end

      private def check_badge(where : String, value : JSON::Any?) : String?
        return nil if value.nil?
        body = object(value, where)
        return nil unless body
        allowed_keys(where, body, ["title"])
        title = present(body, "title")
        if title.nil?
          error("#{where}: needs a title, a regular expression with one capture group")
          return nil
        end
        pattern = title.as_s?
        unless pattern
          error("#{where}.title: must be a regular expression, got #{show(title)}")
          return nil
        end
        regex = begin
          Regex.new(pattern)
        rescue invalid : ArgumentError
          error("#{where}.title: does not compile: #{invalid.message}")
          return nil
        end
        unless regex.capture_count == 1
          error("#{where}.title: needs exactly one capture group, the badge text; it has #{regex.capture_count}")
          return nil
        end
        pattern
      end

      private def check_handles(where : String, value : JSON::Any?) : Array(String)
        schemes = [] of String
        return schemes if value.nil?
        list = value.as_a?
        unless list
          error("#{where}: must be a list of URL schemes, such as [\"mailto\"], got #{show(value)}")
          return schemes
        end
        list.each_with_index do |item, index|
          scheme = item.as_s?
          if scheme.nil? || !HANDLED_SCHEMES.includes?(scheme)
            error("#{where}[#{index}]: must be one of #{HANDLED_SCHEMES.join(", ")}, got #{show(item)}")
          elsif schemes.includes?(scheme)
            error("#{where}: #{scheme.inspect} is listed more than once")
          else
            schemes << scheme
          end
        end
        schemes
      end

      private def check_mailto(where : String, value : JSON::Any?, handled : Bool) : String?
        if value.nil?
          error("#{where}: required when handles has \"mailto\"; the URL a mailto: link opens, with %s for the link") if handled
          return nil
        end
        text = value.as_s?
        unless text && text.scan("%s").size == 1 && https?(text.sub("%s", "x"))
          error("#{where}: must be an https URL with %s exactly once, where the mailto: link goes, got #{show(value)}")
          return nil
        end
        @warnings << "#{where}: unused; add mailto to handles or remove it" unless handled
        text
      end

      private def check_signin(where : String, value : JSON::Any?) : Hash(String, Array(Step))
        logins = {} of String => Array(Step)
        return logins if value.nil?
        body = object(value, where)
        return logins unless body
        body.each do |login, steps_value|
          at = "#{where}.#{login}"
          unless login.matches?(SITE_PATTERN)
            error("#{at}: login names use lowercase letters, digits and hyphens, starting with a letter or digit")
          end
          list = steps_value.as_a?
          if list.nil? || list.empty?
            error("#{at}: must be a list of sign-in steps, such as [{\"flow\": \"google\", \"item\": \"op://Vault/Item\"}], got #{show(steps_value)}")
            next
          end
          steps = list.map_with_index { |step, index| check_step("#{at}[#{index}]", step) }
          if steps.last.try(&.email_from)
            error("#{at}[#{steps.size - 1}]: an email_from step hands off to the next step's sign-in, so a step must follow it")
          end
          logins[login] = steps.compact if steps.all?
        end
        logins
      end

      private def check_step(where : String, value : JSON::Any) : Step?
        body = object(value, where)
        if body.nil?
          error("#{where}: must be a step object, got null") if value.raw.nil?
          return nil
        end
        allowed_keys(where, body, ["flow", "item", "email_from", "account", "method"])
        flow = present(body, "flow").try(&.as_s?)
        unless flow && FLOWS.includes?(flow)
          error("#{where}.flow: must be one of #{FLOWS.join(", ")}, got #{body["flow"]?.try { |raw| show(raw) } || "nothing"}")
        end
        account = check_account("#{where}.account", present(body, "account"))
        method = check_method("#{where}.method", present(body, "method"), flow)
        item = present(body, "item")
        email_from = present(body, "email_from")
        if item && email_from
          error("#{where}: give item or email_from, not both")
          return nil
        elsif item.nil? && email_from.nil?
          error("#{where}: needs an item (sign in with it) or email_from (give only its email)")
          return nil
        end
        if email_from && flow && flow != "google"
          error("#{where}.email_from: only a google step can give only the email")
        end
        reference = item ? item_reference("#{where}.item", item) : field_reference("#{where}.email_from", email_from.not_nil!)
        return nil unless flow && FLOWS.includes?(flow) && reference
        item ? Step.new(flow, reference, nil, account, method) : Step.new(flow, nil, reference, account, method)
      end

      # An item step reads the item's username, password and one-time code,
      # so it names the item alone.
      private def item_reference(where : String, value : JSON::Any) : String?
        text = value.as_s?
        parts = OnePassword.parts(text)
        if text && parts && parts.size == 2
          text
        else
          error("#{where}: must be a 1Password item, op://VAULT/ITEM, got #{show(value)}")
          nil
        end
      end

      private def field_reference(where : String, value : JSON::Any) : String?
        text = value.as_s?
        if text && OnePassword.parts(text)
          text
        else
          error("#{where}: must be a 1Password reference, op://VAULT/ITEM " \
                "(optionally /FIELD or /SECTION/FIELD), got #{show(value)}")
          nil
        end
      end

      private def check_account(where : String, value : JSON::Any?) : String?
        return nil if value.nil?
        text = value.as_s?
        if text && OnePassword.account?(text)
          text
        else
          error("#{where}: must be a 1Password account, its sign-in address (such as example.1password.com) " \
                "or its ID, got #{show(value)}")
          nil
        end
      end

      private def check_method(where : String, value : JSON::Any?, flow : String?) : String?
        return nil if value.nil?
        text = value.as_s?
        unless text && !text.strip.empty? && text.size <= METHOD_MAX
          error("#{where}: must be the text of a verification method in Okta's list, " \
                "1 to #{METHOD_MAX} characters, got #{show(value)}")
          return nil
        end
        if flow && flow != "okta"
          error("#{where}: only an okta step chooses a verification method; Okta alone lists them")
          return nil
        end
        text
      end

      private def flag(where : String, value : JSON::Any?) : Bool
        return false if value.nil?
        bool = value.as_bool?
        error("#{where}: must be true or false, got #{show(value)}") if bool.nil?
        bool || false
      end

      private def object(value : JSON::Any?, where : String) : Hash(String, JSON::Any)?
        return nil if value.nil? || value.raw.nil?
        hash = value.as_h?
        error("#{where}: must be an object, got #{show(value)}") unless hash
        hash
      end

      private def allowed_keys(where : String, hash : Hash(String, JSON::Any), allowed : Array(String)) : Nil
        hash.each_key do |key|
          error("#{where}: unknown key #{key.inspect}") unless allowed.includes?(key)
        end
      end

      private def show(value : JSON::Any) : String
        value.to_json
      end

      private def error(message : String) : Nil
        @errors << message
      end
    end
  end
end
