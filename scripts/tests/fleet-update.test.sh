#!/usr/bin/env bash
# Coverage for scripts/fleet-update.sh (the org.rh7.fleet-update daemon) and the
# `fleet_update` section of scripts/audit-device.sh.
#
# Run: ./scripts/tests/fleet-update.test.sh   (needs git, gpg, jq, python3)
#
# This script decides, unattended and as root, whether a Mac switches to new
# code. The properties pinned here are the ones whose failure is silent:
#   - it applies ONLY a channel tip signed by the pinned key, already in main,
#     and fast-forwarding from what it applied last — every other tip is
#     REFUSED with the contract's reason token and nothing is built;
#   - it never builds on battery / during a manual rebuild / under another run;
#   - a failure is classified (build vs activation vs brew) and the state file
#     always matches the rh-device-management `fleet_update` contract.
#
# Real git + real gpg verify against throwaway keys standing in for GitHub's
# web-flow key; nix, nix-env, the generation's `activate`, pmset, pgrep and sudo
# are stubs. FLEET_UPDATE_ROOT sandboxes every absolute path the script owns.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../fleet-update.sh"
AUDIT="$HERE/../audit-device.sh"

for tool in git gpg gpgconf jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is required" >&2; exit 1; }
done

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

# Short base dir: gpg-agent socket paths have a ~104-byte limit on macOS.
W=$(mktemp -d /tmp/fu.XXXXXX)
cleanup() {
  local h
  for h in "$W"/gpg-*; do [[ -d "$h" ]] && GNUPGHOME="$h" gpgconf --kill all >/dev/null 2>&1; done
  rm -rf "$W"
}
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ── Keys ─────────────────────────────────────────────────────────────────────
# mkkey <name> [faked-time] [expiry] — writes $W/<name>.asc, $W/<name>.fpr and a
# gpg wrapper $W/sign-<name> for git's gpg.program.
mkkey() {
  local name="$1" faked="${2:-}" expiry="${3:-never}" home="$W/gpg-$1"
  local faked_args=()
  [[ -n "$faked" ]] && faked_args=(--faked-system-time "$faked")
  mkdir -m 700 "$home"
  GNUPGHOME="$home" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    "${faked_args[@]}" --quick-gen-key "$name <$name@example.invalid>" ed25519 sign "$expiry" 2>/dev/null
  GNUPGHOME="$home" gpg --batch --armor --export >"$W/$name.asc"
  GNUPGHOME="$home" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}' >"$W/$name.fpr"
  {
    echo '#!/usr/bin/env bash'
    echo "export GNUPGHOME='$home'"
    if [[ -n "$faked" ]]; then
      # Sign "shortly after creation", while the key was still valid.
      echo "exec gpg --faked-system-time '20200101T120000!' \"\$@\""
    else
      echo 'exec gpg "$@"'
    fi
  } >"$W/sign-$name"
  chmod +x "$W/sign-$name"
}
mkkey pinned
mkkey other
mkkey expiring '20200101T000000!' 1d

# ── Origin repo ──────────────────────────────────────────────────────────────
git init -q --bare "$W/origin.git"
git init -q "$W/work"
gw() { git -C "$W/work" -c user.name=Test -c user.email=test@example.invalid "$@"; }
# commit <key|none> <msg> — empty commit on the work HEAD, prints its sha.
commit() {
  if [[ "$1" == none ]]; then
    gw -c commit.gpgsign=false commit -q --allow-empty -m "$2"
  else
    gw -c gpg.program="$W/sign-$1" commit -q --allow-empty -m "$2" -S"$(cat "$W/$1.fpr")"
  fi
  gw rev-parse HEAD
}
# refs <main-sha> [stable-sha] — force the origin branches.
refs() {
  gw push -q -f "$W/origin.git" "$1:refs/heads/main"
  if [[ -n "${2:-}" ]]; then
    gw push -q -f "$W/origin.git" "$2:refs/heads/fleet/stable"
  else
    gw push -q "$W/origin.git" ":refs/heads/fleet/stable" 2>/dev/null || true
  fi
}

