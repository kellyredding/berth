# The CLI ↔ app contract

Berth is two programs: the Crystal CLI (`tools/berth/`) and the Swift shell
app (`BerthApp/`), copied once per configured site into a separate, signed
site app. They share no code, so everything they must agree on is written
down here. Changing any section means changing both sides in the same commit.

| Section | Crystal | Swift |
|---|---|---|
| Paths | `tools/berth/src/berth/paths.cr` | `BerthApp/BerthApp/Models/Paths.swift` |
| Config export | `tools/berth/src/berth/config/export.cr` | `BerthApp/BerthApp/Models/SiteConfig.swift` |
| Socket envelope and events | `tools/berth/src/berth/socket_client.cr` | `BerthApp/BerthApp/Models/Envelope.swift` |

`fixtures/config.json` and `fixtures/export.json` pin the export shape for
both sides: the CLI specs assert that exporting the config yields the JSON
(compared as values, ignoring `path`, with the fixtures directory written as
`fixtures/` in `icon`), and the app's smoke check decodes the JSON. A drift
on either side fails a check. Neither side edits the fixtures to make its own
check pass; a mismatch means the contract changes first.

## Division of labour

- **The app is the actor.** Each site app shows its site in a WebKit view,
  keeps it signed in, decides which links stay in the app, badges its Dock
  tile, forwards notifications, handles the URL schemes it claims, and fills
  sign-in forms it is sent, which it may ask for itself by running `berth
  signin` ("What the app runs"). It never reads or writes the config file
  itself, or 1Password.
- **The CLI is the client, and the only reader and writer of the config.** A
  site app gets its site's resolved config by running
  `berth config export --site SITE --json`. The CLI builds, signs and
  installs site apps, reads 1Password, and reaches a running site app over
  that app's socket.
- **One template, many apps.** A release ships one signed template,
  `Berth.app`. A site app is a copy of it whose `Info.plist` names its site
  (`BerthSite`), with the bundle identifier `com.kellyredding.berth.<site>`
  and the site's `name`, icon and URL schemes.
