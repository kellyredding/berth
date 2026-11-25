require "../spec_helper"

private alias Update = Berth::Commands::Update

# Stand-ins for the network: `curl` prints its arguments to stderr and
# answers with the given installer script, or exits 22 as `curl -f` does on
# an HTTP error.
private def fake_curl(sandbox : SpecHelper::Sandbox, installer : String?) : Hash(String, String?)
  bin = sandbox.root / "fakebin"
  body = if installer
           "#!/bin/sh\necho \"curl $*\" >&2\ncat <<'EOF'\n#{installer}\nEOF\n"
         else
           "#!/bin/sh\necho \"curl: (22) The requested URL returned error: 404\" >&2\nexit 22\n"
         end
  SpecHelper.write_executable(bin / "curl", body)
  {"PATH" => "#{bin}:/usr/bin:/bin"} of String => String?
end

# An installer that installs: it writes a new CLI, which records how it is
# run and exits FAKE_BUILD_EXIT, and a new install record.
private INSTALLS = <<-SH
  echo "installer $*"
  echo "from update: ${BERTH_INSTALL_FROM_UPDATE:-no}"
  mkdir -p "$BERTH_ROOT/bin"
  printf '#!/bin/sh\\necho "new berth $*"\\nexit ${FAKE_BUILD_EXIT:-0}\\n' > "$BERTH_ROOT/bin/berth"
  chmod 755 "$BERTH_ROOT/bin/berth"
  echo '{"commit": "new"}' > "$BERTH_ROOT/installed-manifest.json"
  SH

private PACKAGE = <<-SH
  #!/bin/sh
  echo "package $*"
  while [ $# -gt 0 ]; do
    case "$1" in --out) out="$2"; shift ;; esac
    shift
  done
  mkdir -p "$out"
  echo archive > "$out/berth-darwin.tar.gz"

  SH

private INSTALL = <<-SH
  #!/bin/sh
  echo "install.sh $*"
  [ -f "$2" ] && echo "archive present"
  exit 0

  SH

