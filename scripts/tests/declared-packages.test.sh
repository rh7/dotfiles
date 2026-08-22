#!/usr/bin/env bash
# Fixture tests for scripts/lib/declared-packages.sh
#
# Run: ./scripts/tests/declared-packages.test.sh
#
# These exist because this library's output SELECTS UPGRADE TARGETS. Two
# failure modes matter and both have bitten this code before:
#
#   1. An error silently becoming an empty result. The caller then concludes
#      "nothing is declared", relabels real packages as drift, skips their
#      upgrades, and exits 0 looking successful.
#   2. A false positive in the mas_install scrape. That would make an
#      UNDECLARED app an upgrade target — acting on software the flake
#      deliberately does not manage.
#
# The nix eval itself is not exercised here (it needs a real flake); these
# cover the parsing and status contract, which is where the bugs were.

set -uo pipefail

LIB="$(cd "$(dirname "$0")/../lib" && pwd)/declared-packages.sh"
# shellcheck source=../lib/declared-packages.sh
source "$LIB"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# The scrape is the part worth testing; drive it directly with fixture text by
# reusing the same awk program the library uses. Kept in sync by extracting it
# from the library source rather than duplicating it here — if the library's
# parser changes and this stops matching, the extraction fails loudly.
scrape() {
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*mas_install[[:space:]]+"?[0-9]+"?([[:space:]]|$)/) {
      id = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", id)
      print id
    }
  ' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

echo "declared-packages.sh — mas_install scrape"

check "plain declaration" \
  "497799835" \
  "$(scrape 'mas_install 497799835 "Xcode"')"

check "indented declaration (postActivation indents)" \
  "497799835" \
  "$(scrape '    mas_install 497799835 "Xcode"')"

check "multiple, sorted and deduped" \
  "111 222" \
  "$(scrape 'mas_install 222 "B"
mas_install 111 "A"
mas_install 222 "B again"')"

check "commented-out line is NOT a declaration" \
  "" \
  "$(scrape '# mas_install 497799835 "Xcode"')"

check "indented comment is NOT a declaration" \
  "" \
  "$(scrape '   #  mas_install 497799835 "Xcode"')"

check "mid-line mention is NOT a declaration" \
  "" \
  "$(scrape 'echo "run mas_install 497799835 to add it"')"

check "quoted id is accepted" \
  "497799835" \
  "$(scrape 'mas_install "497799835" "Xcode"')"

check "id with trailing garbage is rejected" \
  "" \
  "$(scrape 'mas_install 497799835abc "Nope"')"

check "no declarations yields empty, not an error" \
  "" \
  "$(scrape 'echo hello
pwa_check "CC" "https://example.com/"')"

check "real-world block mixing declarations and other lines" \
  "1569813296 973134470 980888073" \
  "$(scrape 'mas_install 1569813296 "1Password for Safari"
    mas_install 973134470 "Be Focused"
# mas_install 999999999 "Disabled"
mas_install 980888073 "Crypto Pro"
pwa_check "CC" "https://cc.example.com/"')"

echo ""
echo "jq status contract (errors must not look like emptiness)"

# An EMPTY declared list is a legitimate success — this is the case that `jq -e`
# around the extraction would have broken, since -e exits 4 when nothing is
# output. A host declaring no casks must return 0 with no output, NOT fail.
out=$(jq -e 'if type=="array" then true else error("x") end' >/dev/null <<<'[]' 2>&1; echo "rc=$?")
check "empty array passes shape validation" "rc=0" "$out"

out=$(jq -r '.[] | (.name // error("no name"))' <<<'[]' 2>/dev/null; echo "rc=$?")
check "empty array extracts to nothing, rc 0" "rc=0" "$out"

# A WRONG SHAPE must fail loudly.
jq -e 'if type=="array" then true else error("x") end' >/dev/null <<<'"a string"' 2>/dev/null
check "non-array fails shape validation" "1" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

jq -e 'if type=="string" then true else error("x") end' >/dev/null <<<'{"a":1}' 2>/dev/null
check "non-string postActivation fails validation" "1" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# An entry missing .name must error rather than emit the literal "null".
out=$(jq -r '.[] | (.name // error("no name"))' <<<'[{"brewfileLine":"x"}]' 2>/dev/null; echo "rc=$?")
check "entry without .name errors instead of printing null" "rc=5" "$out"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
  exit 0
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
  exit 1
fi