- **Which site an app shows:** `BerthSite` in its own `Info.plist`, else the
  `BERTH_SITE` environment variable (how development runs a site from the
  template's build), else none: the template only says that it must be built
  per site with `berth sites build`.

## Paths

Every path can be overridden by an environment variable, so specs and checks
run against temporary directories.

| Path | Default | Override |
|---|---|---|
| Root | `~/.berth` | `BERTH_ROOT` |
| Config | `<root>/config.json` | `BERTH_CONFIG` |
| Runtime dir | `<root>/runtime` | `BERTH_RUNTIME_DIR` |
| A site app's socket | `<runtime>/<site>.sock` | — |
| A site app's log | `<runtime>/logs/<site>.log` | — |
| CLI binary (for the apps) | `<root>/bin/berth`, then `~/.local/bin/berth` | `BERTH_BINARY` (the only one tried when set) |
| Template app | `<root>/template/Berth.app` | — |
| Install record | `<root>/installed-manifest.json` | — |
| Site apps | `~/Applications/<name>.app` | `BERTH_APPLICATIONS_DIR` (the directory) |
| The program `berth open` launches an app with | `/usr/bin/open` | `BERTH_OPEN` (specs) |
| 1Password's CLI, which `berth signin` reads with | `op` on `PATH` | `BERTH_OP` (specs) |
| The signing script `berth sites build` runs | `<checkout>/bin/lib/sign-app.sh` for a CLI built in a checkout (`tools/berth/build/berth`), else `<root>/libexec/sign-app.sh` | `BERTH_SIGN_SCRIPT` (the only one tried when set) |
| `codesign`, `sips`, `iconutil` | `/usr/bin/…` | `BERTH_CODESIGN`, `BERTH_SIPS`, `BERTH_ICONUTIL` (specs) |
| `lsregister` | Launch Services' own, in `CoreServices.framework` | `BERTH_LSREGISTER` (specs) |

A site app runs the CLI with its own environment, so the `BERTH_*`
overrides it was given reach the CLI too, except `PATH`:
`/opt/homebrew/bin:/usr/local/bin`, then the app's own `PATH`, then
`/usr/bin:/bin:/usr/sbin:/sbin`, each directory once. An app opened from the
Dock has launchd's minimal `PATH`, and `berth signin` runs `op` from `PATH`.

The last three rows are the CLI's alone; the app never builds or signs.
The template is never registered with Launch Services or launched. Each site
app creates the runtime directories it needs; the CLI never assumes they
exist.

The config path may be a symlink (into a private dotfiles repository, say).
Every write resolves the link and replaces the real file, never the link: a
temp file written beside the real file, then renamed over it. Renaming over
the link path itself would replace the link with a regular file.

## Site apps (`berth sites build`)

The template is a Berth template when its `CFBundleIdentifier` is
`com.kellyredding.berth` and it has no `BerthSite`; the CLI refuses anything
else. It copies the template to a hidden staging path beside the site's app
(`.<name>.app.berth-new`) and stamps the copy's `Info.plist`:

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `com.kellyredding.berth.<site>` |
| `CFBundleName`, `CFBundleDisplayName` | The site's `name`; the app takes its menu name from `CFBundleName` |
| `BerthSite` | The site; the app shows the site it names |
| `CFBundleURLTypes` | One entry, `CFBundleURLName` the bundle identifier and `CFBundleURLSchemes` the site's `handles`; removed when `handles` is empty |
| `CFBundleIconFile` | `SiteIcon`, for `Contents/Resources/SiteIcon.icns` made from the site's `icon` (a full iconset, 16 to 1024 px), with `CFBundleIconName` removed so the template's asset-catalog icon does not win; untouched when the site has no icon |

Every other key is the template's, `CFBundleShortVersionString`,
`CFBundleVersion` and `BerthBuildCommit` among them.

Then the CLI signs every copy in the build in one run of the signing script
(`sign-app.sh op|adhoc PATH…`), so the release identity costs one 1Password
approval; the script exits 4 when 1Password does not provide it. Each copy
must pass `codesign --verify --strict`, carry its bundle identifier as its
`Identifier`, and have `Berth Release Signing`, the release certificate's
common name, as its `Authority` (or be ad hoc with `--sign adhoc`).

`--sign op` finds the identity in 1Password through two environment
variables, which the signing script inherits from the CLI. Both are
required and neither has a default: the repository names no 1Password
account, vault or item. A maintainer sets them in their own shell profile.

| Variable | Value |
|---|---|
| `BERTH_SIGNING_OP_ACCOUNT` | The account holding the identity: its sign-in address or account ID, passed to `op --account` |
| `BERTH_SIGNING_OP_ITEM` | The identity's item, `op://VAULT/ITEM`; the script reads its `signing/p12`, `password` and `sha1` fields |

When either is unset or empty, or the item is not `op://VAULT/ITEM`, the CLI
refuses before copying anything (exit 2), naming each variable with an
example (`export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'`), and so does
`sign-app.sh op` run on its own. `--sign adhoc` and every other command need
neither. `bin/signing-identity create|show` reads the same two, taking the
vault and the new item's title from `BERTH_SIGNING_OP_ITEM`. Only then is each moved into place by rename, and
registered with `lsregister -f`; every `*/Build/Products/*/Berth.app`
registered is unregistered.

- **What may be replaced:** nothing, a symbolic link (the link is removed,
  never its target), or this site's own app: a directory whose `BerthSite` is
  the site and whose `CFBundleIdentifier` starts with
  `com.kellyredding.berth.`. Anything else at any destination refuses the
  whole build before anything changes.
- **A running app** keeps its old build until it is restarted. The CLI never
  launches, quits or restarts one.

Because a site app keeps the template's `BerthBuildCommit`, it names the
template it was copied from; `berth doctor` compares that with the installed
template's ("Releases and installs").

## Releases and installs

### The archive

`bin/package` writes `berth-darwin.tar.gz` and its
`berth-darwin.tar.gz.sha256` (`shasum -a 256` output). The archive holds
one directory, `berth/`:

| Path | What |
|---|---|
| `bin/berth` | The CLI, a universal (`arm64` and `x86_64`) release build that links only `/usr/lib` libraries (`otool -L`), built for macOS 15 and later, signed with the identifier `com.kellyredding.berth-cli` |
| `Berth.app` | The template: a universal Release build for macOS 15 and later, bundle identifier `com.kellyredding.berth`, no `BerthSite`, stamped with `CFBundleShortVersionString` (from `VERSION`), `BerthBuildCommit`, `BerthBuildDirty` and `BerthBuiltAt` |
| `libexec/sign-app.sh` | `bin/lib/sign-app.sh`, which an installed `berth sites build` runs |
| `manifest.json` | The build record, below |
| `VERSION` | The version |

Both `bin/berth` and `Berth.app` are signed by the release certificate,
`Berth Release Signing` (`--sign op`, the default). `--sign adhoc` is allowed
only with `--local`, to check packaging; `install.sh` refuses its archive.

`manifest.json`, one key per line:

```json
{
  "version": "0.1.0",
  "commit": "0123456789ab",
  "dirty": false,
  "built_at": "2026-01-02T03:04:05Z",
  "signing": "op",
  "signer": "Berth Release Signing",
  "berth_sha256": "…"
}
```

`commit` is the 12-character commit the template's `BerthBuildCommit` also
holds; `dirty` is whether the tree had uncommitted changes (`--local` only);
`signer` is the certificate's common name, or `ad hoc`; `berth_sha256` is
`bin/berth`'s checksum. It names no 1Password account, vault or item.

### `install.sh`

Run as `curl -fsSL …/main/install.sh | bash`, or by `berth update`, with
`--version X.Y.Z`, `--from ARCHIVE`, `--preview` or `--force`. It is one
`{ … }` block, so a truncated download runs none of it.

1. Refuses anything but macOS 15 or later.
2. Downloads the latest release's archive and checksum with `curl` (no
   quarantine flag), or `--version`'s, or copies `--from ARCHIVE` and its
   `ARCHIVE.sha256`, rewriting the file name in the checksum so an archive
   saved under another name still verifies. A checksum mismatch installs
   nothing.
