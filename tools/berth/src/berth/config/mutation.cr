module Berth
  module Config
    # One change to the config: load (the starter when there is no file),
    # apply, validate the whole result, write symlink-safely, then ask each
    # site's running app to reload. An invalid result is refused and nothing
    # is written.
    class Mutation
      record Outcome, path : Path, written : Path, model : Model, reloads : Array(SocketClient::ReloadOutcome)

      getter root : Hash(String, JSON::Any)
      @sites_before : Array(String)

      def self.apply(&block : Mutation -> Nil) : Outcome
        mutation = new(Store.load)
        yield mutation
        mutation.commit
      end

      def initialize(@loaded : Loaded)
        tree = @loaded.tree
        if tree.raw.nil?
          @root = {} of String => JSON::Any
        else
          @root = tree.as_h? || raise InvalidConfig.new("the config is invalid", ["the config: must be an object"])
        end
        # A removed site's app is told too, so it reports that its site is gone.
        @sites_before = (@root["sites"]?.try(&.as_h?).try(&.keys) || [] of String).select(&.matches?(SITE_PATTERN))
      end

      # The `sites` object, created in canonical position if absent.
      def sites : Hash(String, JSON::Any)
        existing = @root["sites"]?
        if existing && !existing.raw.nil?
          return existing.as_h? || raise InvalidConfig.new("the config is invalid", ["sites: must be an object"])
        end

        hash = {} of String => JSON::Any
        Mutation.put(@root, "sites", JSON::Any.new(hash), SECTIONS)
        hash
      end

      # The site's object; NotFound when there is no such site.
      def site(id : String) : Hash(String, JSON::Any)
        existing = sites[id]? || raise NotFound.new("no site named #{id.inspect}#{Model.choices(sites.keys)}")
        existing.as_h? || raise InvalidConfig.new("the config is invalid", ["sites.#{id}: must be an object"])
      end

      def commit : Outcome
        result = Validator.validate(JSON::Any.new(@root), @loaded.source, @loaded.path)
        unless result.valid?
          raise InvalidConfig.new("refused: the change would leave the config invalid; nothing was written", result.errors)
        end

        written = Writer.write(@loaded.path, Emitter.emit(@root))
        model = result.model!
        Outcome.new(@loaded.path, written, model.copy_with(source: Source::File),
          SocketClient.reload_all((model.sites.map(&.id) + @sites_before).uniq))
      end

      # Sets `key` in place when present, else inserts it before the first key
      # that `order` puts after it.
      def self.put(hash : Hash(String, JSON::Any), key : String, value : JSON::Any, order : Array(String)) : Nil
        if hash.has_key?(key)
          hash[key] = value
          return
        end
        rank = ->(name : String) { order.index(name) || order.size }
        entries = hash.to_a
        position = entries.index { |name, _| rank.call(name) > rank.call(key) } || entries.size
        entries.insert(position, {key, value})
        hash.clear
        entries.each { |name, item| hash[name] = item }
      end
    end
  end
end
