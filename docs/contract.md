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
  sign-in forms it is sent. It never reads or writes the config file itself.
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
| The signing script `berth sites build` runs | `<checkout>/bin/lib/sign-app.sh` for a CLI built in a checkout (`tools/berth/build/berth`), else `<root>/libexec/sign-app.sh` | `BERTH_SIGN_SCRIPT` (the only one tried when set) |
| `codesign`, `sips`, `iconutil` | `/usr/bin/…` | `BERTH_CODESIGN`, `BERTH_SIPS`, `BERTH_ICONUTIL` (specs) |
| `lsregister` | Launch Services' own, in `CoreServices.framework` | `BERTH_LSREGISTER` (specs) |

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
`Identifier`, and have `Berth Release Signing` as its `Authority` (or be ad
hoc with `--sign adhoc`). Only then is each moved into place by rename, and
registered with `lsregister -f`; every `*/Build/Products/*/Berth.app`
registered is unregistered.

- **What may be replaced:** nothing, a symbolic link (the link is removed,
  never its target), or this site's own app: a directory whose `BerthSite` is
  the site and whose `CFBundleIdentifier` starts with
  `com.kellyredding.berth.`. Anything else at any destination refuses the
  whole build before anything changes.
- **A running app** keeps its old build until it is restarted. The CLI never
  launches, quits or restarts one.

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
          {"flow": "okta", "item": "op://Work/Example SSO", "account": "example.1password.com"}
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
| `mailto` | when `handles` has `mailto` | none | The URL a `mailto:` link opens, with `%s` where the link goes |
| `notifications` | no | `false` | Whether the page's web notifications become macOS notifications |
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
  (`example.1password.com`) or ID, which the CLI passes to `op --account`.
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
  `okta`), exactly one of `item` and `email_from`, and optionally `account`;
  `email_from` goes only with `google`, and a step must follow it. An `item`
  is `op://VAULT/ITEM`; an `email_from` may add `/FIELD` or
  `/SECTION/FIELD`; no part is empty. An `account` is letters, digits, dots
  and hyphens, starting and ending with a letter or digit, at most 128
  characters. The CLI checks the shape only; it never runs `op` to validate.

## Config export (`berth config export --json [--site SITE]`)

The normalized config: defaults filled in, `icon` an absolute path, `badge`,
`mailto` and each step's `item`, `email_from` and `account` present as `null`
when absent.

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
          { "flow": "google", "item": "op://Personal/Example Mail", "email_from": null, "account": null }
        ],
        "work": [
          { "flow": "google", "item": null, "email_from": "op://Work/Example SSO", "account": "example.1password.com" },
          { "flow": "okta", "item": "op://Work/Example SSO", "email_from": null, "account": "example.1password.com" }
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
or no reply; the app never sends it. The CLI waits 5 s for a reply.

### Events

Every key of a reply's `data` is always present, `null` when it has no
value.

| Event | `detail_data` | `data` on success |
|---|---|---|
| `status` | — | `{"version", "pid", "site", "url": string\|null, "title": string\|null, "badge": string\|null, "config": {"loaded": bool, "state": "loading"\|"loaded"\|"failed", "error": string\|null}}` |
| `open` | `{"url"?}` | `{"url": string\|null, "opened_in": "app"\|"browser"}` |
| `reload` | — | `{"loaded": bool, "error": string\|null}`: re-runs the export and applies the site's config |
| `signin.fill` | `{"login", "steps": [{"flow", "username", "password"?, "code"?}]}` | `{"completed": [flow…], "stopped_at": {"step", "flow", "reason"}\|null, "url": string\|null, "already_signed_in": bool}`, once the sign-in finishes or stops |

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
  sends no `code`. `login` (a string or null) is only for the log. A step
  missing `flow` (`google` or `okta`) or a non-empty `username`, or with an
  unknown key, is `bad_request`, and the refusal never quotes a value.
  - The app brings its window forward and fills the steps in order in the
    main window, polling the page (every 0.4 s) with injected JavaScript in
    an isolated content world. It waits for each step's page and field to
    appear, sets each value through the input's native value setter,
    dispatches `input` and `change`, then clicks the step's submit button
    (or a button labelled Next, Sign in or Verify, else submits the form).
    A step is done once the page has left its flow (its hosts and marker
    elements) and stayed away 1.5 s.
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
- An app given a URL at launch (`open -a <app> URL`) treats it as `open`
  does.

### What the CLI does with them

- `berth status` asks each site's app for `status` (waiting 2 s each) and
  reports it as running, not running (no connection), or not replying.
- `berth open SITE [URL]` sends `open` to a running app. With no connection
  it launches `~/Applications/<name>.app` with `open -a`, passing `URL`, and
  without that app it exits 5 saying to run `berth sites build`. A
  connection that never replies exits 3 without launching anything, since
  the app may have acted on the request.
- Every config write (`sites add|set|remove`, `config init`) then sends
  `reload` to the app of every site in the config before and after the
  write. An app that is not running is skipped silently; the write never
  fails because of a reload.

## CLI exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failed, including an invalid config or a refused change (`bad_request`, `unavailable`, `internal`) |
| 2 | Usage error |
| 3 | The site's app is not running (no connection, or no reply) |
| 4 | Not permitted (`not_permitted`, or 1Password declined) |
| 5 | No such site or login, or the site's app is not built (`not_found`) |