3. Refuses an archive whose `Berth.app` or `bin/berth` does not verify or is
   not signed by `Berth Release Signing`, or whose `Berth.app` is not the
   template, before anything is replaced.
4. A release whose `commit` is the install record's, clean, is up to date
   unless `--force`; `--from` always installs.
5. Installs, under the root (`BERTH_ROOT`, else `~/.berth`):

| Path | What |
|---|---|
| `<root>/bin/berth` | The CLI, moved into place over the old one; `~/.local/bin/berth` links to it |
| `<root>/template/Berth.app` | The template, staged beside it as `.Berth.app.berth-new` and swapped in by rename; a link there is removed, never its target |
| `<root>/libexec/sign-app.sh` | The signing script |
| `<root>/installed-manifest.json` | The archive's `manifest.json`, written last, so a record names only an install that finished |

The template is never registered with Launch Services: any registration of
it, or of anything beside it, is removed (`lsregister -u`; `BERTH_LSREGISTER`
overrides the tool). It never touches the config, the denylist,
`~/Applications` or any site app, and never launches or quits anything. It
ends by saying that site apps are rebuilt from the new template with `berth
sites build --all` (signing needs `BERTH_SIGNING_OP_ACCOUNT`,
`BERTH_SIGNING_OP_ITEM` and one 1Password approval) and that running site
apps keep their old build until restarted; `berth update`, which rebuilds them
itself, sets `BERTH_INSTALL_FROM_UPDATE` to leave out the first part.

### `berth update [--version X.Y.Z | --local [PATH]] [--preview] [--force] [--no-sites]`

- A release: downloads `install.sh` from `main` into memory with `curl`, and
  runs it with `bash -s --` only if the download succeeded (piped straight
  into bash, a failed download would be an empty script that exits 0).
- `--local [PATH]`: the Berth checkout at `PATH`, else the one the working
  directory is in (it has `bin/package`, `install.sh` and
  `BerthApp/project.yml`): its `bin/package --local --out TMP`, which signs
  with the release identity, then its `install.sh --from TMP/<archive>`.
- An installer or packager that fails ends the update with its exit code (128
  plus the signal when one ended it).
- Then, unless `--preview` or `--no-sites`, when the install record changed
  and the config has sites: the newly installed CLI, `<root>/bin/berth`, runs
  `sites build --all` as a child, and its exit code is the update's. Without
  the two signing variables it builds nothing, exits 0, and says to set them
  and run `berth sites build --all`; it never signs ad hoc. It never restarts
  a site app; the build names each running one, which keeps its old build.
- It has no `--json` output.

### `berth doctor`'s install checks

With an install record (none, as in a checkout, is a warning):

| Check | Fails when |
|---|---|
| `install` | — (reports version, commit, build time, signer) |
| `installed cli` | `<root>/bin/berth` is missing or its `/usr/bin/shasum` checksum is not `berth_sha256` (a record without one warns) |
| `template` | `<root>/template/Berth.app` is missing, a link, not the template, or its `BerthBuildCommit` is missing or not the record's `commit` |
| `template signer` | Its signature does not verify, is ad hoc, or is not the record's `signer` |
| `template registered` | Warns for each registration of the template, or of anything beside it |
| `sign script` | `<root>/libexec/sign-app.sh` is missing or not executable |
| `SITE build` | Warns when a built site app's `BerthBuildCommit` is not the installed template's: rebuild with `berth sites build --all` |

