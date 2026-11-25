#!/usr/bin/env bash
# Installs or updates Berth: the berth CLI and the template Berth.app that
# `berth sites build` copies once per site.
#
#   curl -fsSL https://raw.githubusercontent.com/kellyredding/berth/main/install.sh | bash
#
# `berth update` runs this same script. Options (after `bash -s --` when piped):
#
#   --version X.Y.Z   Install that release instead of the latest
#   --from ARCHIVE    Install a local archive written by bin/package
#   --preview         Show what would change, change nothing
#   --force           Reinstall even when already up to date
#
# Never touches your config, your site apps or ~/Applications, and never
# launches or quits anything. Rebuild your site apps afterwards with
# `berth sites build --all`.

# One compound command, so bash reads all of it before running any: piped in,
# a truncated download or a command that reads stdin would otherwise cut the
# script short partway through an install.
{
set -euo pipefail

REPO="kellyredding/berth"
ASSET="berth-darwin.tar.gz"
IDENTITY="Berth Release Signing"
TEMPLATE_ID="com.kellyredding.berth"
MIN_MACOS=15
BERTH_HOME="${BERTH_ROOT:-$HOME/.berth}"
BIN_DIR="$BERTH_HOME/bin"
LOCAL_BIN="$HOME/.local/bin"
TEMPLATE_DIR="$BERTH_HOME/template"
TEMPLATE="$TEMPLATE_DIR/Berth.app"
LIBEXEC_DIR="$BERTH_HOME/libexec"
INSTALLED_MANIFEST="$BERTH_HOME/installed-manifest.json"
LSREGISTER="${BERTH_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister}"

version=""
from=""
preview=false
force=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version needs X.Y.Z}"; version="${version#v}"; shift ;;
    --from) from="${2:?--from needs an archive path}"; shift ;;
    --preview|preview) preview=true ;;
    --force|force) force=true ;;
    # Piped in, $0 is the shell rather than this file.
    -h|--help|help) if [[ -f "$0" ]]; then sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
                    else echo "See https://github.com/$REPO/blob/main/install.sh"; fi; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$from" && -n "$version" ]]; then
  echo "install.sh: --from installs that archive; it cannot be combined with --version" >&2
  exit 2
fi

if [[ -t 1 ]]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; NC=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; NC=""; fi
say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
die() { printf '%sinstall.sh: %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

# --- This Mac ----------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "Berth runs on macOS only; this is $(uname -s)."
macos="$(sw_vers -productVersion)"
(( ${macos%%.*} >= MIN_MACOS )) || die "Berth needs macOS $MIN_MACOS or later; this Mac runs $macos."

work="$(mktemp -d)"
installed_ok=false
# shellcheck disable=SC2329 # run by the trap below
bi_cleanup() {
  if $installed_ok || $preview; then rm -rf "${work:?}"
  else printf 'Working files kept for inspection: %s\n' "$work" >&2; fi
}
trap bi_cleanup EXIT

# --- Fetch -------------------------------------------------------------------

if [[ -n "$from" ]]; then
  [[ -f "$from" ]] || die "no archive at $from"
  [[ -f "$from.sha256" ]] || die "no checksum at $from.sha256; bin/package writes one beside the archive"
  cp "$from" "$work/$ASSET"
  # Renamed to the fixed name, so an archive saved under another name still
  # checks against its own checksum file.
  sed "s/[^ ]*$/$ASSET/" "$from.sha256" > "$work/$ASSET.sha256"
  source_label="$from"
else
  if [[ -n "$version" ]]; then
    base="https://github.com/$REPO/releases/download/v$version"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  # curl rather than a browser download: curl sets no quarantine flag, which
  # is what lets self-signed apps open without a Gatekeeper prompt.
  curl -fsSL "$base/$ASSET" -o "$work/$ASSET" </dev/null \
    || die "could not download $base/$ASSET${version:+ (is v$version a Berth release?)}"
  curl -fsSL "$base/$ASSET.sha256" -o "$work/$ASSET.sha256" </dev/null \
    || die "could not download the checksum for $ASSET"
  source_label="$base"
fi

(cd "$work" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) \
  || die "checksum mismatch for $ASSET; nothing was installed"

mkdir -p "$work/unpacked"
tar -xzf "$work/$ASSET" -C "$work/unpacked" || die "could not unpack $ASSET"
pkg="$work/unpacked/berth"
[[ -f "$pkg/manifest.json" && -f "$pkg/bin/berth" && -d "$pkg/Berth.app" && -f "$pkg/libexec/sign-app.sh" ]] \
  || die "$ASSET is not a Berth release archive"

template_plist="$pkg/Berth.app/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$template_plist" 2>/dev/null)" == "$TEMPLATE_ID" ]] \
  || die "Berth.app in $ASSET is not the Berth template ($TEMPLATE_ID); nothing was installed"