C1=$(commit pinned "c1")
C2=$(commit pinned "c2")
UNSIGNED=$(commit none "unsigned on top of c2")
gw checkout -q --detach "$C2"
OTHER=$(commit other "signed by another key")
gw checkout -q --detach "$C2"
EXPIRED=$(commit expiring "signed by a since-expired key")
gw checkout -q --detach "$C2"
SIDE=$(commit pinned "signed, but never merged to main")

# ── Stubs ────────────────────────────────────────────────────────────────────
STUBS="$W/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/pmset" <<'EOF'
#!/usr/bin/env bash
echo "Now drawing from '${STUB_POWER:-AC Power}'"
EOF
cat >"$STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
# STUB_REBUILD=1: a rebuild is running from the start. STUB_REBUILD=after-build:
# one starts while the daemon is building (seen once something is in the store).
case "${STUB_REBUILD:-}" in
  1) exit 0 ;;
  after-build) [[ -n "$(ls -A "$STUB_STORE" 2>/dev/null)" ]] ;;
  *) exit 1 ;;
esac
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
EOF
cat >"$STUBS/nix-env" <<'EOF'
#!/usr/bin/env bash
# nix-env -p <profile> --set <out>: emulate system-N-link generations.
[[ "$1" == -p && "$3" == --set ]] || exit 2
p="$2" out="$4" n=1
while [[ -e "$p-$n-link" ]]; do n=$((n+1)); done
ln -s "$out" "$p-$n-link"
ln -sfn "$(basename "$p")-$n-link" "$p"
EOF
cat >"$STUBS/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$STUB_LOG"
[[ " $* " == *" build "* ]] || exit 0
if [[ -n "${STUB_BUILD_FAIL:-}" ]]; then echo "error: builder for '/nix/store/x.drv' failed" >&2; exit 1; fi
out="$STUB_STORE/system-$(git -C "$FLEET_UPDATE_ROOT/var/lib/rh7-fleet-update/dotfiles" rev-parse --short HEAD)"
mkdir -p "$out"
cat >"$out/activate" <<ACT
#!/usr/bin/env bash
echo "setting up /etc..."
echo "Homebrew bundle..."
if [[ -n "\${STUB_BREW_FAIL:-}" ]]; then
  echo "\\\`brew bundle\\\` failed! 1 Brewfile dependency failed to install"; exit 1
fi
echo "\\\`brew bundle\\\` complete! 3 Brewfile dependencies now installed."
if [[ -n "\${STUB_ACTIVATE_FAIL:-}" ]]; then echo "postActivation: boom"; exit 1; fi
if [[ -n "\${STUB_RACE:-}" ]]; then
  # A manual rebuild switched profile + current-system to ITS generation
  # while this activation ran; both links agree, neither is ours.
  mkdir -p "$STUB_STORE/manual"
  ln -sfn "$STUB_STORE/manual" "$FLEET_UPDATE_ROOT/nix/var/nix/profiles/system-99-link"
  ln -sfn system-99-link "$FLEET_UPDATE_ROOT/nix/var/nix/profiles/system"
  ln -sfn "$STUB_STORE/manual" "$FLEET_UPDATE_ROOT/run/current-system"
  exit 0
