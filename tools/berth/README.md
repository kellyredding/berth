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
app to reload, and says so only for the apps that answered. `sites build` and
`signin` are not built yet: each parses its options and exits 1 saying so.

**Health:** `doctor` checks the config; install, template and site-app checks
are not built yet. `version`; `update` is not built yet.

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

Specs point all of these at temporary directories and never touch `~/.berth`
or `~/Applications`.