describe "berth update" do
  it "runs the installer from main with install.sh's own flags, and rebuilds nothing on --preview" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "installer $*"\necho "root $BERTH_ROOT"))
      result = SpecHelper.run(sandbox, ["update", "--version", "v0.2.0", "--preview", "--force"], env)
      result.exit_code.should eq(0), result.stderr
      result.stderr.should contain("curl -fsSL #{Update::INSTALL_SCRIPT_URL}\n")
      result.stdout.should eq("installer --version 0.2.0 --preview --force\nroot #{sandbox.root}\n")
      result.stderr.should_not contain("sites build")
    end
  end

  it "installs the latest release, then rebuilds every site app with the newly installed CLI" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["update"], fake_curl(sandbox, INSTALLS))
      result.exit_code.should eq(0), result.stderr
      result.stdout.should eq("installer \nfrom update: 1\nnew berth sites build --all\n")
      result.stderr.should contain("Rebuilding every site app from the new template with " \
                                   "#{sandbox.root}/bin/berth sites build --all")
    end
  end

  it "exits with the new CLI's build exit code when the rebuild fails" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["update"], fake_curl(sandbox, INSTALLS).merge({"FAKE_BUILD_EXIT" => "4"}))
      result.exit_code.should eq(4)
      result.stdout.should contain("new berth sites build --all\n")
    end
  end

  it "--no-sites installs and leaves the site apps alone, letting install.sh give its advice" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["update", "--no-sites"], fake_curl(sandbox, INSTALLS))
      result.exit_code.should eq(0)
      result.stdout.should eq("installer \nfrom update: no\n")
      result.stderr.should contain("site apps not rebuilt (--no-sites); rebuild them with `berth sites build --all`")
    end
  end

  it "finishes the install without the signing variables, never signing ad hoc, and says how to rebuild" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, INSTALLS).merge({"BERTH_SIGNING_OP_ACCOUNT" => nil, "BERTH_SIGNING_OP_ITEM" => ""})
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(0)
      result.stdout.should_not contain("new berth")
      result.stderr.should contain("installed, but site apps were not rebuilt: signing them needs the Berth release " \
                                   "identity from 1Password, named by BERTH_SIGNING_OP_ACCOUNT and BERTH_SIGNING_OP_ITEM")
      result.stderr.should contain("export BERTH_SIGNING_OP_ACCOUNT='<account>.1password.com'")
      result.stderr.should contain("export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'")
      result.stderr.should contain("Set them in your shell profile, then run `berth sites build --all`.")
    end
  end

  it "rebuilds nothing when the installer installed nothing, or the config has no sites" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "Berth is up to date"))
      SpecHelper.write_install(sandbox)
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(0)
      result.stdout.should eq("Berth is up to date\n")
      result.stderr.should contain("nothing was installed, so site apps were not rebuilt")

      sandbox.write_config(%({"version": 1, "sites": {}}))
      empty = SpecHelper.run(sandbox, ["update"], fake_curl(sandbox, INSTALLS))
      empty.exit_code.should eq(0)
      empty.stdout.should_not contain("new berth")
      empty.stderr.should contain("the config has no sites, so there are no site apps to rebuild")
    end
  end

  it "exits with the installer's exit code, rebuilding nothing" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "no release" >&2\nexit 7))
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(7)
      result.stderr.should contain("no release")
      result.stderr.should_not contain("Rebuilding")
    end
  end

  it "fails, running nothing, when the installer does not download" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, nil)
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(1)
      result.stdout.should be_empty
      result.stderr.should contain("berth: could not download the installer from #{Update::INSTALL_SCRIPT_URL} (exit 22)")
    end
  end

  it "--local packages the checkout it is run from and installs the archive with its install.sh" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: INSTALL)
      result = SpecHelper.run(sandbox, ["update", "--local", "--preview"], chdir: (root / "tools").to_s)
      result.exit_code.should eq(0), result.stderr

      out_dir = result.stdout[/^package --local --out (\S+)$/m, 1]
      archive = "#{out_dir}/berth-darwin.tar.gz"
      result.stdout.should contain("install.sh --from #{archive} --preview\narchive present\n")
      Dir.exists?(out_dir).should be_false
    end
  end

  it "--local PATH packages that checkout, installs it and rebuilds the site apps" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: "#!/bin/sh\n#{INSTALLS}\n")
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(0), result.stderr
      result.stdout.should contain("installer --from ")
      result.stdout.should contain("from update: 1\nnew berth sites build --all\n")
    end
  end

  it "--local refuses a directory that is not a Berth checkout" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: INSTALL, berth: false)
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(1)
      result.stdout.should be_empty
      result.stderr.should contain("#{root} is not inside a Berth checkout")
    end
  end

  it "--local stops with the packager's exit code, or 128 + its signal, before installing" do
    SpecHelper.sandbox do |sandbox|
      {"exit 2" => 2, "kill -TERM $$" => 128 + Signal::TERM.value}.each do |ending, code|
        root = SpecHelper.checkout(sandbox, package: "#!/bin/sh\n#{ending}\n", install: INSTALL)
        result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
        result.exit_code.should eq(code)
        result.stdout.should_not contain("install.sh")
      end
    end
  end

  it "--local fails when the packager writes no archive" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: "#!/bin/sh\nexit 0\n", install: INSTALL)
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(1)
      result.stderr.should contain("bin/package wrote no berth-darwin.tar.gz")
      result.stdout.should_not contain("install.sh")
    end
  end

  it "exits 2 on a usage error, and documents its flags" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["update", "--local", "--version", "0.1.0"]).exit_code.should eq(2)
      SpecHelper.run(sandbox, ["update", "--json"]).json["code"].should eq("usage")

      help = SpecHelper.run(sandbox, ["update", "--help"])
      help.exit_code.should eq(0)
      help.stdout.should contain("berth update --local [PATH]")
      help.stdout.should contain("--no-sites")
      help.stdout.should contain("a running one keeps its old build until you\nrestart it")
    end
  end
end

describe Berth::Commands::Update do
  it "parses its options, refusing bad combinations" do
    Update.parse([] of String).should eq(Update::Options.new)
    Update.parse(["--local", "~/src/berth"]).local_path.should eq("~/src/berth")
    Update.parse(["--version", "v0.1.0"]).version.should eq("0.1.0")
    Update.parse(["--no-sites"]).sites.should be_false
    expect_raises(Berth::UsageError, /--version needs a version like 0\.1\.0/) { Update.parse(["--version", "latest"]) }
    expect_raises(Berth::UsageError, /cannot be combined/) { Update.parse(["--local", "--version", "0.1.0"]) }
    expect_raises(Berth::UsageError, /goes with --local/) { Update.parse(["../berth"]) }
    expect_raises(Berth::UsageError, /no --json output/) { Update.parse(["--json"]) }
  end

  it "spells options the way install.sh reads them" do
    options = Update.parse(["--version", "0.1.0", "--preview", "--force", "--no-sites"])
    Update.install_args(options).should eq(["--version", "0.1.0", "--preview", "--force"])
  end

  it "finds a Berth checkout's root from inside it, and nothing elsewhere" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox)
      Update.resolve_repo(nil, (root / "tools").to_s).should eq(root)
      Update.resolve_repo("checkout", sandbox.root.to_s).should eq(root)
      Update.resolve_repo("missing", sandbox.root.to_s).should be_nil
    end
  end
end

describe "Berth::Commands::Support.exit_code_for" do
  it "passes an exit code on, and reports a signal as 128 + the signal" do
    Berth::Commands::Support.exit_code_for(Process.run("sh", ["-c", "exit 7"])).should eq(7)
    signalled = Process.run("sh", ["-c", "kill -TERM $$"])
    Berth::Commands::Support.exit_code_for(signalled).should eq(128 + Signal::TERM.value)
  end
end