fi
ln -sfn "$out" "$FLEET_UPDATE_ROOT/run/current-system"
ACT
chmod +x "$out/activate"
echo "$out"
EOF
chmod +x "$STUBS"/*

# ── Harness ──────────────────────────────────────────────────────────────────
CASE=0
fresh() { # new sandbox root + stub store
  CASE=$((CASE+1))
  ROOT="$W/case$CASE"
  mkdir -p "$ROOT/nix/var/nix/profiles" "$ROOT/run" "$ROOT/store"
  STATE="$ROOT/var/lib/rh7-fleet-update/state.json"
  : >"$ROOT/stub.log"
}
run_fu() { # run_fu [args...] -> OUT, RC   (CHANNEL / PINNED overridable)
  OUT=$(env FLEET_UPDATE_ROOT="$ROOT" FLEET_UPDATE_REPO_URL="file://$W/origin.git" \
        PATH="$STUBS:$PATH" STUB_LOG="$ROOT/stub.log" STUB_STORE="$ROOT/store" \
        bash "$SCRIPT" --channel "${CHANNEL:-fleet/stable}" --flake-attr test-host \
        --signer-key "${PINNED:-$W/pinned.asc}" --primary-user tester "$@" 2>&1)
  RC=$?
}
field() { jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' "$STATE" 2>/dev/null; }
builds() { grep -c ' build ' "$ROOT/stub.log" || true; }

# The rh-device-management `fleet_update` contract, enforced on every state file.
validate_state() {
  jq -e '
    def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    (keys == ["applied_commit","channel","consecutive_failures","enabled","generation",
              "last_result","last_run_at","last_success_at","reason","schema","target_commit"])
    and .schema == 1 and .enabled == true
    and (.channel | IN("main", "fleet/stable"))
    and (.last_run_at | iso)
    and (.last_result | IN("applied", "no-op", "skipped", "failed", "refused"))
    and (.reason == null or (.reason | IN("on-battery", "lock-held", "rebuild-in-progress",
          "fetch-failed", "signature-invalid", "signer-key-expired", "not-fast-forward",
          "not-in-main", "build-failed", "activation-failed", "brew-failed", "unknown")))
    and (if .last_result == "refused" then (.reason | IN("signature-invalid",
          "signer-key-expired", "not-fast-forward", "not-in-main"))
         elif .last_result == "skipped" then (.reason | IN("on-battery", "lock-held",
          "rebuild-in-progress"))
         elif .last_result == "failed" then .reason != null
         else .reason == null end)
    and (.target_commit == null or (.target_commit | sha))
    and (.applied_commit == null or (.applied_commit | sha))
    and (.last_success_at == null or (.last_success_at | iso))
    and (.generation == null or (.generation | type == "number"))
    and (.consecutive_failures | type == "number" and . >= 0)' "$STATE" >/dev/null 2>&1 \
  && [[ -n "$(find "$STATE" -perm 0644)" ]]
}
# expect <label> <rc> <result> <reason|null>
expect() {
  check "$1: exit $2" "$RC" "$2"
  check "$1: last_result=$3" "$(field last_result)" "$3"
  check "$1: reason=$4" "$(field reason)" "$4"
  if validate_state; then good "$1: state matches the contract (mode 0644)"
  else bad "$1: state matches the contract (mode 0644)" "$(cat "$STATE" 2>/dev/null)"; fi
  [[ $RC -eq "$2" ]] || printf '      output:\n%s\n' "$(sed 's/^/        /' <<<"$OUT")"
}

# ── Cases ────────────────────────────────────────────────────────────────────
echo ""
echo "fleet-update — success, then no-op"
fresh; refs "$C2" "$C2"
run_fu
expect "signed tip in main" 0 applied null
check "applied_commit is the tip" "$(field applied_commit)" "$C2"
check "target_commit is the tip" "$(field target_commit)" "$C2"
check "generation recorded" "$(field generation)" "1"
check "consecutive_failures reset" "$(field consecutive_failures)" "0"
[[ "$(field last_success_at)" != null ]] && good "last_success_at set" || bad "last_success_at set" "null"
grep -q 'build .*darwinConfigurations."test-host".system' "$ROOT/stub.log" \
  && good "builds the baked-in flake attr" || bad "builds the baked-in flake attr" "$(cat "$ROOT/stub.log")"
grep -q 'sudo -n -u tester -- sudo -K' "$ROOT/stub.log" \
  && good "closes the primary user's sudo window first" || bad "closes the primary user's sudo window first" "$(cat "$ROOT/stub.log")"
check "checkout is detached at the tip" "$(git -C "$ROOT/var/lib/rh7-fleet-update/dotfiles" rev-parse HEAD)" "$C2"
[[ "$(readlink "$ROOT/run/current-system")" == "$ROOT/store/system-"* ]] \
  && good "generation activated" || bad "generation activated" "$(readlink "$ROOT/run/current-system")"

run_fu
expect "same commit, same generation" 0 no-op null
check "no second build" "$(builds)" "1"
check "applied_commit kept" "$(field applied_commit)" "$C2"

echo ""
echo "fleet-update — refusals (nothing is built)"
fresh; refs "$UNSIGNED" "$UNSIGNED"
run_fu
expect "unsigned tip" 3 refused signature-invalid
check "unsigned tip: no build" "$(builds)" "0"
check "unsigned tip: consecutive_failures" "$(field consecutive_failures)" "1"

fresh; refs "$OTHER" "$OTHER"
run_fu
expect "tip signed by another key" 3 refused signature-invalid
check "other key: no build" "$(builds)" "0"

fresh; refs "$EXPIRED" "$EXPIRED"
PINNED="$W/expiring.asc" run_fu
expect "tip signed by a pinned key that has since expired" 3 refused signer-key-expired

fresh; refs "$C2" "$SIDE"
run_fu
expect "signed tip not in main" 3 refused not-in-main
check "not in main: no build" "$(builds)" "0"

fresh; refs "$C2" "$C2"
run_fu
refs "$C2" "$C1"
run_fu
expect "channel rewound below applied commit" 3 refused not-fast-forward
check "rewind: applied_commit kept" "$(field applied_commit)" "$C2"
check "rewind: only the first run built" "$(builds)" "1"

echo ""
echo "fleet-update — preconditions (skipped, nothing fetched)"
fresh; refs "$C2" "$C2"
STUB_POWER='Battery Power' run_fu
expect "on battery" 0 skipped on-battery
[[ ! -d "$ROOT/var/lib/rh7-fleet-update/dotfiles" ]] && good "on battery: nothing fetched" \
  || bad "on battery: nothing fetched" "checkout exists"
STUB_POWER='Battery Power' run_fu --force-check
expect "on battery with --force-check" 0 applied null

fresh; refs "$C2" "$C2"
STUB_REBUILD=1 run_fu
expect "darwin-rebuild running" 0 skipped rebuild-in-progress

fresh; refs "$C2" "$C2"
STUB_REBUILD=after-build run_fu
expect "rebuild started during the build" 0 skipped rebuild-in-progress
[[ ! -e "$ROOT/nix/var/nix/profiles/system" ]] && good "rebuild during build: profile untouched" \
  || bad "rebuild during build: profile untouched" "$(readlink "$ROOT/nix/var/nix/profiles/system")"

fresh; refs "$C2" "$C2"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"; echo $$ >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu
check "another run holds the lock: exit 0" "$RC" "0"
[[ ! -e "$STATE" ]] && good "lock-held: state left to the holder" || bad "lock-held: state left to the holder" "$(cat "$STATE")"
grep -q 'skipped (lock-held)' <<<"$OUT" && good "lock-held: logged" || bad "lock-held: logged" "$OUT"
check "lock-held: foreign lock left alone" "$(cat "$ROOT/var/run/rh7-fleet-update.lock/pid")" "$$"

echo ""
echo "fleet-update — failures"
fresh; refs "$C2" "$C2"
STUB_BUILD_FAIL=1 run_fu
expect "build fails" 1 failed build-failed
check "build fails: applied_commit stays null" "$(field applied_commit)" "null"
check "build fails: consecutive_failures" "$(field consecutive_failures)" "1"

fresh; refs "$C1" "$C1"
run_fu
refs "$C2" "$C2"
STUB_BREW_FAIL=1 run_fu
expect "brew bundle fails during activation" 1 failed brew-failed
check "brew fails: applied_commit not advanced" "$(field applied_commit)" "$C1"
check "brew fails: new nix generation still recorded" "$(field generation)" "2"

fresh; refs "$C2" "$C2"
STUB_ACTIVATE_FAIL=1 run_fu
expect "activation fails after brew" 1 failed activation-failed

fresh; refs "$C2" "$C2"
STUB_RACE=1 run_fu
expect "manual rebuild replaced the system mid-activation" 1 failed activation-failed
check "race: applied_commit not claimed" "$(field applied_commit)" "null"

fresh; refs "$C2" "$C2"
TMPDIR="$W/does-not-exist" run_fu
expect "isolated GNUPGHOME cannot be created" 3 refused signature-invalid

fresh; refs "$C2"   # no fleet/stable branch yet (before the owner bootstraps it)
run_fu
expect "channel branch missing" 1 failed fetch-failed

fresh; mkdir -p "$(dirname "$STATE")"; echo '{"schema": 1, "applied_commit": "nope"}' >"$STATE"
before=$(cat "$STATE")
refs "$C2" "$C2"
run_fu
check "corrupt state: exit 1" "$RC" "1"
check "corrupt state: file left for the audit to flag" "$(cat "$STATE")" "$before"
check "corrupt state: no build" "$(builds)" "0"

fresh; refs "$C2" "$C2"
run_fu
jq '.last_success_at = "garbage"' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
before=$(cat "$STATE")
run_fu
check "state outside the contract: exit 1" "$RC" "1"
check "state outside the contract: file left untouched" "$(cat "$STATE")" "$before"

echo ""
echo "fleet-update — canary channel, dry-run"
fresh; refs "$C2"
CHANNEL=main run_fu
expect "canary follows main" 0 applied null
check "canary: channel recorded" "$(field channel)" "main"

fresh; refs "$C2" "$C2"
run_fu --dry-run
check "dry-run: exit 0" "$RC" "0"
[[ ! -e "$STATE" ]] && good "dry-run: no state written" || bad "dry-run: no state written" "$(cat "$STATE")"
check "dry-run: no build" "$(builds)" "0"
grep -q 'would build' <<<"$OUT" && good "dry-run: reports what it would apply" \
  || bad "dry-run: reports what it would apply" "$OUT"
fresh; refs "$UNSIGNED" "$UNSIGNED"
run_fu --dry-run
check "dry-run still refuses an unsigned tip" "$RC" "3"

echo ""
echo "fleet-update — usage"
fresh
run_fu --channel nightly
check "unknown channel rejected" "$RC" "64"

# ── audit-device.sh collect_fleet_update ─────────────────────────────────────
echo ""
echo "audit-device.sh — fleet_update section"
# shellcheck disable=SC1090
eval "$(sed -n '/^collect_fleet_update() {/,/^}/p' "$AUDIT")"
if ! declare -F collect_fleet_update >/dev/null; then
  echo "FATAL: could not extract collect_fleet_update from $AUDIT" >&2; exit 1
fi
A="$W/audit"; mkdir -p "$A"; : >"$A/plist"
# shellcheck disable=SC2034  # OS is read by the extracted collect_fleet_update
OS=Darwin

check "no plist -> disabled" "$(collect_fleet_update "$A/absent.plist" "$A/state.json")" '{"enabled": false}'
check "plist, no state -> state-unreadable" \
  "$(collect_fleet_update "$A/plist" "$A/missing.json")" '{"enabled": true, "error": "state-unreadable"}'
echo 'not json' >"$A/bad.json"
check "plist, invalid state -> state-unreadable" \
  "$(collect_fleet_update "$A/plist" "$A/bad.json")" '{"enabled": true, "error": "state-unreadable"}'
# A real state file from the success case above, plus a field outside the contract.
jq '. + {"secret": "must-not-leak"}' "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/state.json"
got=$(collect_fleet_update "$A/plist" "$A/state.json")
check "valid state -> exactly the contract fields" \
  "$(jq -c 'keys' <<<"$got")" \
  '["applied_commit","channel","consecutive_failures","enabled","generation","last_result","last_run_at","last_success_at","reason","schema","target_commit"]'
check "valid state -> values passed through" "$(jq -r '.applied_commit' <<<"$got")" "$C2"
jq '.reason = "made-up"' "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/off.json"
check "reason outside the closed set -> state-unreadable" \
  "$(collect_fleet_update "$A/plist" "$A/off.json")" '{"enabled": true, "error": "state-unreadable"}'
for bad_state in '.last_run_at = "garbage"' '.reason = "fetch-failed"' \
                 '.last_result = "refused" | .reason = "on-battery"' 'del(.target_commit)' \
                 '.applied_commit = "abc"' '.consecutive_failures = -1'; do
  jq "$bad_state" "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/off.json"
  check "contract violation ($bad_state) -> state-unreadable" \
    "$(collect_fleet_update "$A/plist" "$A/off.json")" '{"enabled": true, "error": "state-unreadable"}'
done
# shellcheck disable=SC2034
OS=Linux
check "Linux -> disabled" "$(collect_fleet_update "$A/plist" "$A/state.json")" '{"enabled": false}'

echo ""
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
