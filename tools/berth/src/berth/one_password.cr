module Berth
  # 1Password references and accounts as the config names them.
  module OnePassword
    extend self

    ACCOUNT = /\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,126}[A-Za-z0-9])?\z/

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
  end
end
