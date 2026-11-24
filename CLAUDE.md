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

**Never commit anything personal**: no real sites, accounts, email addresses,
1Password vault or item names, or icons from anyone's own config. Fixtures,
specs and `config/starter.json` use `example.com` sites only (`docs`, `mail`).
Personal configs and their icons live outside the repository.

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

## Building and checking

```bash
make check       # CLI: lint + build + specs
make app-check   # app: build + smoke (fails while there is no BerthApp/)
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
- `fixtures/config.json` and `fixtures/export.json` pin the config export for
  both sides. Never edit them to make one side's check pass.
- **The CLI never links OpenSSL.** Nothing in `tools/berth/src/` may require
  `digest`, `openssl` or anything else that loads Homebrew's libcrypto; a
  release binary must load only `/usr/lib` libraries (`otool -L`). Shell out
  to `/usr/bin/shasum` for a checksum.

## Signing

macOS ties a site app's notification permission and login item to its
signature. **Never sign ad hoc** anything that gets installed. Releases and
every site app are signed with the self-signed "Berth Release Signing"
identity from 1Password, which Kelly approves, so each app keeps one
signature across rebuilds and updates.

## Do not

- Launch, quit or sign in to a site app unless asked. Reading (`berth sites
  list`, `berth config export --json`, `berth status`) is always fine.
- Touch `~/.berth` or `~/Applications` from specs or checks: every path has
  an environment override (`BERTH_ROOT`, `BERTH_CONFIG`, `BERTH_RUNTIME_DIR`,
  `BERTH_BINARY`, `BERTH_APPLICATIONS_DIR`).
- Run `op` from specs, or put a secret in a spec, a log, a file or argv.
  Sign-in secrets travel only from `op`'s output to a site app's socket.
