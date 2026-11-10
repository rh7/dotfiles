#!/usr/bin/env bash
# Fixture tests for the .sops.yaml recipient edit (scripts/lib/sops-recipients.sh)
# and sops-add-host.sh's refusal conditions — rh7/rh-device-management#310.
#
# Run: bash scripts/tests/sops-recipients.test.sh
#
# The predecessor of this edit (the old setup-secrets.sh) matched sed anchors that
# no longer existed in .sops.yaml, changed nothing, and printed success; five
# hosts then could not decrypt on their first rebuild. So these pin, against a
# copy of the REAL .sops.yaml:
#   - a new host lands as one anchor line plus one alias in the flow sequence
#   - a re-run is a no-op that SAYS so (status 10) and leaves the file byte-identical
#   - every malformed input or unrecognised shape is refused with the file untouched
# No network, no sops, no age: the end-to-end updatekeys run is exercised by hand
# against a throwaway key (see the PR), not in CI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/sops-recipients.sh
source "$REPO_ROOT/scripts/lib/sops-recipients.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
add() { local rc=0; sops_yaml_add_recipient "$@" 2>"$T/stderr" || rc=$?; echo "$rc"; }

# Deterministic, well-formed (age1 + 58 bech32 chars) test keys — never real ones.
K1="age1$(printf 'q%.0s' {1..58})"
K2="age1$(printf 'p%.0s' {1..58})"
REAL_KEY=$(grep -oE 'age1[0-9a-z]{58}' "$REPO_ROOT/.sops.yaml" | head -1)

flow_line() { grep -E '^[[:space:]]*(-[[:space:]]+)?age:[[:space:]]*\[' "$1"; }

echo "sops-recipients.sh — add a host to the real .sops.yaml"
F="$T/sops.yaml"
cp "$REPO_ROOT/.sops.yaml" "$F"
ORIG_FLOW=$(flow_line "$F")

check "fresh host is added (status 0)" "0" "$(add "$F" testhost "$K1")"
check "exactly one line added" \
  "$(( $(wc -l < "$REPO_ROOT/.sops.yaml") + 1 ))" "$(wc -l < "$F" | tr -d ' ')"
check "anchor line declares the key" "1" \
  "$(grep -cE "^[[:space:]]+- &testhost[[:space:]]+$K1\$" "$F")"
check "anchor lands directly after the last existing anchor" "testhost" \
  "$(grep -E '^[[:space:]]+- &[A-Za-z0-9-]+[[:space:]]+age1' "$F" | tail -1 | sed -E 's/.*&([A-Za-z0-9-]+).*/\1/')"
check "alias is appended INSIDE the flow sequence" \
  "$(sed -E 's/[[:space:]]*\][[:space:]]*$/, *testhost ]/' <<<"$ORIG_FLOW")" "$(flow_line "$F")"
check "anchor indentation matches its siblings" "1" \
  "$(grep -E '^[[:space:]]+- &' "$F" | sed -E 's/-.*//' | sort -u | wc -l | tr -d ' ')"

cp "$F" "$T/after-first"
check "re-run reports already-declared (status 10)" "10" "$(add "$F" testhost "$K1")"
check "re-run leaves the file byte-identical" "same" \
  "$(cmp -s "$F" "$T/after-first" && echo same || echo changed)"

if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah; then
  check "result parses, and the new alias resolves to the new key" "$K1" \
    "$(yq '.creation_rules[0].key_groups[0].age | explode(.) | .[-1]' "$F")"
else
  echo "  - (mikefarah yq not installed: YAML parse check skipped; structure pinned above)"
fi

echo
echo "sops-recipients.sh — refusals leave the file untouched"
refused() { # refused <name> <file> <host> <key>
  local before; before=$(cat "$2")
  local rc; rc=$(add "$2" "$3" "$4")
  if [[ "$rc" == "1" && "$(cat "$2")" == "$before" && -s "$T/stderr" ]]; then ok "$1"
  else bad "$1" "rc=$rc, changed=$([[ "$(cat "$2")" == "$before" ]] && echo no || echo yes), stderr=$(cat "$T/stderr")"; fi
}
cp "$REPO_ROOT/.sops.yaml" "$F"
refused "key without age1 prefix"        "$F" newhost "${K1#age1}"
refused "key one char short"             "$F" newhost "${K1%q}"
refused "uppercase key"                  "$F" newhost "$(tr '[:lower:]' '[:upper:]' <<<"$K1")"
refused "ssh key instead of age key"     "$F" newhost "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"
refused "host name with a flow indicator" "$F" "new,host" "$K1"
refused "host name with an alias char"   "$F" "*newhost" "$K1"
refused "empty host name"                "$F" "" "$K1"
refused "existing key under a new name"  "$F" newhost "$REAL_KEY"
refused "existing name with a different key" "$F" admin "$K2"

cat > "$T/block.yaml" <<EOF
keys:
  - &admin $REAL_KEY
creation_rules:
  - path_regex: secrets/secrets\.yaml\$
    key_groups:
      - age:
          - *admin
EOF
refused "block-style age list (the shape the old sed expected)" "$T/block.yaml" newhost "$K1"

cat > "$T/two-rules.yaml" <<EOF
keys:
  - &admin $REAL_KEY
