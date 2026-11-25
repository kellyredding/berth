#!/usr/bin/env bash
#
# check-disclosure.sh: refuse personal details in the repository.
#
# This repository is public. How a product's public pages work may be in it;
# anything about a particular person or account may not: real sites, tenants,
# email addresses, 1Password accounts, vaults, items and IDs, personal paths.
# CLAUDE.md, "This repository is public", has the rule.
#
# Two layers, because they fail differently:
#
#   1. STRUCTURAL patterns, defined below. They describe the shape of a leak,
#      so they catch leaks nobody thought to list, and they can live in a
#      public repository because they name nothing.
#
#   2. A LITERAL denylist, deliberately kept outside the repository, since
#      committing it would be the leak it exists to prevent:
#
#        $BERTH_DENYLIST, else ~/.berth/denylist.txt
#
#      One term per line, matched literally and ignoring case; blank lines
#      and lines starting with # are skipped. A missing or empty list fails
#      the audit unless BERTH_ALLOW_NO_DENYLIST=1 (a fresh clone).
#
# A finding prints only the file and line, never the text that matched: a
# denylist term or a leaked address printed here would land in a terminal's
# scrollback or an agent's transcript. A denylist finding names the
# denylist's line instead of its term.
#
# Scans git-tracked files only, so a new file must be staged first. Exits 1 on
# a finding, 2 on bad usage.
#
#   scripts/check-disclosure.sh --file PATH...
#
# scans those files instead, tracked or not, for generated text that will be
# published, such as release notes.

set -euo pipefail

