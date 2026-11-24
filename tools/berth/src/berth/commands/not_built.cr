module Berth
  module Commands
    # The commands that need what does not exist yet: the app's sign-in
    # filling, or a release. Each parses the options it will take, so its
    # usage is settled, then says it is not built yet.
    module Signin
      extend self

      HELP = <<-TEXT
        berth signin SITE [--account NAME] — fill a site app's sign-in from 1Password

        Not built yet: the site apps cannot fill a sign-in yet.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv, values: ["--account"])
        Support.not_built(args, HELP, "signin is not built yet: the site apps cannot fill a sign-in yet")
      end
    end

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
