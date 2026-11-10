#!/usr/bin/env bash
# Fixture tests for scripts/ci/flake-lock-diff.sh — the input table in the
# weekly flake.lock bot PR, which is what the owner reads before merging.
#
# Run: bash scripts/tests/flake-lock-diff.test.sh
#
# The failure modes that matter: an input change missing from the table (the
# owner merges a bump they never saw), and a broken lock rendering as "No input
# changes." (a bad update described as a no-op).
set -uo pipefail

DIFF="$(cd "$(dirname "$0")/../ci" && pwd)/flake-lock-diff.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
contains() { # contains <name> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing [$2] in [$3]"; fi
}

# node <owner> <repo> <rev> <lastModified>
node() {
  printf '{"locked":{"lastModified":%s,"narHash":"sha256-x","owner":"%s","repo":"%s","rev":"%s","type":"github"},"original":{"owner":"%s","repo":"%s","type":"github"}}' \
    "$4" "$1" "$2" "$3" "$1" "$2"
}
OLD_NP=1111111111111111111111111111111111111111
NEW_NP=2222222222222222222222222222222222222222
DARWIN=3333333333333333333333333333333333333333

cat > "$TMP/old.lock" <<EOF
{"nodes":{
  "nixpkgs":$(node NixOS nixpkgs $OLD_NP 1787209939),
  "nix-darwin":$(node LnL7 nix-darwin $DARWIN 1786845137),
  "gone":$(node a gone 4444444444444444444444444444444444444444 1786845137),
  "root":{"inputs":{"nixpkgs":"nixpkgs","nix-darwin":"nix-darwin","gone":"gone"}}
},"root":"root","version":7}
EOF
cat > "$TMP/new.lock" <<EOF
{"nodes":{
  "nixpkgs":$(node NixOS nixpkgs $NEW_NP 1787900000),
  "nix-darwin":$(node LnL7 nix-darwin $DARWIN 1786845137),
  "fresh":$(node b fresh 5555555555555555555555555555555555555555 1787900000),
  "root":{"inputs":{"nixpkgs":"nixpkgs","nix-darwin":"nix-darwin","fresh":"fresh"}}
},"root":"root","version":7}
EOF

echo "flake-lock-diff.sh"

out=$(bash "$DIFF" "$TMP/old.lock" "$TMP/new.lock"); rc=$?
check "changed locks exit 0" 0 "$rc"
contains "changed input: old→new revs with UTC dates" \
  "| \`nixpkgs\` | \`111111111111\` (2026-08-20) | \`222222222222\` (2026-08-28) |" "$out"
contains "github input gets a compare link" \
  "https://github.com/NixOS/nixpkgs/compare/$OLD_NP...$NEW_NP" "$out"
contains "added input shown with empty old side" "| \`fresh\` | — | \`555555555555\`" "$out"
contains "removed input shown with empty new side" "| \`gone\` | \`444444444444\` (2026-08-16) | — |" "$out"
if [[ "$out" == *nix-darwin* ]]; then
  bad "unchanged input is not listed" "$out"
else
  ok "unchanged input is not listed"
fi
check "root node is never a row" "" "$(grep -F '`root`' <<<"$out")"

check "identical locks → explicit no-op line" \
  "No input changes." "$(bash "$DIFF" "$TMP/old.lock" "$TMP/old.lock")"

echo 'not json' > "$TMP/bad.lock"
bash "$DIFF" "$TMP/old.lock" "$TMP/bad.lock" >"$TMP/bad.out" 2>/dev/null; rc=$?
check "malformed lock exits 2" 2 "$rc"
check "malformed lock prints no table/no-op line" "" "$(cat "$TMP/bad.out")"

bash "$DIFF" "$TMP/old.lock" >/dev/null 2>&1; rc=$?
check "missing argument exits 2" 2 "$rc"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
  exit 0
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
  exit 1
fi
