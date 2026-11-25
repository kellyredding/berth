# Berth

Berth turns web pages into standalone, signed Mac apps: a Swift shell app
(`BerthApp/`) copied once per configured site, and a Crystal CLI
(`tools/berth/`). **The app is the actor; the CLI is the client.** Each site
app shows its page, keeps its links and sign-in, and listens on its own Unix
socket. The CLI is the only reader and writer of the config, builds and signs
the site apps, and talks to a running one over that socket.

`docs/contract.md` is the CLI ↔ app contract: paths, config keys and
validation, the export shape, socket events, exit codes. A change to either
side that touches it changes the contract and both sides in the same commit.

## This repository is public

The rule: **how a product's public pages work may be committed; anything
about a particular person or account may not.** It covers source, comments,
specs, fixtures, docs, config and commit messages.

- **May be committed:** what is the same for every user and visible to
  anyone, as Berth's built-in `google` and `okta` sign-in flows are: field
  selectors, button text, and the product's own hosts (`accounts.google.com`,
  `*.okta.com`).
- **Never committed:** real sites and their URLs; tenants and their hosts;
  email addresses and usernames; 1Password accounts, vaults, items and IDs;
  which verification method an account uses; icons; personal paths
  (`/Users/<name>/…`). All of that belongs in the user's own config and
  environment, outside the repository: `~/.berth/config.json` (or wherever
  `BERTH_CONFIG` points) and their shell profile.

Fixtures, specs and `config/starter.json` use `example.com` sites only
(`docs`, `mail`), placeholder 1Password references (`op://V/I`,
`op://Work/…`, `op://Example Vault/…`) and `example.1password.com`.

`make audit` checks this, and `make check` runs it first. **It scans
git-tracked files only**, so a new file is invisible to it until staged:
stage first, then audit. A leak that reaches a commit cannot be undone by a
later commit, so run it before committing.

The audit (`scripts/check-disclosure.sh`) has two layers: structural patterns
that describe the shape of a leak (an email address off `example.*`, an
`op://` reference to a vault that is not a placeholder, a 1Password sign-in
address other than `example.1password.com`, a 1Password-style ID, a `/Users/<name>` path, a real host in a fixture or the starter config),
and a literal denylist kept outside the repository, since committing it
would be the leak: `BERTH_DENYLIST`, else `~/.berth/denylist.txt`, one term
per line, ignoring case, `#` for comments. It prints only the file and line
of a match, never the text. Without a denylist it refuses; on a fresh clone,
`BERTH_ALLOW_NO_DENYLIST=1 make check` accepts the structural layer alone.
`scripts/check-disclosure.sh --file PATH…` audits generated text, such as
release notes, before it is published.

## Branches and releases

- Work lands on `development`. Feature branches
  (`kr/berth-<feature>NN-<task>`) come off it, and `development`
  fast-forwards to them (`git merge --ff-only`), rebasing first if it moved.
- `main` is the release branch and only ever fast-forwards to
  `development`. Never commit on `main`, not even a version bump.
- **No pull requests and no review loop** in this repository. That is a
  deliberate exception to the general git workflow; do not open PRs here.
- Kelly releases with `bin/release`. **Agents never tag, publish or push a
  release.**
- The version lives only in `VERSION`. The CLI reads it at compile time and
  `bin/package` stamps it into the app; never type a version anywhere else.

## Releasing and installing

`docs/contract.md`, "Releases and installs", has the archive, the manifest,
the install layout and what `update` and `doctor` do.

- **A release:** an agent drafts `release-notes/vX.Y.Z.md` (see
  `release-notes/README.md`) and the `VERSION` bump as the last commit on
  `development`; Kelly fast-forwards `main`, pushes it, and runs `bin/release
  --dry-run`, reads the printed description, then `bin/release`. It refuses
  off `main`, when `main` is not `origin/main`, on a dirty tree, without the
  notes, when the tag points elsewhere, and when `BERTH_ALLOW_NO_DENYLIST` is
  set; it runs `make check` (the audit with the real denylist) and `make
  app-check`, packages with `--sign op`, verifies the archive, and audits the
  notes and the generated description with `scripts/check-disclosure.sh
  --file` before tagging or printing anything. A rerun after a dry run of the
  same commit reuses its archive; `--fresh` rebuilds.
- **`bin/package [--local] [--sign op|adhoc] [--out DIR]`** builds the CLI and
  the template, stamps them, signs both through `bin/lib/sign-app.sh` and
  writes the archive to `dist/` (ignored). `--sign op` is the default and
  needs the signing variables; it never falls back to ad hoc. It refuses a CLI
  that links anything outside `/usr/lib`. `--local --sign adhoc` checks
  packaging only: `install.sh` refuses that archive.
