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
              json.field("reload") { reloads_json(json, outcome.reloads) }
              extra.call(json)
            end
          end
        else
          STDOUT.puts message
          STDOUT.puts "  wrote #{outcome.written}" if outcome.written != outcome.path.expand
          print_reloads(outcome.reloads)
        end
        ExitCode::OK
      end

      # Each site's reload, keyed by site; an app that is not running says
      # nothing in text, since it loads the config when it starts.
      def reloads_json(json : JSON::Builder, reloads : Array(SocketClient::ReloadOutcome)) : Nil
        json.object { reloads.each { |reload| json.field reload.site, reload } }
      end

      def print_reloads(reloads : Array(SocketClient::ReloadOutcome)) : Nil
        reloads.each { |reload| reload.summary.try { |line| STDOUT.puts "  #{line}" } }
      end

      def report_mutation(args : Args, outcome : Config::Mutation::Outcome, message : String) : Int32
        report_mutation(args, outcome, message) { }
      end

      # A child's exit code to pass on: 128 plus the signal when a signal
      # ended it, as a shell reports it.
      def exit_code_for(status : Process::Status) : Int32
        status.exit_code? || status.exit_signal?.try { |signal| 128 + signal.value } || ExitCode::FAILED
      end
    end
  end
end
