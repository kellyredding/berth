module Berth
  module Commands
    # The commands that need what does not exist yet: a release. Each parses
    # the options it will take, so its usage is settled, then says it is not
    # built yet.
    module Update
      extend self

      HELP = <<-TEXT
        berth update [--version X.Y.Z | --local [PATH]] [--preview] [--force]

        Not built yet: updates arrive with release packaging.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv, values: ["--version"], switches: ["--local", "--preview", "--force"])
        Support.not_built(args, HELP, "update is not built yet: updates arrive with release packaging, which does not exist yet")
      end
    end
  end
end