usage="usage: scripts/check-disclosure.sh [--file PATH...]"
files=()
if [[ "${1:-}" == "--file" ]]; then
  shift
  (( $# > 0 )) || { echo "check-disclosure.sh: --file needs at least one path" >&2; exit 2; }
  for path in "$@"; do
    [[ -f "$path" ]] || { echo "check-disclosure.sh: no such file: $path" >&2; exit 2; }
    files+=("$(cd "$(dirname "$path")" && pwd)/$(basename "$path")")
  done
elif (( $# > 0 )); then
  echo "$usage" >&2
  exit 2
fi
command -v rg >/dev/null || { echo "check-disclosure.sh: ripgrep (rg) is not installed" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)"

SELF="scripts/check-disclosure.sh"
found=0
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

bd_files() {
  if (( ${#files[@]} > 0 )); then
    printf '%s\0' "${files[@]}"
  else
    git ls-files -z
  fi
}

# Every match as PATH:LINE:MATCH, ignoring case. Binary files are skipped.
bd_matches() {
  bd_files | xargs -0 rg --no-messages --no-heading --with-filename --line-number \
    --only-matching --ignore-case --color never "$@" -- 2>/dev/null || true
}

# PATH:LINE:MATCH lines down to PATH:LINE, once each.
bd_locations() {
  sed -E 's/^([^:]*:[0-9]+):.*$/\1/' | sort -u
}

bd_report() {
  local label="$1" hits="$2"
  [[ -z "$hits" ]] && return 0
  found=1
  printf '\n  %s\n' "$label"
  printf '%s\n' "$hits" | sed 's/^/    /'
}

# bd_scan LABEL PATTERN SCOPE [ALLOW...]
#
# SCOPE, when not empty, limits the rule to paths it matches. Each ALLOW is a
# regular expression for a match that is fine; it must match the whole of
# the matched text (case-sensitive unless it starts with (?i)). The script
# itself is skipped: its patterns would match themselves.
bd_scan() {
  local label="$1" pattern="$2" scope="$3"
  shift 3
  local hits allow
  hits="$(bd_matches --regexp "$pattern" | { rg -v "^$SELF:" || true; })"
  if [[ -n "$scope" ]]; then
    hits="$(printf '%s\n' "$hits" | { rg "^([^:]*/)?(${scope})[^:]*:" || true; })"
  fi
  for allow in "$@"; do
    hits="$(printf '%s\n' "$hits" | { rg -v "^[^:]*:[0-9]+:(?:${allow})\$" || true; })"
  done
  bd_report "$label" "$(printf '%s\n' "$hits" | { rg -v '^$' || true; } | bd_locations)"
}

if (( ${#files[@]} > 0 )); then
  echo "disclosure audit: ${#files[@]} file(s)"
else
  echo "disclosure audit: tracked files"
fi

# Layer 1: structural patterns.

# example.com, .org and .net are reserved for examples (RFC 2606). A
# retina image name (icon_16x16@2x.png) has the same shape.
bd_scan "email address not on example.com, .org or .net" \
  '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' "" \
  '(?i)[^@]*@([a-z0-9-]+\.)*example\.(com|org|net)' \
  '(?i)[^@]*@[0-9]+x\.(png|jpe?g|gif|tiff?|pdf)'

# The match stops at the vault. A placeholder vault is an all-capitals word
# (V, VAULT), <anything>, an ellipsis, Vault, Example..., or Work or Personal,
# the two generic vaults the specs and fixtures invent. Any other vault reads
# as someone's own, so a new example uses one of these. A vault starting
# with [ or ( is a regular expression matching references, not a name.
bd_scan "1Password reference to a vault that is not a placeholder" \
  'op://([^/\s"'"'"'`)\]},][^/"'"'"'`)\]},]*)?' "" \
  'op://([A-Z]+|<[^>]*>|…|Vault|Example[^/]*|Work|Personal|[\[(].*)?'

# A 1Password sign-in address names an account, even the common
# my.1password.com. The placeholders are example and an <account>.
bd_scan "1Password account address that is not a placeholder" \
  '(<[^>[:space:]]*>|[a-z0-9][a-z0-9_-]*)\.1password\.(com|eu|ca)' "" \
  '(?i)(example|<[^>]*>)\.1password\.(com|eu|ca)'

# 1Password item, vault and account IDs are 26 letters and digits. One with
# no digit, or no letter, is a word or a number, such as the specs' made-up
# account ID, ABCDEFGHIJKLMNOPQRSTUVWXYZ.
bd_scan "26-character 1Password-style ID" \
  '\b[a-z0-9]{26}\b' "" \
  '[A-Za-z]+' '[0-9]+'

bd_scan "personal path under /Users" \
  '/Users/[^/\s"'"'"'`)]+' "" \
  '/Users/(me|you|someone|Shared|<[^>]*>)'

# Hosts in URLs and quoted host values (keep, account) in the shipped config
# and the contract's fixtures, which may name only reserved example domains.
# The project's own bundle identifiers have the same shape.
bd_scan "host on a real domain in a fixture or the starter config" \
  '(://|")(\*\.)?([a-z0-9-]+\.)+[a-z][a-z0-9-]*' \
  'fixtures/|config/starter\.json' \
  '(?i)(://|")(\*\.)?([a-z0-9-]+\.)*(example\.(com|org|net)|[a-z0-9-]+\.(test|example|invalid|localhost))' \
  '(?i)"example\.1password\.com' \
  '"com\.kellyredding\.berth(\.[a-z0-9-]+)?'

# Layer 2: the literal denylist, outside the repository.
denylist="${BERTH_DENYLIST:-$HOME/.berth/denylist.txt}"
shown="${denylist/#$HOME/\~}"
missing=""
if [[ ! -f "$denylist" ]]; then
  missing="no denylist at $shown"
else
  terms=0
  number=0
  while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    terms=$((terms + 1))
    # Through a file, so the term never appears in a process's arguments.
    printf '%s\n' "$line" > "$work/term"
    bd_report "denylisted term (denylist line $number)" \
      "$(bd_matches --fixed-strings --file "$work/term" | bd_locations)"
  done 3< "$denylist"
  : > "$work/term"
  (( terms > 0 )) || missing="the denylist at $shown has no terms"
fi

if [[ -n "$missing" ]]; then
  # Refused rather than warned: the structural layer alone would print
  # "clean" and let a commit through while covering less than it claims.
  cat <<EOF

FAILED: $missing.

The terms that must never appear here live outside the repository, one per
line, in \$BERTH_DENYLIST or ~/.berth/denylist.txt. Create it with the names
of your own sites, tenants, accounts, vaults and items.

On a fresh clone with no list, accepting the structural checks alone:
  BERTH_ALLOW_NO_DENYLIST=1 make audit
EOF
  [[ "${BERTH_ALLOW_NO_DENYLIST:-}" == "1" ]] || exit 1
  echo
  echo "  denylist: none; proceeding on BERTH_ALLOW_NO_DENYLIST"
else
  echo "  denylist: $shown ($terms terms)"
fi

if (( found )); then
  cat <<'EOF'

FAILED: the lines above look personal.

This repository is public. Anything about a particular person or account
belongs in their own config and environment, not here. If a match is a false
positive, add a narrow allowance in scripts/check-disclosure.sh and say in
the commit why it is safe.
EOF
  exit 1
fi

echo "  clean"
