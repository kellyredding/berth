module Berth
  module Commands
    # The commands that need a site app, 1Password or a release. Each parses
    # the options it will take, so its usage is settled, then says it is not
    # built yet.
    module Status
      extend self

      HELP = <<-TEXT
        berth status — every site: whether its app is built and running, and its version

        Not built yet: it needs the Berth app, which does not exist yet.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv)
        Support.not_built(args, HELP, "status is not built yet: it needs the Berth app, which does not exist yet")
      end
    end

    module Open
      extend self

      HELP = <<-TEXT
        berth open SITE [URL] — launch or focus a site's app, and load URL in it

        Not built yet: it needs the Berth app, which does not exist yet.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv)
        Support.not_built(args, HELP, "open is not built yet: it needs the Berth app, which does not exist yet")
      end
    end

    module Signin
      extend self

      HELP = <<-TEXT
        berth signin SITE [--account NAME] — fill a site app's sign-in from 1Password

        Not built yet: it needs the Berth app, which does not exist yet.
        TEXT

      def run(argv : Array(String)) : Int32
        args = Args.parse(argv, values: ["--account"])
        Support.not_built(args, HELP, "signin is not built yet: it needs the Berth app, which does not exist yet")
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
