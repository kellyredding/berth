require "json"
require "uri"

# Explicit and first: the glob below loads alphabetically, and every error
# class needs its superclass defined before it.
require "./berth/error"
require "./berth/**"

module Berth
  VERSION        = {{ read_file("#{__DIR__}/../../../VERSION").strip }}
  STARTER_CONFIG = {{ read_file("#{__DIR__}/../../../config/starter.json") }}
end

# Specs require this file to reach the library without running the program;
# integration specs run the built binary instead.
unless ENV.has_key?("BERTH_SKIP_CLI")
  Berth::CLI.run(ARGV)
end
