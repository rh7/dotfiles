#!/usr/bin/env bash
# Fixture tests for scripts/ci/check-darwin-cache.sh — the binary-cache gate in
# the weekly flake.lock bot PR. Offline: fixture `nix derivation show -r` JSON
# (both the current and the legacy format) plus a fixture "cache" (a list of
# output hashes it holds) through the script's test seams.
#
# Run: bash scripts/tests/check-darwin-cache.test.sh
#
# The failure modes that matter: a heavy uncached package hidden (the owner
# merges a lock that makes every Mac compile for an hour), and trivial local
# glue (system-path, plists, activation) or packages behind a CACHED parent
# reported as heavy (a gate that always fails gets ignored).
# shellcheck disable=SC2016 # backticks in expectations are Markdown, not shell
set -uo pipefail

CHECK="$(cd "$(dirname "$0")/../ci" && pwd)/check-darwin-cache.sh"
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
lacks() { # lacks <name> <needle> <haystack>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected [$2] in [$3]"; fi
}

h() { printf "%032d" 0 | tr 0 "$1"; } # 32-char fake store hash
# --- current format (Nix >= 2.33): {version, derivations}, basenames ----------
# drv <char> <name> <env-json> <outputs-json> <input-drv-basenames...>
drv() {
  local c=$1 name=$2 env=$3 outs=$4; shift 4
  local ins='{}'
  for i in "$@"; do ins=$(jq -c --arg i "$i" '. + {($i): {dynamicOutputs: {}, outputs: ["out"]}}' <<<"$ins"); done
  jq -nc --arg k "$(h "$c")-$name.drv" --arg n "$name" --argjson env "$env" --argjson outs "$outs" --argjson ins "$ins" \
    '{($k): ({name: $n, system: "aarch64-darwin", builder: "/bin/sh", args: [], env: $env, outputs: $outs, inputs: {drvs: $ins, srcs: []}, version: 4}
             + (if $env.__sa then {structuredAttrs: $env.__sa} else {} end) | .env |= del(.__sa))}'
}
out() { printf '{"out":{"path":"%s-%s"}}' "$(h "$1")" "$2"; }
d() { printf '%s-%s.drv' "$(h "$1")" "$2"; }

mkdir -p "$TMP/fx" "$TMP/cwd"
{
  # system: runCommandLocal-style, never substituted → walked into.
  drv a darwin-system '{"preferLocalBuild":"1","allowSubstitutes":""}' "$(out A darwin-system)" \
    "$(d b system-path)" "$(d f heavy-1.0)" "$(d j sops-install-secrets-0.0.1)" "$(d k source)" "$(d l launchd.plist)" "$(d n sa-nosub)"
  # system-path: structured attrs, allowSubstitutes = false (a real `false`).
  drv b system-path '{"__sa":{"preferLocalBuild":true,"allowSubstitutes":false}}' "$(out B system-path)" \
    "$(d c cached-1.0)"
  # cached package: its uncached build input must never be walked.
  drv c cached-1.0 '{}' "$(out C cached-1.0)" "$(d e deep-uncached-1.0)"
  drv e deep-uncached-1.0 '{}' "$(out E deep-uncached-1.0)"
  # heavy: `out` cached but `dev` missing → still built; its uncached dep too.
  drv f heavy-1.0 '{}' \
    "$(printf '{"out":{"path":"%s-heavy-1.0"},"dev":{"path":"%s-heavy-1.0-dev"}}' "$(h F)" "$(h G)")" \
    "$(d i libheavy-2.0)"
  drv i libheavy-2.0 '{}' "$(out I libheavy-2.0)"
  drv j sops-install-secrets-0.0.1 '{}' "$(out J sops-install-secrets-0.0.1)"
  # fixed-output source: no output path in this format; never walked or asked.
  drv k source '{"__sa":{"preferLocalBuild":true}}' '{"out":{"hash":"sha256-x","method":"nar"}}'
  # preferLocalBuild only: asked, missing → built (not reported), walked into.
  drv l launchd.plist '{"preferLocalBuild":"1"}' "$(out L launchd.plist)" "$(d m tool-1.0)"
  drv m tool-1.0 '{}' "$(out M tool-1.0)"
  # structured allowSubstitutes = false, no preferLocalBuild → trivial.
  drv n sa-nosub '{"__sa":{"allowSubstitutes":false}}' "$(out N sa-nosub)"
} | jq -s '{version: 4, derivations: add}' > "$TMP/fx/mac-new.json"

# --- legacy format: full paths, inputDrvs, env.__json -------------------------
jq -n --arg s /nix/store --arg r "$(h p)" --arg L "$(h q)" --arg C "$(h r)" --arg J "$(h s)" \
  --arg oP "$(h P)" --arg oQ "$(h Q)" --arg oR "$(h R)" --arg oS "$(h S)" '
  def o($h; $n): {out: {path: "\($s)/\($h)-\($n)"}};
  def ins($l): $l | map({key: "\($s)/\(.).drv", value: ["out"]}) | from_entries;
  {
    "\($s)/\($r)-darwin-system.drv": {name: "darwin-system", env: {preferLocalBuild: "1", allowSubstitutes: ""},
      outputs: o($oP; "darwin-system"), inputDrvs: ins(["\($L)-legacy-heavy-3.0", "\($C)-legacy-cached-1.0", "\($J)-json-attrs"]), inputSrcs: []},
    "\($s)/\($L)-legacy-heavy-3.0.drv": {name: "legacy-heavy-3.0", env: {}, outputs: o($oQ; "legacy-heavy-3.0"), inputDrvs: {}, inputSrcs: []},
    "\($s)/\($C)-legacy-cached-1.0.drv": {name: "legacy-cached-1.0", env: {}, outputs: o($oR; "legacy-cached-1.0"), inputDrvs: {}, inputSrcs: []},
    "\($s)/\($J)-json-attrs.drv": {name: "json-attrs", env: {__json: "{\"preferLocalBuild\":true,\"allowSubstitutes\":false}"},
      outputs: o($oS; "json-attrs"), inputDrvs: {}, inputSrcs: []}
  }' > "$TMP/fx/mac-legacy.json"