- **Development installs** go through the signed package path, never a link
  to a build: `berth update --local [PATH]` packages the checkout, installs it
  and rebuilds every site app, which Kelly approves in 1Password.
- **Agents never run** `bin/release` without `--dry-run`, a real `berth
  update`, or `bin/package --sign op`. Check the installer against an ad-hoc
  archive in a sandboxed `HOME`, with `BERTH_LSREGISTER` pointing at a
  stand-in, and delete the sandbox afterwards.

## Building and checking

```bash
make check       # disclosure audit, then CLI: lint + build + specs
make audit       # the disclosure audit alone
make app-check   # app: build + smoke (BerthApp/Makefile's check)
```

- **`make check` does not build the app.** A change touching both sides
  needs both commands.
- `BerthApp/project.yml` is the source of truth for the Xcode project,
  which `xcodegen` regenerates on every build and which is not tracked.
  Never run `xcodebuild` directly; never hand-edit the `.xcodeproj`.
- **`BerthApp/BerthApp/Models/` is Foundation-only.** The `BerthSmoke`
  target compiles exactly that directory, which is how site decoding, `keep`
  matching, badge parsing, the user agent and the sign-in steps are checked
  without a window server. Anything needing AppKit or WebKit belongs in
  `Services/` or `Views/`.
- **JavaScript embedded in Swift** goes in a `"""` literal with `// js-validate`
  on the line above it. The app's build runs `BerthApp/scripts/validate-js.mjs`
  (it needs `node`) before xcodebuild, because a syntax error in a literal
  compiles clean and fails only in the page. Write a JS backslash as `\\`.
- `fixtures/config.json` and `fixtures/export.json` pin the config export for
  both sides. Never edit them to make one side's check pass.
- The build is the template, `Berth.app`, which shows no site. A development
  build runs a site with `BERTH_SITE=<site>` in its environment, with
  `BERTH_ROOT`, `BERTH_CONFIG` and `BERTH_BINARY` pointing at a scratch
  config and the dev CLI (`tools/berth/build/berth`); start its executable
  (`BerthApp/build/Build/Products/Debug/Berth.app/Contents/MacOS/Berth`)
  directly, record its pid, and quit it by that pid. The app logs to
  `<runtime>/logs/<site>.log`.
- The build unregisters `Berth.app` from Launch Services; after running a
  development build, unregister it again (`lsregister -u <path>`), so it
  never shadows an installed site app.
- **The CLI never links OpenSSL.** Nothing in `tools/berth/src/` may require
  `digest`, `openssl` or anything else that loads Homebrew's libcrypto; a
  release binary must load only `/usr/lib` libraries (`otool -L`). Shell out
  to `/usr/bin/shasum` for a checksum.

## Signing

macOS ties a site app's notification permission and login item to its
signature. **Never sign ad hoc** anything that gets installed. Releases and
every site app are signed with one self-signed identity (its certificate's
common name is `Berth Release Signing`) kept in 1Password, which Kelly
approves, so each app keeps one signature across rebuilds and updates.
`berth sites build --sign adhoc` is for scratch directories only
(`BERTH_APPLICATIONS_DIR`). Agents never run `bin/signing-identity create`;
Kelly does.

Signing reads the identity's 1Password account and item from
`BERTH_SIGNING_OP_ACCOUNT` and `BERTH_SIGNING_OP_ITEM` (`op://VAULT/ITEM`),
which a maintainer sets in their own shell profile. **Neither has a default,
and none may be added**: the repository names no account, vault or item.
Without them `--sign op`, `sign-app.sh op` and `bin/signing-identity` refuse
with exit 2. Specs set placeholder values and use the fake signing script.

## Do not

- Launch, quit or sign in to a site app unless asked. Reading (`berth sites
  list`, `berth config export --json`, `berth status`) is always fine.
- Touch `~/.berth`, `~/Applications`, the network or the Launch Services
  database from specs or checks: every path has an environment override
  (`BERTH_ROOT`, `BERTH_CONFIG`, `BERTH_RUNTIME_DIR`, `BERTH_BINARY`,
  `BERTH_APPLICATIONS_DIR`), and so does every tool a build runs
  (`BERTH_SIGN_SCRIPT`, `BERTH_CODESIGN`, `BERTH_SIPS`, `BERTH_ICONUTIL`,
  `BERTH_LSREGISTER`). `update` specs put stand-ins for `curl` and a
  checkout's `bin/package` and `install.sh` on `PATH` or in a scratch
  repository.
- Run `op` from specs, or put a secret in a spec, a log, a file or argv.
  Sign-in secrets travel only from `op`'s output to a site app's socket.
