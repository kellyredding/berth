require "socket"

module Berth
  # One request line to a running site app over its Unix socket, and one reply
  # line back. No connection, or no reply within the timeout, means the app is
  # not running.
  #
  # MIRROR: BerthApp/BerthApp/Models/Envelope.swift (docs/contract.md, "Socket")
  module SocketClient
    extend self

    ENVELOPE_VERSION = 1
    READ_TIMEOUT     = 5.seconds
    WRITE_TIMEOUT    = 1.second

    class NotRunning < Error
      def initialize(site : String, reason : String)
        super("#{site}'s app is not running (#{reason})", ExitCode::NOT_RUNNING)
      end

      def code : String
        "not_running"
      end
    end

    # Connected, but no reply came back, so the request may have arrived.
    # Still `not_running` to callers, as the contract says.
    class NoReply < NotRunning
      getter reason : String

      def initialize(site : String, @reason : String)
        super(site, @reason)
      end
    end

    # A reply with `"ok": false`, mapped to the contract's exit codes.
    class Refused < Error
      getter reply_code : String

      def initialize(message : String, @reply_code : String)
        super(message, Refused.exit_code_for(@reply_code))
      end

      def self.exit_code_for(code : String) : Int32
        case code
        when "not_permitted" then ExitCode::NOT_PERMITTED
        when "not_found"     then ExitCode::NOT_FOUND
        else                      ExitCode::FAILED
        end
      end

      def code : String
        reply_code
      end
    end

    record ReloadOutcome, site : String, sent : Bool, loaded : Bool?, error : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "sent", sent
          json.field "loaded", loaded
          json.field "error", error
        end
      end

      # Nil when the app is not running: it loads the config when it starts.
      def summary : String?
        if !sent
          nil
        elsif loaded.nil?
          "#{site}'s app didn't confirm the reload (#{error || "no reason given"}); it also reloads " \
          "when the file changes, so `berth status` shows whether it took"
        elsif loaded
          "#{site}'s app reloaded the config"
        else
          "#{site}'s app could not reload the config: #{error || "no reason given"}"
        end
      end
    end

    def envelope(event : String, detail : Hash(String, JSON::Any)? = nil) : String
      JSON.build do |json|
        json.object do
          json.field "v", ENVELOPE_VERSION
          json.field "event", event
          json.field "ts", Time.utc.to_unix
          json.field "detail_data", detail if detail
        end
      end
    end

    # The reply's `data` on success; raises NotRunning or Refused otherwise.
    def request(site : String, event : String, detail : Hash(String, JSON::Any)? = nil,
                timeout : Time::Span = READ_TIMEOUT) : JSON::Any
      parse_reply(site, exchange(site, "#{envelope(event, detail)}\n".to_slice, timeout))
    end

    # A request line built by the caller, ending in a newline: how
    # `signin.fill` sends values it never turns into strings.
    def request_line(site : String, line : Bytes, timeout : Time::Span) : JSON::Any
      parse_reply(site, exchange(site, line, timeout))
    end

    private def parse_reply(site : String, line : String) : JSON::Any
      reply = begin
        JSON.parse(line)
      rescue JSON::ParseException
        raise Error.new("#{site}'s app sent a reply that is not JSON: #{line[0, 200]}")
      end

      if reply["ok"]?.try(&.as_bool?)
        reply["data"]? || JSON::Any.new({} of String => JSON::Any)
      else
        raise Refused.new(
          reply["error"]?.try(&.as_s?) || "#{site}'s app refused the request",
          reply["code"]?.try(&.as_s?) || "internal",
        )
      end
    end

    # Sent to every site's app after a config write. Its failure never fails
    # the write.
    def reload_quietly(site : String) : ReloadOutcome
      data = request(site, "reload")
      ReloadOutcome.new(site, true, data["loaded"]?.try(&.as_bool?) || false, data["error"]?.try(&.as_s?))
    rescue silent : NoReply
      ReloadOutcome.new(site, true, nil, silent.reason)
    rescue NotRunning
      ReloadOutcome.new(site, false, nil, nil)
    rescue error : Error
      ReloadOutcome.new(site, true, false, error.message)
    end

    def reload_all(sites : Array(String)) : Array(ReloadOutcome)
      sites.map { |site| reload_quietly(site) }
    end

    private def exchange(site : String, line : Bytes, timeout : Time::Span) : String
      path = Paths.socket(site).to_s
      socket = begin
        UNIXSocket.new(path)
      rescue error : Socket::Error | IO::Error | File::Error | ArgumentError
        raise NotRunning.new(site, "no connection at #{path}")
      end

      begin
        socket.sync = true
        socket.write_timeout = WRITE_TIMEOUT
        socket.read_timeout = timeout
        socket.write(line)
        reply = socket.gets(chomp: true)
        if reply.nil? || reply.empty?
          raise NoReply.new(site, "no reply at #{path}")
        end
        reply
      rescue IO::TimeoutError
        raise NoReply.new(site, "no reply within #{timeout.total_seconds.to_i}s at #{path}")
      rescue error : IO::Error | Socket::Error
        raise NoReply.new(site, "the connection failed: #{error.message}")
      ensure
        socket.close rescue nil
      end
    end
  end
end