creation_rules:
  - path_regex: secrets/secrets\.yaml\$
    key_groups:
      - age: [ *admin ]
  - path_regex: secrets/other\.yaml\$
    key_groups:
      - age: [ *admin ]
EOF
refused "two creation rules (which one gets the host is a human decision)" "$T/two-rules.yaml" newhost "$K1"

cat > "$T/literal.yaml" <<EOF
keys:
  - &admin $REAL_KEY
creation_rules:
  - path_regex: secrets/secrets\.yaml\$
    key_groups:
      - age: [ *admin, $K2 ]
EOF
refused "literal key inside the age list" "$T/literal.yaml" newhost "$K1"

cat > "$T/dangling.yaml" <<EOF
keys:
  - &admin $REAL_KEY
creation_rules:
  - path_regex: secrets/secrets\.yaml\$
    key_groups:
      - age: [ *admin, *newhost ]
EOF
refused "alias present but anchor missing" "$T/dangling.yaml" newhost "$K1"

echo
echo "sops-recipients.sh — completes a half-declared host"
cat > "$T/half.yaml" <<EOF
keys:
  - &admin   $REAL_KEY
  - &newhost $K1
creation_rules:
  - path_regex: secrets/secrets\.yaml\$
    key_groups:
      - age: [ *admin ]
EOF
check "anchor present, alias missing → alias added (status 0)" "0" "$(add "$T/half.yaml" newhost "$K1")"
check "no duplicate anchor written" "1" "$(grep -c '&newhost' "$T/half.yaml")"
check "alias appended" "      - age: [ *admin, *newhost ]" "$(flow_line "$T/half.yaml")"

echo
echo "sops-recipients.sh — recipients read from sops metadata"
check "real secrets.yaml lists one recipient per declared anchor" \
  "$(grep -cE '^[[:space:]]+- &[A-Za-z0-9-]+[[:space:]]+age1' "$REPO_ROOT/.sops.yaml")" \
  "$(sops_metadata_recipients "$REPO_ROOT/secrets/secrets.yaml" | wc -l | tr -d ' ')"
check "every declared key is a recipient (declared == applied)" "" \
  "$(comm -3 <(grep -oE 'age1[0-9a-z]{58}' "$REPO_ROOT/.sops.yaml" | sort -u) \
             <(sops_metadata_recipients "$REPO_ROOT/secrets/secrets.yaml"))"

echo
echo "config-service.sh — the resolver is loaded from collector-runner.sh, not copied"
check "load_config_service_resolver defines find_config_service" "yes" \
  "$(bash -c "source '$REPO_ROOT/scripts/lib/config-service.sh' && load_config_service_resolver '$REPO_ROOT' && declare -F find_config_service >/dev/null && echo yes || echo no")"
check "…and fails (nonzero, nothing defined) when the block is missing" "no" \
  "$(bash -c "source '$REPO_ROOT/scripts/lib/config-service.sh'; load_config_service_resolver '$T/nowhere' 2>/dev/null; declare -F find_config_service >/dev/null && echo yes || echo no")"

echo
echo "sops-add-host.sh — refuses before touching anything"
# A scratch repo whose sops/gh FAIL if invoked: every refusal below must happen
# before either tool runs.
R="$T/repo"; mkdir -p "$R/scripts/lib" "$R/secrets" "$T/bin"
cp "$REPO_ROOT/scripts/sops-add-host.sh" "$R/scripts/"
cp "$REPO_ROOT/scripts/lib/sops-recipients.sh" "$R/scripts/lib/"
cp "$REPO_ROOT/.sops.yaml" "$R/.sops.yaml"
echo "placeholder: true" > "$R/secrets/secrets.yaml"
for tool in sops gh; do
  printf '#!/bin/sh\necho "%s must not run" >&2\nexit 99\n' "$tool" > "$T/bin/$tool"
  chmod +x "$T/bin/$tool"
done
touch "$T/age-key"
git -C "$R" init -q -b main
git -C "$R" -c user.email=t@t -c user.name=t add -A
git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
run_add() { (cd "$R" && PATH="$T/bin:$PATH" SOPS_AGE_KEY_FILE="$T/age-key" bash scripts/sops-add-host.sh "$@" >"$T/out" 2>&1); echo $?; }
pristine() { [[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ]] && echo yes || echo no; }

check "invalid pubkey refused (exit 1)" "1" "$(run_add newhost age1bad)"
check "on main refused (exit 1)" "1" "$(run_add newhost "$K1")"
grep -q "refusing to run on 'main'" "$T/out" && ok "…and says why" || bad "…and says why" "$(cat "$T/out")"
git -C "$R" checkout -q -b sops/add-newhost
echo "# dirty" >> "$R/.sops.yaml"
check "dirty tracked tree refused (exit 1)" "1" "$(run_add newhost "$K1")"
grep -q "tracked changes present" "$T/out" && ok "…and says why" || bad "…and says why" "$(cat "$T/out")"
git -C "$R" checkout -q -- .sops.yaml
check "nothing was modified by any refusal" "yes" "$(pristine)"
if grep -q "must not run" "$T/out"; then bad "sops/gh never invoked" "$(cat "$T/out")"; else ok "sops/gh never invoked"; fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
