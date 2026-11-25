# berth

The command-line half of Berth. It is the only reader and writer of the sites
config, and the client agents use to build, open and sign in to site apps.
`docs/contract.md` at the repository root is the contract between the CLI and
the app.

## Building

```bash
make check   # lint + dev build + specs (the specs run the dev binary)
make dev     # build/berth, unoptimized
make build   # build/berth, release
make install # check, build, copy to ~/.berth/bin/berth, link onto ~/.local/bin
```

The version comes from the repository's `VERSION` file and the starter
config from `config/starter.json`, both read at compile time. The binary
links only system libraries: nothing here may require `digest` or `openssl`,
which load Homebrew's libcrypto.

## Commands

Every command except `update` takes `--json`. On failure the message goes to
stderr, and with `--json` the failure is also printed on stdout as
`{"ok": false, "error", "code", …}`.

**Config** (no app needed): `sites list|show|add|set|remove`,
`config path|show|validate|export|init`. `sites add SITE --name NAME --url
URL` adds a site; `sites set` changes any key, and its `--no-…` options put a
key back to its default. A sign-in login is set with `--login NAME --steps
JSON` and removed with `--remove-login NAME`. `config export --json [--site
SITE]` is what a site app loads.

**Site apps:** `status` reports, for every site, whether its app is built and
running, and a running app's page title and Dock badge. `open SITE [URL]`
brings a running app forward and loads `URL` in it (or in the default browser
when the site does not keep its host), and otherwise launches the built app
with `open -a`. Each running app talks over its own Unix socket
(`<runtime>/<site>.sock`); after every config write the CLI asks each running
app to reload, and says so only for the apps that answered.

**Signing in:** `signin SITE [--account NAME]` reads the login's steps from
1Password with `op` (each step may name its 1Password account) and has the
site's running app fill each sign-in page, waiting up to two minutes for a
push you approve. It prints the steps completed, or where the app stopped
and why. The app must be running (`berth open SITE`; exit 3 otherwise); a
declined 1Password approval exits 4. Values travel from op's stdout to the
app's socket and nowhere else: not argv, output, `--json` or a log. A site
app runs this same command, with `--account` and `--json`, when you sign in
from inside it (File → Sign In with 1Password, or its sign-in bar), and
reads the outcome from the exit code and the JSON.

**Building site apps:** `sites build [SITE…|--all] [--template PATH] [--sign
op|adhoc] [--preview]` copies the template (`~/.berth/template/Berth.app`, or
`--template`) to `~/Applications/NAME.app` for each site, stamps its
`Info.plist` and icon, signs every copy in one session, then swaps each in by
rename and registers it with Launch Services. `--sign op`, the default, signs
with the release identity from 1Password, one approval for the whole build;
`--sign adhoc` is for development, and warns that macOS may forget an ad-hoc
app's permissions. `--preview` prints the plan and changes nothing. It
refuses a missing template, an unknown site (exit 5), and anything at a
destination that is not that site's Berth app, changing nothing; a link
there is replaced, never its target. It never launches, quits or restarts an
app: a running one keeps its old build until restarted. In a checkout:

```bash
make -C BerthApp release
berth sites build docs --template BerthApp/build/Build/Products/Release/Berth.app
```

The signing script is `bin/lib/sign-app.sh`. A CLI built in a checkout runs
the checkout's copy; an installed one runs `~/.berth/libexec/sign-app.sh`;
`BERTH_SIGN_SCRIPT` overrides both.

`--sign op` needs two variables naming where the identity lives in
1Password. Set them in your own shell profile; Berth has no defaults:

```bash
export BERTH_SIGNING_OP_ACCOUNT='<account>.1password.com'   # sign-in address or account ID
export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'          # the identity's item
```

Without either, or with an item that is not `op://VAULT/ITEM`, the build
refuses (exit 2) before copying anything. `--sign adhoc` needs neither.

**Health:** `doctor` checks the config and, for each site, its app: built and
stamped for the site, signed by the release certificate, Berth Release
Signing (ad hoc warns), known to Launch Services (another registered copy,
or a development build, warns), and running. The install record and template checks are not built yet.
`version`; `update` is not built yet.

Run `berth <command> --help` for each command's options.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failed, including an invalid config or a refused change |
| 2 | Usage error |
| 3 | The site's app is not running |
| 4 | Not permitted |
| 5 | No such site or login, or the site's app is not built |

## Config changes

The config is a JSON file. Commands that change it load it (the built-in
starter when no file exists), apply the change, validate the whole result,
and refuse an invalid one without writing anything. A valid result is
written back as JSON: two-space indent, `version` before `sites`, a site's
keys in canonical order when added and in their existing order otherwise.
After editing the file by hand, run `berth config validate`.

Writes are symlink-safe: when the config path is a symlink, the file it
points to is replaced (temp file beside it, then a rename), and the link
stays a link. A site's relative `icon` is found from that real file's
directory.

## Paths

| Path | Default | Override |
|---|---|---|
| Root | `~/.berth` | `BERTH_ROOT` |
| Config | `<root>/config.json` | `BERTH_CONFIG` |
| Runtime dir | `<root>/runtime` | `BERTH_RUNTIME_DIR` |
| CLI binary | `<root>/bin/berth` | `BERTH_BINARY` |
| Site apps | `~/Applications` | `BERTH_APPLICATIONS_DIR` |
| The program that launches an app | `/usr/bin/open` | `BERTH_OPEN` |
| 1Password's CLI | `op` on `PATH` | `BERTH_OP` |
| Signing script | the checkout's `bin/lib/sign-app.sh`, else `<root>/libexec/sign-app.sh` | `BERTH_SIGN_SCRIPT` |
| `codesign`, `sips`, `iconutil`, `lsregister` | the system's | `BERTH_CODESIGN`, `BERTH_SIPS`, `BERTH_ICONUTIL`, `BERTH_LSREGISTER` |

Specs point all of these at temporary directories and stand-ins, and never
touch `~/.berth`, `~/Applications` or the Launch Services database.