if /usr/bin/plutil -extract BerthSite raw -o - "$template_plist" >/dev/null 2>&1; then
  die "Berth.app in $ASSET is a site app, not the template; nothing was installed"
fi

# Every site app is a copy of the template, re-signed with this identity, and
# macOS ties a site app's notification permission and login item to its
# signature: an archive signed any other way is refused before anything is
# replaced.
bi_require_release_signer() {
  local target signature
  for target in "$pkg/Berth.app" "$pkg/bin/berth"; do
    codesign --verify --strict "$target" 2>/dev/null \
      || die "$(basename "$target") in $ASSET does not verify; nothing was installed"
    signature="$(codesign -dv --verbose=2 "$target" 2>&1)"
    [[ "$signature" == *$'\n'"Authority=$IDENTITY"$'\n'* ]] \
      || die "$(basename "$target") in $ASSET is not signed by $IDENTITY. Package it with bin/package (--sign op); nothing was installed"
  done
}
bi_require_release_signer

bi_field() { sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$2" | sed -n 1p; }
new_version="$(bi_field version "$pkg/manifest.json")"
new_commit="$(bi_field commit "$pkg/manifest.json")"
new_dirty="$(bi_field dirty "$pkg/manifest.json")"
if [[ -f "$INSTALLED_MANIFEST" ]]; then
  cur_version="$(bi_field version "$INSTALLED_MANIFEST")"
  cur_commit="$(bi_field commit "$INSTALLED_MANIFEST")"
  cur_dirty="$(bi_field dirty "$INSTALLED_MANIFEST")"
elif [[ -x "$BIN_DIR/berth" ]]; then
  cur_version="unknown (installed from source)"; cur_commit=""; cur_dirty=""
else
  cur_version="not installed"; cur_commit=""; cur_dirty=""
fi

bi_describe() { printf '%s' "$1"; [[ -n "$2" ]] && printf ' (%s%s)' "$2" "$([[ "$3" == true ]] && echo ', uncommitted changes')"; }

# A release is up to date when it is the same commit with no local edits.
# --from always installs, because a local archive is installed on purpose.
if [[ -z "$from" ]] && ! $force && ! $preview \
   && [[ -n "$cur_commit" && "$cur_commit" == "$new_commit" && "$cur_dirty" != "true" ]]; then
  say "${GREEN}Berth is up to date: $(bi_describe "$cur_version" "$cur_commit" "$cur_dirty")${NC}"
  installed_ok=true
  exit 0
fi

say "${BOLD}$([[ "$cur_version" == "not installed" ]] && echo Installing || echo Updating) Berth${NC}"
step "From:      $source_label"
step "Installed: $(bi_describe "$cur_version" "$cur_commit" "$cur_dirty")"
step "New:       $(bi_describe "$new_version" "$new_commit" "$new_dirty")"
step "CLI:       $BIN_DIR/berth (linked into $LOCAL_BIN)"
step "Template:  $TEMPLATE"
step "Signing:   $LIBEXEC_DIR/sign-app.sh"
step "Signed by: $IDENTITY"

if $preview; then
  say ""
  say "Preview only: nothing was changed. Run without --preview to install."
  exit 0
fi
say ""

# --- Install -----------------------------------------------------------------

mkdir -p "$BIN_DIR" "$LOCAL_BIN" "$TEMPLATE_DIR" "$LIBEXEC_DIR"

# A new file moved over the old one, rather than copied onto it, so a binary
# that is running keeps its pages and macOS sees a fresh signature.
install -m 755 "$pkg/bin/berth" "$BIN_DIR/.berth.new"
mv -f "$BIN_DIR/.berth.new" "$BIN_DIR/berth"
# Replaces a plain file a source install may have left here, too.
ln -sfn "$BIN_DIR/berth" "$LOCAL_BIN/berth"
step "Installed berth"

# Swapped by rename, staged under names that are not .app so Launch Services
# passes over them. A link here is removed, never its target.
staged="$TEMPLATE_DIR/.Berth.app.berth-new"
old="$TEMPLATE_DIR/.Berth.app.berth-old"
rm -rf "${staged:?}" "${old:?}"
ditto --noextattr --noqtn "$pkg/Berth.app" "$staged"
if [[ -L "$TEMPLATE" ]]; then
  rm "${TEMPLATE:?}"
elif [[ -e "$TEMPLATE" ]]; then
  mv "$TEMPLATE" "$old"
fi
mv "$staged" "$TEMPLATE"
rm -rf "${old:?}"
step "Installed the template Berth.app"

install -m 755 "$pkg/libexec/sign-app.sh" "$LIBEXEC_DIR/.sign-app.sh.new"
mv -f "$LIBEXEC_DIR/.sign-app.sh.new" "$LIBEXEC_DIR/sign-app.sh"
step "Installed sign-app.sh"

# The template is never registered: it is not an app anyone opens, and must
# never be offered a link. Undo a registration something else made.
if dump="$("$LSREGISTER" -dump 2>/dev/null)"; then
  while IFS= read -r registered; do
    if [[ "$registered" == "$TEMPLATE" || "$registered" == "$TEMPLATE_DIR/"* ]]; then
      "$LSREGISTER" -u "$registered" 2>/dev/null || true
      step "Unregistered $registered from Launch Services"
    fi
  done < <(printf '%s\n' "$dump" | sed -n 's/^path: *\(.*\) (0x[0-9a-f]*)$/\1/p' | sort -u)
else
  step "Could not read Launch Services' registrations; run berth doctor to check the template is not registered"
fi

# Last, so a record names only an install that finished.
cp "$pkg/manifest.json" "$INSTALLED_MANIFEST.new"
mv -f "$INSTALLED_MANIFEST.new" "$INSTALLED_MANIFEST"
installed_ok=true

# --- Next steps --------------------------------------------------------------

say ""
say "${GREEN}Berth $(bi_describe "$new_version" "$new_commit" "$new_dirty") is installed.${NC}"
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) say "Add $LOCAL_BIN to your PATH to use berth." ;;
esac
# Forget where berth was found before the install, so this looks again.
hash -r
on_path="$(command -v berth || true)"
if [[ -n "$on_path" && "$on_path" != "$LOCAL_BIN/berth" && "$on_path" != "$BIN_DIR/berth" ]]; then
  say "$on_path comes first on your PATH and is not this install; remove it."
fi
# `berth update` rebuilds the site apps itself and says so.
if [[ -z "${BERTH_INSTALL_FROM_UPDATE:-}" ]]; then
  say ""
  say "Your site apps are rebuilt from the new template with:"
  say "  berth sites build --all"
  say "Signing needs BERTH_SIGNING_OP_ACCOUNT and BERTH_SIGNING_OP_ITEM set in your shell"
  say "profile, and asks 1Password once for the whole build."
fi
say "Running site apps keep their old build until you restart them."
exit 0
}
