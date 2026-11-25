#!/usr/bin/env bash
# Usage: sign-app.sh (op|adhoc) <target>...
#
# A target is a bundle's path, or <identifier>=<path> for a bare binary, whose
# identifier would otherwise be its file name. Every target is signed in one
# session, so the release identity costs one 1Password approval however many
# bundles there are: every site app in a `berth sites build`, or the template
# and the CLI in bin/package.
#
# op:    signs with the release identity, fetched from 1Password into a
#        throwaway keychain that is deleted on exit. The login keychain is
#        never used: a key there needs the user's login password, which
#        surfaces as a dialog mid-build. Exits 4 when 1Password never
#        provides the identity.
# adhoc: signs with no identity. macOS treats every ad-hoc build as a new app,
#        so an installed site app may lose its notification permission and
#        login item. Development and specs only; never for anything installed.
#
# op needs two variables, set in your own shell profile, never in this
# repository; it exits 2 before doing anything when either is unset or empty:
#
#   BERTH_SIGNING_OP_ACCOUNT  the 1Password account holding the identity: its
#                             sign-in address or account ID (op --account)
#   BERTH_SIGNING_OP_ITEM     the identity's item, op://VAULT/ITEM, as
#                             bin/signing-identity create stores it
set -euo pipefail

usage="usage: sign-app.sh (op|adhoc) <path|identifier=path>..."
mode="${1:?$usage}"
shift
(( $# > 0 )) || { echo "$usage" >&2; exit 2; }

# Exits 2 naming each signing variable that is unset, empty or malformed.
bs_require_signing_env() {
  local ok=1
  if [[ -z "${BERTH_SIGNING_OP_ACCOUNT:-}" ]]; then
    echo "sign-app.sh: BERTH_SIGNING_OP_ACCOUNT is not set. Set it in your shell profile to the 1Password account that holds the signing identity, its sign-in address or account ID:" >&2
    echo "  export BERTH_SIGNING_OP_ACCOUNT='<account>.1password.com'" >&2
    ok=0
  fi
  if [[ -z "${BERTH_SIGNING_OP_ITEM:-}" ]]; then
    echo "sign-app.sh: BERTH_SIGNING_OP_ITEM is not set. Set it in your shell profile to the signing identity's 1Password item:" >&2
    echo "  export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'" >&2
    ok=0
  elif ! [[ "$BERTH_SIGNING_OP_ITEM" =~ ^op://[^/]*[^/[:space:]][^/]*/[^/]*[^/[:space:]][^/]*$ ]]; then
    echo "sign-app.sh: BERTH_SIGNING_OP_ITEM must be the signing identity's 1Password item, op://VAULT/ITEM, with no field:" >&2
    echo "  export BERTH_SIGNING_OP_ITEM='op://<vault>/<item>'" >&2
    ok=0
  fi
  (( ok )) || exit 2
}

# Splits a target into its path and the --identifier arguments it needs. An
# identifier is a reverse-DNS name, so a path that merely contains "=" is
# taken whole.
bs_target() {
  local target="$1"
  if [[ "$target" =~ ^([A-Za-z0-9.-]+)=(.+)$ ]]; then
    target_path="${BASH_REMATCH[2]}"
    target_args=(--identifier "${BASH_REMATCH[1]}")
  else
    target_path="$target"
    target_args=()
  fi
  [[ -e "$target_path" ]] || { echo "sign-app.sh: no such file: $target_path" >&2; exit 1; }
}

if [[ "$mode" == "adhoc" ]]; then
  for target in "$@"; do
    bs_target "$target"
    codesign --force --sign - --timestamp=none ${target_args[@]+"${target_args[@]}"} "$target_path" 2>&1 \
      | { grep -v "replacing existing signature" || true; }
  done
  exit 0
fi
[[ "$mode" == "op" ]] || { echo "sign-app.sh: unknown mode '$mode'" >&2; exit 2; }
bs_require_signing_env
OP_ACCOUNT="$BERTH_SIGNING_OP_ACCOUNT"
OP_ITEM="$BERTH_SIGNING_OP_ITEM"
for target in "$@"; do bs_target "$target"; done
command -v op >/dev/null || { echo "sign-app.sh: the 1Password CLI (op) is not installed; it holds the signing identity" >&2; exit 1; }

work="$(mktemp -d)"
kc="$work/berth-signing.keychain-db"
kcpass="$(/usr/bin/openssl rand -hex 24)"

orig_list=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && orig_list+=("$line")
done < <(security list-keychains -d user)

# shellcheck disable=SC2329 # run by the trap below
bs_cleanup() {
  security list-keychains -d user -s ${orig_list[@]+"${orig_list[@]}"} || true
  security delete-keychain "$kc" 2>/dev/null || true
  rm -rf "${work:?}"
}
trap bs_cleanup EXIT

# op gives up on the desktop app within a few seconds, often while its
# approval prompt is still on screen, so retry until the approval lands.
last_error=""
for attempt in $(seq 1 20); do
  # bin/signing-identity stores the file as field `p12` in section `signing`.
  if last_error="$(op read --account "$OP_ACCOUNT" --out-file "$work/signing.p12" --force "$OP_ITEM/signing/p12" 2>&1 >/dev/null)"; then
    break
  fi
  if (( attempt == 1 )); then
    echo "Approve the 1Password prompt to sign with the release identity (op said: $last_error)" >&2
  fi
  if (( attempt == 20 )); then
    echo "1Password never provided the signing identity. Last error from op: $last_error" >&2
    echo "Run it from a terminal that can show 1Password's prompt; bin/signing-identity show checks the item exists." >&2
    exit 4
  fi
  sleep 3
done
p12pass="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/password")"
identity="$(op read --account "$OP_ACCOUNT" "$OP_ITEM/sha1")"

security create-keychain -p "$kcpass" "$kc"
# No auto-lock and no lock on sleep: a keychain that locks mid-run raises a
# password dialog for a password no one knows.
security set-keychain-settings "$kc"
security unlock-keychain -p "$kcpass" "$kc"
security import "$work/signing.p12" -k "$kc" -P "$p12pass" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$kc" >/dev/null
# codesign --keychain only searches keychains already on the search list.
security list-keychains -d user -s ${orig_list[@]+"${orig_list[@]}"} "$kc"

for target in "$@"; do
  bs_target "$target"
  codesign --force --keychain "$kc" --sign "$identity" --timestamp=none \
    ${target_args[@]+"${target_args[@]}"} "$target_path" 2>&1 \
    | { grep -v "replacing existing signature" || true; }
done
