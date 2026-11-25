# Release notes

Each release has one file here, `vX.Y.Z.md`, named for the version in
`VERSION`, and `bin/release` refuses to publish without it. It lands on
`development` in the same commit as the version bump, the last commit before
`main` is fast-forwarded for the release. It holds the changes since the last
tag, grouped by what a user notices: each group a `###` heading led by an
emoji, with two or three bullets. Draft it from `git log <last tag>..HEAD`,
check every bullet against its commit, and let the maintainer edit it.

`bin/release` puts install steps and a line about rebuilding site apps above
it, and publishes the result as the GitHub release's description, under
"What's new". The repository is public, so the notes name no real site,
account or person: `bin/release` runs the disclosure audit
(`scripts/check-disclosure.sh --file`, with the literal denylist) over this
file and over the description before it tags anything.
