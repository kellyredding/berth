module Berth
  # A value read from 1Password. It never prints: `to_s` and `inspect` give a
  # placeholder, so interpolating one into a message cannot leak it. `wipe`
  # zeroes its bytes once they have been sent.
  class Secret
    getter bytes : Bytes

    def initialize(@bytes : Bytes)
    end

    def wipe : Nil
      @bytes.fill(0_u8)
    end

    def to_s(io : IO) : Nil
      io << "[secret]"
    end

    def inspect(io : IO) : Nil
      io << "[secret]"
    end
  end

  # 1Password references and accounts as the config names them, and the `op`
  # CLI that reads them. Values come back on op's stdout, never through argv.
  module OnePassword
    extend self

    ACCOUNT = /\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,126}[A-Za-z0-9])?\z/

    # op gives up on the 1Password app within seconds, often while its
    # approval prompt is still on screen, so a timeout is retried, as
    # bin/lib/sign-app.sh does.
    RETRY_DELAY = 2.seconds
    MAX_WAIT    = 60.seconds

    # The parts of `op://VAULT/ITEM[/FIELD | /SECTION/FIELD]`, or nil when it
    # is not one.
    def parts(reference : String?) : Array(String)?
      parts = reference.try(&.lchop?("op://")).try(&.split('/'))
      return nil unless parts && (2..4).includes?(parts.size) && parts.none? { |part| part.strip.empty? }
      parts
    end

    # A sign-in address (example.1password.com) or an account ID, as `op --account`
    # takes it.
    def account?(text : String) : Bool
      text.matches?(ACCOUNT)
    end

    # One field, by reference (`op read`).
    def read(reference : String, account : String?, what : String) : Secret
      fetch(["read", "--no-newline", reference], account, what, optional: false).not_nil!
    end

    # The item's current one-time code (`op item get --otp`), or nil when the
    # item has none.
    def otp(item_reference : String, account : String?, what : String) : Secret?
      vault, item = parts(item_reference).not_nil!
      fetch(["item", "get", item, "--vault", vault, "--otp"], account, what, optional: true)
    end

    private def fetch(args : Array(String), account : String?, what : String, optional : Bool) : Secret?
      started = Time.monotonic
      announced = false
      loop do
        output = IO::Memory.new(4096)
        status, reason = run((account ? ["--account", account] : [] of String) + args, output)
        if status.success?
          return Secret.new(take(output))
        end
        output.to_slice.fill(0_u8)

        if reason.matches?(/dismissed|denied|declined|cancell?ed/i)
          raise NotPermitted.new("1Password declined to give #{what} (op: #{reason})")
        elsif reason.matches?(/timeout|timed out/i) && Time.monotonic - started < MAX_WAIT
          STDERR.puts "waiting for 1Password: approve its prompt (op: #{reason})" unless announced
          announced = true
          sleep RETRY_DELAY
        elsif optional
          return nil
        elsif reason.matches?(/isn't an item|isn't a vault|isn't a field|not found/i)
          raise Error.new("1Password could not find #{what} (op: #{reason})")
        else
          raise NotPermitted.new("1Password did not give #{what} (op: #{reason})")
        end
      end
    end

    # The exit status and op's last error line, without its log prefix.
    private def run(args : Array(String), output : IO::Memory) : {Process::Status, String}
      error = IO::Memory.new
      status = Process.run(Paths.op.to_s, args, input: Process::Redirect::Inherit, output: output, error: error)
      line = error.to_s.strip.lines.last? || "no reason given"
      {status, line.sub(/\A\[ERROR\]\s+\S+\s+\S+\s+/, "")}
    rescue failure : File::Error | IO::Error | RuntimeError
      raise NotPermitted.new("1Password's CLI is not available: could not run #{Paths.op} (#{failure.message}); " \
                             "install it and turn on its 1Password app integration")
    end

    # The value without a trailing newline, copied out of the buffer, which is
    # then zeroed.
    private def take(output : IO::Memory) : Bytes
      slice = output.to_slice
      size = slice.size
      while size > 0 && (slice[size - 1] == '\n'.ord || slice[size - 1] == '\r'.ord)
        size -= 1
      end
      value = Bytes.new(size)
      slice[0, size].copy_to(value)
      slice.fill(0_u8)
      value
    end
  end
end
