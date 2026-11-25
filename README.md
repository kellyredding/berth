<h1 align="center">
  <img src="BerthApp/BerthApp/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" height="128" alt=""><br>
  Berth
</h1>

Web pages as standalone Mac apps, with a CLI built for agents.

Berth turns a page such as webmail or a calendar into its own signed Mac app:
its own Dock icon, window, cookies and bundle identifier, which stays open
whatever your browser does. Links to other sites open in your default browser;
copy and paste, find, zoom, downloads and printing work as in Safari. A site
can badge its Dock tile from the page title, show the page's notifications,
handle `mailto:` links, and sign in from 1Password.

## Parts

- **Berth.app** (`BerthApp/`): one WebKit shell, released as a signed
  template. Each site app is a copy of it, stamped with the site's name,
  bundle identifier and icon and signed with the same identity.
- **`berth`** (`tools/berth/`): the CLI. It is the only reader and writer of
  the config, builds and signs the site apps, and talks to a running one over
  its Unix socket.

`docs/contract.md` is everything the two must agree on.

## Install

macOS 15 or later, on Apple Silicon or Intel:

```bash
curl -fsSL https://raw.githubusercontent.com/kellyredding/berth/main/install.sh | bash
```

Use the script, not a browser download: the apps are self-signed, and a
download through a browser is quarantined. It installs the CLI at
`~/.berth/bin/berth` (linked onto `~/.local/bin`), the template app at
`~/.berth/template/Berth.app` and its signing script, and never touches your
config, `~/Applications` or a site app.

## Building your site apps

Each site in your config becomes its own app, copied from the template and
signed with the Berth release identity, which lives in 1Password:

```bash
export BERTH_SIGNING_OP_ACCOUNT='<account>.1password.com'   # in your shell profile
export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'
berth sites build --all
```

One 1Password approval covers every app in the build. A site app keeps one
signature across rebuilds, so macOS keeps its notification permission and
login item. A running app keeps its old build until you restart it.

## Update

```bash
berth update            # the latest release, then every site app rebuilt
berth update --preview  # what would change
```

`--version X.Y.Z` installs that release, `--no-sites` skips the rebuild, and
`--local [PATH]` packages and installs a Berth checkout. Without the two
signing variables the update still installs, and says to set them and run
`berth sites build --all`. `berth doctor` checks the install: the CLI and the
template against the install record, and whether each site app was built from
the installed template.

## Config

`~/.berth/config.json`, or `BERTH_CONFIG`. It may be a symlink, for example
into a private dotfiles repository, and edits replace the file it points to,
never the link. Without a config file Berth uses `config/starter.json`;
`berth config init --starter` writes it out to edit.

```json
{
  "version": 1,
  "sites": {
    "mail": {
      "name": "Mail",
      "url": "https://mail.example.com/",
      "keep": ["mail.example.com", "accounts.example.com"],
      "icon": "icons/mail.png",
      "badge": {"title": "\\((\\d+)\\)"},
      "handles": ["mailto"],
      "mailto": "https://mail.example.com/compose?to=%s",
      "notifications": true
    }
  }
}
```

Each site becomes `~/Applications/<name>.app`. `keep` lists the hosts whose
links stay in the app when clicked (exact, or `*.example.com` for any
subdomain); redirects and form posts stay wherever they go, so a sign-in
through other hosts finishes in the app; `icon` is
a PNG beside the config; `badge.title` is a regular expression whose one
capture group, found in the page title, becomes the Dock badge. `signin` names
logins whose steps fill a sign-in page from 1Password items: from the app's
File → Sign In with 1Password (⇧⌘L), from the bar it shows above a sign-in
page, or with `berth signin SITE` in a terminal. The bar follows each step
of the sign-in, whichever started it.

```bash
berth sites list
berth sites add docs --name Docs --url https://docs.example.com/
berth sites set mail --keep mail.example.com,accounts.example.com --notifications on
berth config validate
```

Every command except `update` takes `--json`. The file is strict JSON; edit
it with the CLI, or by hand followed by `berth config validate`.
`docs/contract.md` has every key and rule.

## Development

```bash
make check       # disclosure audit, then the CLI gate: lint, build, specs
make app-check   # app gate: build and the smoke check
```

`make check` does not build the app; a change touching both needs both.

The repository is public, so `make audit` (run first by `make check`)
refuses personal details in tracked files: structural patterns, plus a list
of your own terms kept outside the repository in `~/.berth/denylist.txt` (or
`BERTH_DENYLIST`), one per line. On a fresh clone without one,
`BERTH_ALLOW_NO_DENYLIST=1 make check` runs the structural checks alone.

Signing reads the identity from 1Password through two variables you set in
your own shell profile, `BERTH_SIGNING_OP_ACCOUNT` (the account's sign-in
address or ID) and `BERTH_SIGNING_OP_ITEM` (`op://<vault>/<item>`). Berth
has no defaults for them; see `docs/contract.md`.

`bin/package` builds the release archive (the CLI, the template and the
signing script), `bin/release` publishes it from `main`, and `release-notes/`
holds each version's notes.

## License

MIT