## Config file (JSON, read and written only by the CLI)

```json
{
  "version": 1,
  "sites": {
    "mail": {
      "name": "Mail",
      "url": "https://mail.example.com/",
      "keep": ["mail.example.com", "accounts.example.com", "*.sso.example.com"],
      "icon": "icons/mail.png",
      "badge": {
        "title": "\\((\\d+)\\)"
      },
      "handles": ["mailto"],
      "mailto": "https://mail.example.com/compose?to=%s",
      "notifications": true,
      "launch_at_login": true,
      "signin": {
        "personal": [
          {"flow": "google", "item": "op://Personal/Example Mail"}
        ],
        "work": [
          {"flow": "google", "email_from": "op://Work/Example SSO", "account": "example.1password.com"},
          {"flow": "okta", "item": "op://Work/Example SSO", "account": "example.1password.com", "method": "Example Authenticator"}
        ]
      }
    }
  }
}
```

Each key of `sites` is a **site**: the name the CLI and the app use for it
(`berth open mail`), its socket's name, and the last part of its app's
bundle identifier (`com.kellyredding.berth.mail`).

| Key | Required | Default | Value |
|---|---|---|---|
| `name` | yes | — | The display name, and the app's file name: `~/Applications/Mail.app` |
| `url` | yes | — | The page the app opens: an `https` URL |
| `keep` | no | the `url`'s host | Hosts whose pages stay in the app |
| `icon` | no | none (the template's icon) | A PNG file |
| `badge.title` | no | no badge | A regular expression whose one capture group, matched against the page title, is the Dock badge |
| `handles` | no | `[]` | URL schemes the app handles: `mailto` |
| `mailto` | when `handles` has `mailto` | none | The URL a `mailto:` link opens, with `%s` where the link goes ("`mailto:` links") |
| `notifications` | no | `false` | Whether the page's web notifications become macOS notifications ("Notifications") |
| `launch_at_login` | no | `false` | Whether the app opens at login |
| `signin` | no | `{}` | Named logins, each the ordered steps of one sign-in |

- **`keep`** holds exact hosts (`mail.example.com`) and suffix patterns
  (`*.example.com`). A suffix pattern matches any host ending in
  `.example.com`, not `example.com` itself. Matching ignores case and the
  port. `keep` decides where the person's own moves go: a clicked link to a
  kept host loads in the app, and one to any other host opens in the default
  browser, as does every ⌘-click. What the page does itself stays in the app
  whatever the host: redirects (server or script), form submissions, reloads
  and back/forward, which is what keeps a sign-in's chain of hosts intact.
  A new window (`target=_blank`, `window.open`) opens in a second window,
  hidden until a kept page has loaded in it and stayed; if it is sent out of
  scope before then, by a link or a redirector, that URL opens in the default
  browser and the window closes. Other apps' schemes (`mailto:`, `tel:`) go
  to their apps; `file:` is dropped.
- **`icon`** is a path relative to the directory the config file really
  lives in (after following its symlink), or an absolute path. `~` is not
  expanded.
- **`badge.title`** is checked with the CLI's regular expressions (PCRE2);
  the app runs it with `NSRegularExpression` (ICU). Write it in the syntax
  the two share: groups, classes, `\d`, `\s`, quantifiers, anchors. A match
  whose group is empty, or no match, clears the badge.
- **`signin`**: each login is a list of steps, run in order. A step is
  `{"flow": "google" | "okta", "item": "op://VAULT/ITEM"}`, which signs in
  with that 1Password item's username, password and one-time code, or
  `{"flow": "google", "email_from": "op://…"}`, which gives the Google page
  only the email (the item's username, or the field the reference names) so
  that Google hands off to the next step's single sign-on. A reference names
  a vault and item but not the 1Password account; a step whose item is not in
  `op`'s default account adds `"account"`, the account's sign-in address
  (`example.1password.com`) or ID, which the CLI passes to `op --account`. An
  `okta` step may add `"method"`, the verification method to choose when
  Okta shows its list of them ("Verify it's you with a security method"):
  text matched, ignoring case and runs of spaces, as part of a row's text,
  such as the one the item's one-time code answers. Which methods a list
  offers depends on the person's Okta, so Berth names none itself.
  `berth signin SITE` uses the only login, and `--account NAME` picks one
  when there are several.

The file is strict JSON (RFC 8259, with no extensions). A file that does not
parse, or repeats a key within one object, is invalid, and the error gives
the line and column. The CLI writes the file with two-space indentation,
`version` before `sites`, a site's keys in the order of the table above when
the CLI adds them and in their existing order otherwise, an array of plain
values on one line, an array holding objects with one element per line and
each flat object (a sign-in step) on its line, and a trailing newline.

When the config file does not exist, the CLI uses the starter config
embedded in it (`config/starter.json` in the repository); `berth config init
--starter` writes that out, and `berth config init` writes one with no sites.

### Validation

The CLI validates the whole config before any write and refuses an invalid
result, writing nothing. Every problem is reported, not just the first.

- The top level is an object. Unknown keys are errors at every level, so a
  typo is reported rather than ignored. An optional key set to `null` reads
  as absent.
- `version` is `1`; a missing `version` reads as `1`.
- `sites` is an object. A site matches `[a-z0-9][a-z0-9-]*`, at most 32
  characters (its socket path must fit the 104-byte limit).
- `name`: a string of at most 64 characters, without spaces at its start or
  end, a `/`, a `:`, a control character, or a leading `.`. No two sites
  share a name, ignoring case, since they would share an app.
- `url`: an `https` URL with a host and no spaces.
- `keep`: a non-empty list of distinct host patterns. A host is lowercase
  labels of letters, digits and hyphens joined by dots, each label starting
  and ending with a letter or digit; a suffix pattern is `*.` followed by a
  host of at least two labels (`*.com` is refused). One pattern must match
  the `url`'s host.
- `icon`: a string naming a file that exists and starts with the PNG
  signature.
- `badge`: an object whose only key, `title`, is a string that compiles as a
  regular expression with exactly one capture group.
- `handles`: a list of distinct schemes, each `mailto`.
- `mailto`: an `https` URL (with `%s` standing for a value) containing `%s`
  exactly once. Required when `handles` has `mailto`; set without it, it is a
  **warning** (`sites.mail.mailto: unused; add mailto to handles or remove
  it`).
- `notifications`, `launch_at_login`: `true` or `false`.
- `signin`: an object whose keys match `[a-z0-9][a-z0-9-]*`. Each login is a
  non-empty list of steps. A step is an object with `flow` (`google` or
  `okta`), exactly one of `item` and `email_from`, and optionally `account`
  and `method`; `email_from` goes only with `google`, and a step must follow
  it; `method` goes only with `okta`, the only flow with a method list. An
  `item` is `op://VAULT/ITEM`; an `email_from` may add `/FIELD` or
  `/SECTION/FIELD`; no part is empty. An `account` is letters, digits, dots
  and hyphens, starting and ending with a letter or digit, at most 128
  characters. A `method` is a string of 1 to 64 characters, not only
  spaces. The CLI checks the shape only; it never runs `op` to validate.

## Config export (`berth config export --json [--site SITE]`)

The normalized config: defaults filled in, `icon` an absolute path, `badge`,
`mailto` and each step's `item`, `email_from`, `account` and `method` present
as `null` when absent.

```json
{
  "version": 1,
  "source": "file",
  "path": "/Users/me/.berth/config.json",
  "sites": {
    "mail": {
      "site": "mail",
      "bundle_id": "com.kellyredding.berth.mail",
      "name": "Mail",
      "url": "https://mail.example.com/",
      "keep": ["mail.example.com", "accounts.example.com", "*.sso.example.com"],
      "icon": "/Users/me/dotfiles/berth/icons/mail.png",
      "badge": { "title": "\\((\\d+)\\)" },
      "handles": ["mailto"],
      "mailto": "https://mail.example.com/compose?to=%s",
      "notifications": true,
      "launch_at_login": true,
      "signin": {
        "personal": [
          { "flow": "google", "item": "op://Personal/Example Mail", "email_from": null, "account": null, "method": null }
        ],
        "work": [
          { "flow": "google", "item": null, "email_from": "op://Work/Example SSO", "account": "example.1password.com", "method": null },
          { "flow": "okta", "item": "op://Work/Example SSO", "email_from": null, "account": "example.1password.com", "method": "Example Authenticator" }
        ]
      }
    }
  },
  "warnings": []
}
```

- `source` is `"file"` or `"starter"` (no config file exists).
- `path` is the configured path, not the symlink's target.
- `sites` is in config order. With `--site SITE`, it holds only that site.
- `keep` is the configured list, or `[host of url]` when there is none.
- `icon` is resolved against the config file's real directory.
- An invalid config exits 1 with the errors on stderr, whichever site is
  asked for: a site app keeps its last good config and shows the error. An
  unknown `--site` exits 5.

## Socket

Each running site app listens on its own Unix socket,
`<runtime>/<site>.sock`, created with mode `0600`. The CLI connects, writes
one request line, reads one reply line, and the app closes the connection.
This is Assist Ant's envelope, as Trellis uses it.

Request (one line of JSON, then `\n`):

```json
{"v":1,"event":"open","ts":1716825600,"detail_data":{"url":"https://mail.example.com/#inbox"}}
```

Reply (one line of JSON, then `\n`):

```json
{"ok":true,"data":{ }}
{"ok":false,"error":"no sign-in form is showing","code":"unavailable"}
```

Error codes: `bad_request`, `not_permitted`, `not_found`, `unavailable` (the
app cannot do it yet, e.g. no config loaded), `internal`. The CLI adds
`not_running` to its own `--json` error output when there is no connection
or no reply; the app never sends it. The CLI waits 5 s for a reply, and
130 s for `signin.fill`'s.

### Events

Every key of a reply's `data` is always present, `null` when it has no
value.

| Event | `detail_data` | `data` on success |
|---|---|---|
| `status` | — | `{"version", "pid", "site", "url": string\|null, "title": string\|null, "badge": string\|null, "config": {"loaded": bool, "state": "loading"\|"loaded"\|"failed", "error": string\|null}}` |
| `open` | `{"url"?}` | `{"url": string\|null, "opened_in": "app"\|"browser"}` |
| `reload` | — | `{"loaded": bool, "error": string\|null}`: re-runs the export and applies the site's config |
| `signin.fill` | `{"login", "steps": [{"flow", "username", "password"?, "code"?, "method"?}]}` | `{"completed": [flow…], "stopped_at": {"step", "flow", "reason"}\|null, "url": string\|null, "already_signed_in": bool}`, once the sign-in finishes or stops |

- `status`: `url` and `title` are the main window's page now (null before
  one loads), and `badge` its Dock badge (null when there is none).
  `config.error` is the last load's failure, kept beside a last good config
  (`"loaded": true`) or with none (`"state": "failed"`).
- `open` without a `url` brings the window forward and is `"opened_in":
  "app"`. A `url` must be `http` or `https` (`bad_request` otherwise). One
  whose host `keep` matches loads in the window, which comes forward; any
  other opens in the default browser (`"opened_in": "browser"`). Before a
  config has loaded, `open` with a `url` is `unavailable`.
- `reload` is `"ok": true` with `"loaded": false` and the error when the
  export fails: the request worked, the config did not. What a running app
  cannot change in place (name, icon, URL schemes) needs `berth sites build`.
- `signin.fill` carries secrets. They travel only over this socket; the app
  never logs them or writes them to a file, and drops them when the fill
  returns. For a `google` step `username` is the email; an `email_from` step
  sends no `password` or `code`, and a step whose item has no one-time code
  sends no `code`. `method` is the step's configured `method`, sent only
  when set; it is not a secret, and the log may name it. `login` (a string
  or null) is only for the log. A step missing `flow` (`google` or `okta`)
  or a non-empty `username`, with a `password`, `code` or `method` that is
  not a non-empty string, or with an unknown key, is `bad_request`, and the
  refusal never quotes a value.
  - The app brings its window forward and fills the steps in order in the
    main window, polling the page (every 0.4 s) with injected JavaScript in
    an isolated content world. It waits for each step's page and field to
    appear, sets each value through the input's native value setter,
    dispatches `input` and `change`, then clicks the step's submit button
    (or a button labelled Next, Sign in or Verify, else submits the form).
    A step is done once the page has left its flow (its hosts and marker
    elements) and stayed away 1.5 s.
  - Okta may show a list of verification methods before the code: more than
    one visible button labelled Select, each row the largest ancestor of its
    button holding no other. When the step has a `method` and a row's text
    holds it (ignoring case and runs of spaces), the app clicks the first
    such row's button once, then waits for the next page, stopping if the
    list is still there after 15 s. When no row holds it, or the step has
    none, it waits for the person to choose ("waiting for you: choose a
    verification method (the list has no METHOD)" or "(this step names
    none)"). With no list, the code page is filled as it appears.
  - It replies once the sign-in finishes or stops, within 120 s, since a
    person may have to approve a push. `completed` lists the flows of the
    steps done, in order. `stopped_at` is null on success, else the
    zero-based `step`, its `flow` and a `reason` such as "waiting for you:
    approve the Okta sign-in" or "the page didn't accept the password on the
    okta password step"; the person finishes by hand. `url` is the page's
    scheme, host and path, never its query. `already_signed_in` is true when
    the page was the site itself, not a sign-in page: there was nothing to
    do. Steps that are neither completed nor stopped at were not needed:
    the page reached the site first.
  - One fill at a time: another `signin.fill` meanwhile is `unavailable`,
    as is one before a config has loaded.
  - Selectors and the step model live in
    `BerthApp/BerthApp/Models/SigninFlows.swift`, the script in
    `SigninScript.swift` beside it.
- An app given a URL at launch or later (`open -a <app> URL`) treats it as
  `open` does, except a `mailto:` link ("`mailto:` links").

### What the CLI does with them

- `berth status` asks each site's app for `status` (waiting 2 s each) and
  reports it as running, not running (no connection), or not replying.
- `berth open SITE [URL]` sends `open` to a running app. With no connection
  it launches `~/Applications/<name>.app` with `open -a`, passing `URL`, and
  without that app it exits 5 saying to run `berth sites build`. A
  connection that never replies exits 3 without launching anything, since
  the app may have acted on the request.
- `berth signin SITE [--account NAME]` (which a site app also runs itself;
  see below) picks the login (`--account`, or the
  only one; several without `--account` is a usage error, an unknown one
  exits 5), asks the app for `status` and exits 3 saying to run `berth open
  SITE` first when it does not answer, and only then reads 1Password: for an
  `item` step, `op read` of `ITEM/username` and `ITEM/password` and `op item
  get ITEM --vault VAULT --otp` (no code when that fails); for an
  `email_from` step, `op read` of `ITEM/username` or the field named; each
  with `--account` when the step names one. Each step's `method`, when set,
  goes into the request beside its values. Values come from op's stdout and
  go into the request as bytes, never into argv, output or an error, and are
  zeroed once sent. A declined approval, or no `op`, exits 4; an approval
  still pending (op's "authorization timeout") is retried for up to 60 s; an
  item, vault or field op cannot find exits 1. It prints the steps
  completed, or where the app stopped and why (exit 1), and `--json` gives
  the reply's keys with each step's flow and whether a password and code
  were sent, never a value.
- Every config write (`sites add|set|remove`, `config init`) then sends
  `reload` to the app of every site in the config before and after the
  write. An app that is not running is skipped silently; the write never
  fails because of a reload.

### What the app runs

Besides `berth config export`, a site app runs `berth signin SITE --account
LOGIN --json` when the person signs in from inside it (File → Sign In with
1Password, or its sign-in bar), with the CLI found as in "Paths" and a
240 s limit: the fill's 120 s, the CLI's wait for its reply and 1Password's
approvals. The CLI reads 1Password and sends `signin.fill` back to the app's
own socket, so values still travel only from op's stdout to that socket; the
app reads nothing from 1Password and passes no value to the CLI. It reads
the outcome from the exit status and the `--json` output on stdout:

| Exit | `--json` | The app says |
|---|---|---|
| 0 | `already_signed_in` | Signed in (or already signed in) |
| 1 | `stopped_at.reason` | The sign-in stopped, and why |
| 4 | — | 1Password didn't approve, or isn't available |
| 5 | — | No such login |
| any other | `error`, else stderr's last `berth:` line | The sign-in failed, with that message |

## Notifications (`notifications`)

The app's alone; the CLI only validates and exports the key. WebKit's web
view has no `window.Notification`, so a site app whose site sets
`notifications` gives its pages one.

- **The shim** (`BerthApp/BerthApp/Models/NotificationShim.swift`) is a user
  script injected at document start, main frame only, in the page's own
  content world, on hosts `keep` matches; other hosts and sites without
  `notifications` get none. It replaces `window.Notification`:
  `Notification.permission` is `"granted"` once macOS allows the app's
  notifications, `"denied"` once it refuses, and `"default"` before it is
  asked; `Notification.requestPermission()`, with a callback or as a
  promise, asks macOS through the app and resolves with the answer; `new
  Notification(title, {body, tag, icon, silent, data, …})` posts to the
  `berthNotifications` script message handler and returns an object with
  `close()`, `onclick`, `onclose`, `onshow`, `onerror` and
  `addEventListener` for those events. `show` fires once macOS takes it and
  `error` when it does not (no permission, the rate limit, a refusal). A
  change to the config or to macOS's answer reaches a page at its next load;
  a page already open learns a new permission at once.
- **Asking macOS** happens the first time a page calls `requestPermission()`,
  or when the person turns on "Show notifications" in Settings, never at
  launch: a page asks when the person turns on its own desktop
  notifications, so the prompt comes when they want it.
- **Posting** uses `UNUserNotificationCenter` with the title and body. The
  `tag` (per host) is the request's identifier, so a notification posted
  with a tag already showing replaces it. `silent` drops the sound. `icon`
  is ignored: macOS shows the site app's own icon. `data` stays in the page.
  A notification shows even while the app is in front, since the page
  decides when to notify.
- **Clicking one** brings forward the window whose page posted it (the main
  window when that is gone) and fires that `Notification`'s `click`, which
  is how a page opens the item. A page reloaded since then gets nothing, and
  the window still comes forward. `close()` removes it from Notification
  Center; clearing it there tells the page nothing.
- **Limits:** messages from a subframe or from a host outside `keep` are
  ignored, as is everything when the site's `notifications` is false. A
  title is cut to 200 characters and a body to 1000; a tag over 256 or an id
  over 64 refuses the message. At most 3 a second and 30 a minute are
  posted; the rest are dropped. The rules live in `NotificationRules.swift`.
- **The log** gets one line per notification, `notification: posted (tag
  TAG)` or `(no tag)`, and refusals by kind (each at most once in 10 s),
  never a title or body.
- **Settings** shows "Show notifications" as macOS's answer: off before it
  is asked (turning it on asks), on once allowed, and off with a link to
  System Settings › Notifications for this app once refused. Only System
  Settings changes an answer macOS has given.
- **The Dock badge:** the app asks macOS for alerts and sounds, and for
  badges too when the site has a `badge.title` rule; a site without one never
  asks for badges. Once an app has notification permission, macOS appears to
  show the badge the page title sets only while its Badges permission is on
  (inferred from the Dock, not documented); an app allowed without asking for
  badges has no Badges row in System Settings. So at launch, a site with
  `notifications` and a badge rule whose app is allowed but never asked for
  badges asks again with them, once, and logs the answer (`notification:
  asked macOS for badges; Badges is enabled`). Whenever either answer
  changes, the app sets its badge again. For a site with a badge rule, when
  notifications are allowed and badges are not, Settings says "Dock badge
  off" with the same System Settings link. The rules live in
  `NotificationRules.swift` (`DockBadgePermission`).

## `mailto:` links (`handles`, `mailto`)

`berth sites build` registers the schemes in `handles` through
`CFBundleURLTypes` ("Site apps"); the app does the rest.

- **A link arrives** as a get-URL Apple event (`kAEGetURL`), whichever app
  sent it, `open -a <app> URL` included. When the site's `handles` has
  `mailto`, the app replaces the `%s` in the site's `mailto` with the whole
  link percent-encoded (everything but RFC 3986's unreserved characters, so
  `+`, `&`, `,`, `@` and an existing `%20` are encoded too), as a browser's
  registered protocol handler does; the site decodes it once and reads the
  link exactly as it was sent. The compose URL then goes where `open` sends
  a URL: into the main window, which comes forward, when `keep` matches its
  host, else the default browser. A link arriving before the page is up
  waits for it. The rules live in `BerthApp/BerthApp/Models/MailtoLink.swift`.
- **The main window, not a new one:** the compose page is the site itself,
  and a second window would load and keep a second copy of it.
- **A site that does not handle `mailto`** (its config changed since the app
  was built) drops the link; it never hands it back to the system, which
  could send it straight back to this app.
- **The log** names the compose page's host and path, never the link, its
  address, subject or body.
- **Settings**, for a site that handles `mailto`, shows "Default email app:
  NAME" (macOS's current choice) and, unless it is this app, a button "Make
  NAME the default email app", which asks macOS to make this app the
  default; macOS asks the person to confirm.

## CLI exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failed, including an invalid config or a refused change (`bad_request`, `unavailable`, `internal`) |
| 2 | Usage error |
| 3 | The site's app is not running (no connection, or no reply) |
| 4 | Not permitted (`not_permitted`, or 1Password declined) |
| 5 | No such site or login, or the site's app is not built (`not_found`) |
