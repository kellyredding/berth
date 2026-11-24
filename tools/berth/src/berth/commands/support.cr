module Berth
  module Commands
    # Helpers shared by the command modules.
    module Support
      extend self

      def help(args : Args, text : String) : Int32?
        return nil unless args.help?
        STDOUT.puts text
        ExitCode::OK
      end

      def print_json(&block : JSON::Builder ->) : Nil
        STDOUT.puts JSON.build(indent: "  ") { |json| block.call(json) }
      end

      def print_json(value) : Nil
        STDOUT.puts value.to_pretty_json
      end

      def report_mutation(args : Args, outcome : Config::Mutation::Outcome, message : String,
                          &extra : JSON::Builder ->) : Int32
        if args.json?
          print_json do |json|
            json.object do
              json.field "ok", true
              json.field "message", message
              json.field "path", outcome.path.to_s
              json.field "written", outcome.written.to_s
              extra.call(json)
            end
          end
        else
          STDOUT.puts message
          STDOUT.puts "  wrote #{outcome.written}" if outcome.written != outcome.path.expand
        end
        ExitCode::OK
      end

      def report_mutation(args : Args, outcome : Config::Mutation::Outcome, message : String) : Int32
        report_mutation(args, outcome, message) { }
      end

      # A command that needs what does not exist yet: its help works, and
      # running it fails saying so.
      def not_built(args : Args, help : String, message : String) : Int32
        help(args, help).try { |code| return code }
        raise Error.new(message)
      end
    end
  end
end