# The cache holds: cached-1.0, heavy-1.0 `out` (not `dev`), legacy-cached-1.0.
printf '%s\n' "$(h C)" "$(h F)" "$(h R)" > "$TMP/present"

empty_allow="$TMP/empty-allowlist"; : > "$empty_allow"
run() { # run [env...] → stdout in $TMP/out, exit code in $rc
  (cd "$TMP/cwd" && env CHECK_DARWIN_CACHE_FIXTURES="$TMP/fx" CHECK_DARWIN_CACHE_PRESENT="$TMP/present" \
    DARWIN_CACHE_ALLOWLIST_FILE="$empty_allow" "$@" bash "$CHECK" >"$TMP/out" 2>"$TMP/err"); rc=$?
}
row() { grep -F "| \`$1\` |" "$TMP/out"; }

echo "check-darwin-cache.sh"

run
check "uncached heavy derivation → exit 1" 1 "$rc"
contains "failure headline" "❌" "$(cat "$TMP/out")"
new=$(row mac-new)
contains "heavy package with one uncached output is reported" '`heavy-1.0`' "$new"
contains "uncached dependency of a heavy package is reported" '`libheavy-2.0`' "$new"
contains "uncached dependency of trivial glue is reported" '`tool-1.0`' "$new"
contains "non-allowlisted sops-install-secrets is reported" '`sops-install-secrets-0.0.1`' "$new"
lacks "inputs of a CACHED package are never walked" 'deep-uncached' "$new"
lacks "cached package is not reported" '`cached-1.0`' "$new"
lacks "preferLocalBuild/!allowSubstitutes system drv is not reported" 'darwin-system' "$new"
lacks "structured-attrs allowSubstitutes=false system-path is not reported" 'system-path' "$new"
lacks "structured allowSubstitutes=false alone is trivial" 'sa-nosub' "$new"
lacks "preferLocalBuild glue is not reported" 'launchd.plist' "$new"
lacks "fixed-output source is not reported" '`source`' "$new"
legacy=$(row mac-legacy)
contains "legacy format: heavy uncached reported" '`legacy-heavy-3.0`' "$legacy"
lacks "legacy format: cached package not reported" 'legacy-cached' "$legacy"
lacks "legacy format: env.__json allowSubstitutes=false is trivial" 'json-attrs' "$legacy"

printf '# by design\nsops-install-secrets-*   # trailing comment\n' > "$TMP/allow"
run DARWIN_CACHE_ALLOWLIST_FILE="$TMP/allow"
check "allowlist file: other heavy builds still fail" 1 "$rc"
lacks "allowlisted package leaves the host row" 'sops-install' "$(row mac-new)"
contains "allowlisted package is listed separately" 'Allowlisted by-design local builds' "$(grep -F sops-install-secrets-0.0.1 "$TMP/out")"

touch "$TMP/cwd/tool-zzz" # an unquoted glob would expand to this and miss tool-1.0
run DARWIN_CACHE_ALLOWLIST_FILE="$TMP/allow" DARWIN_CACHE_ALLOWLIST='heavy-* libheavy-2.0
tool-* legacy-heavy-*'
check "everything heavy allowlisted → exit 0" 0 "$rc"
contains "pass headline" "✅" "$(cat "$TMP/out")"
check "pass: no host row lists a package" "2" "$(grep -c '| — |' "$TMP/out")"

run DARWIN_CACHE_ALLOWLIST='libheavy.2.0 heavy-1 *-heavy-3.0 tool-1.0 sops-*'
lacks "allowlist globs are anchored and '.' is literal" '`heavy-1.0`' "$(grep -F 'Allowlisted' "$TMP/out")"
contains "unmatched heavy stays in the row" '`libheavy-2.0`' "$(row mac-new)"

# Fail closed: an unreachable cache is "could not decide" (2), never a pass.
run CHECK_DARWIN_CACHE_PRESENT= CACHE_URL=http://127.0.0.1:9 CACHE_RETRIES=0
check "unreachable cache → exit 2" 2 "$rc"
check "unreachable cache → no report" "" "$(cat "$TMP/out")"

run CHECK_DARWIN_CACHE_PRESENT="$TMP/nope"
check "unreadable cache fixture → exit 2" 2 "$rc"

mkdir -p "$TMP/two-roots"
jq --arg k "$(h z)-stray.drv" '.derivations += {($k): {name: "stray", env: {}, outputs: {}, inputs: {drvs: {}, srcs: []}}}' \
  "$TMP/fx/mac-new.json" > "$TMP/two-roots/mac.json"
run CHECK_DARWIN_CACHE_FIXTURES="$TMP/two-roots"
check "graph without a unique system derivation → exit 2" 2 "$rc"

mkdir -p "$TMP/none"
run CHECK_DARWIN_CACHE_FIXTURES="$TMP/none"
check "no hosts → exit 2 (never vacuously green)" 2 "$rc"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
  exit 0
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
  exit 1
fi
