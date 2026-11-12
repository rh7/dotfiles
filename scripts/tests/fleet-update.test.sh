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
gw checkout -q --detach "$C2"
C3=$(commit pinned "c3: newer main")
gw checkout -q --detach "$C2"
LOCAL=$(commit pinned "local build, never pushed")
# Two signed branches off C2, merged on main: DIV_A and DIV_B are both in main,
# neither is an ancestor of the other.
gw checkout -q --detach "$C2"
DIV_A=$(commit pinned "div a")
gw checkout -q --detach "$C2"
DIV_B=$(commit pinned "div b")
gw -c gpg.program="$W/sign-pinned" merge -q --no-ff -m "merge div a" -S"$(cat "$W/pinned.fpr")" "$DIV_A"
DIV_MAIN=$(gw rev-parse HEAD)

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
if [[ " $* " == *" eval "* ]]; then
  # The Dock declaration of the checked-out commit: STUB_DOCK_APPS is the
  # evaluated persistent-apps value (unset = null = Dock unmanaged).
  [[ -z "${STUB_EVAL_FAIL:-}" ]] || { echo "error: evaluation aborted" >&2; exit 1; }
  echo "{\"user\":\"tester\",\"apps\":${STUB_DOCK_APPS:-null}}"
  exit 0
fi
[[ " $* " == *" build "* ]] || exit 0
if [[ -n "${STUB_BUILD_FAIL:-}" ]]; then echo "error: builder for '/nix/store/x.drv' failed" >&2; exit 1; fi
if [[ -n "${STUB_PIN_DURING_BUILD:-}" ]]; then
  # The user pins an app while the (hours-long) build runs.
  dp="$FLEET_UPDATE_ROOT/Users/tester/Library/Preferences/com.apple.dock.plist"
  jq --arg u "$STUB_PIN_DURING_BUILD" '.["persistent-apps"] += [{"tile-data": {"file-data": {"_CFURLString": $u}}, "tile-type": "file-tile"}]' \
    "$dp" >"$dp.tmp" && mv "$dp.tmp" "$dp"
fi
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
if [[ -n "\${STUB_NO_GUI:-}" ]]; then
  echo "Activating home-manager configuration for tester"
  echo "rh7: no GUI login session for tester — LaunchAgents installed; they load at the next login"
fi
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
cat >"$STUBS/plutil" <<'EOF'
#!/usr/bin/env bash
# plutil -extract <keypath> raw -o - <file>, over a JSON stand-in for the
# binary plist: scalars print, arrays/dicts print their count (as plutil does).
[[ "$1" == -extract && "$3" == raw && "$4" == -o && "$5" == - ]] || exit 2
jq -er --arg kp "$2" '
  getpath($kp | split(".") | map(if test("^[0-9]+$") then tonumber else . end))
  | if . == null then error("no value") elif type == "array" or type == "object" then length else . end' \
  "$6" 2>/dev/null
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
    ((keys - ["dock_protect"]) == ["applied_commit","channel","consecutive_failures","enabled","generation",
              "last_result","last_run_at","last_success_at","reason","schema","target_commit"])
    and .schema == 1 and .enabled == true
    and (.channel | IN("main", "fleet/stable"))
    and (.last_run_at | iso)
    and (.last_result | IN("applied", "no-op", "skipped", "failed", "refused"))
    and (.reason == null or (.reason | IN("on-battery", "lock-held", "rebuild-in-progress",
          "channel-behind", "dock-protect", "fetch-failed", "signature-invalid", "signer-key-expired",
          "not-fast-forward", "not-in-main", "build-failed", "activation-failed",
          "brew-failed", "unknown")))
    and (if .last_result == "refused" then (.reason | IN("signature-invalid",
          "signer-key-expired", "not-fast-forward", "not-in-main"))
         elif .last_result == "skipped" then (.reason | IN("on-battery", "lock-held",
          "rebuild-in-progress", "channel-behind", "dock-protect"))
         elif .last_result == "failed" then .reason != null
         else .reason == null end)
    and (has("dock_protect") == (.reason == "dock-protect"))
    and (if has("dock_protect") then (.dock_protect | (keys - ["error"]) == ["checked_at", "would_remove"]
          and (.checked_at | iso) and (.would_remove | type == "array" and length <= 30))
         else true end)
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
grep -q 'build --no-update-lock-file ' "$ROOT/stub.log" \
  && good "never re-resolves flake.lock" || bad "never re-resolves flake.lock" "$(cat "$ROOT/stub.log")"
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

# First run on a freshly enrolled host: no state, so the floor is the commit
# the running generation was built from (darwin-version.json).
installed() { # installed <configurationRevision>
  mkdir -p "$ROOT/store/installed"
  printf '{"configurationRevision": "%s"}\n' "$1" >"$ROOT/store/installed/darwin-version.json"
  ln -sfn "$ROOT/store/installed" "$ROOT/run/current-system"
}
fresh; refs "$C2" "$C1"; installed "$C2"
run_fu
expect "first run: hand-rebuilt from newer main, channel behind" 0 skipped channel-behind
check "first run behind: nothing built" "$(builds)" "0"
check "first run behind: target_commit is the tip" "$(field target_commit)" "$C1"
check "first run behind: applied_commit stays null" "$(field applied_commit)" "null"
check "first run behind: not counted as a failure" "$(field consecutive_failures)" "0"
fresh; refs "$C2" "$C2"; installed "$C1-dirty"
run_fu
expect "first run: channel ahead of a -dirty installed revision" 0 applied null
fresh; refs "$C3" "$C2"; installed "$C3-dirty"
run_fu
expect "first run: -dirty build ahead of the channel is not merged main" 3 refused not-fast-forward
fresh; refs "$C2" "$C1"; installed "$LOCAL"
run_fu
expect "first run: running an unmerged local build" 3 refused not-fast-forward
check "local build: nothing built" "$(builds)" "0"
fresh; refs "$DIV_MAIN" "$DIV_A"; installed "$DIV_B"
run_fu
expect "first run: channel tip diverged from the running revision" 3 refused not-fast-forward
fresh; refs "$C3" "$C1"
run_fu                     # fetches C3 into the daemon's checkout, applies C1
refs "$C2" "$C1"           # main force-rewound: C3 known locally, no longer in main
installed "$C3"
run_fu
expect "running revision known locally but no longer in main" 3 refused not-fast-forward

fresh; refs "$C2" "$C1"
run_fu
installed "$C2"   # a human rebuilt from newer main after the daemon applied C1
run_fu
expect "manual rebuild ahead of the channel waits for it" 0 skipped channel-behind
check "manual rebuild: only the daemon's own run built" "$(builds)" "1"
check "manual rebuild: applied_commit kept" "$(field applied_commit)" "$C1"
check "manual rebuild: generation kept" "$(field generation)" "1"
refs "$C3" "$C2"  # the channel catches up
run_fu
expect "channel caught up with the manual rebuild" 0 applied null
check "caught up: applied_commit is the tip" "$(field applied_commit)" "$C2"

fresh; refs "$C3" "$C2"
run_fu
refs "$C3" "$C1"; installed "$C3"
run_fu
expect "channel rewound below applied, even with a newer manual rebuild" 3 refused not-fast-forward

fresh; refs "$C2" "$C1"; installed "$C2"
run_fu --dry-run
check "dry-run, channel behind: exit 0" "$RC" "0"
grep -q 'dry-run result: skipped (channel-behind)' <<<"$OUT" && good "dry-run reports channel-behind" \
  || bad "dry-run reports channel-behind" "$OUT"

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
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"; echo "$$ $(date +%s)" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu
check "another run holds the lock: exit 0" "$RC" "0"
[[ ! -e "$STATE" ]] && good "lock-held: state left to the holder" || bad "lock-held: state left to the holder" "$(cat "$STATE")"
grep -q 'skipped (lock-held)' <<<"$OUT" && good "lock-held: logged" || bad "lock-held: logged" "$OUT"
check "lock-held: foreign lock left alone" "$(cut -d' ' -f1 "$ROOT/var/run/rh7-fleet-update.lock/pid")" "$$"

fresh; refs "$C2" "$C2"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"
echo "$$ $(( $(date +%s) - 7 * 3600 ))" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu
expect "live pid but lock older than any bounded run (pid reuse)" 0 applied null

bash -c 'exit 0' & dead_pid=$!; wait "$dead_pid"
fresh; refs "$C2" "$C2"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"; echo "$dead_pid" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu
expect "stale lock (dead pid) is taken over" 0 applied null
[[ ! -e "$ROOT/var/run/rh7-fleet-update.lock" && ! -e "$ROOT/var/run/rh7-fleet-update.lock.takeover" ]] \
  && good "stale lock: released afterwards" || bad "stale lock: released afterwards" "$(ls "$ROOT/var/run")"

fresh; refs "$C2" "$C2"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock" "$ROOT/var/run/rh7-fleet-update.lock.takeover"
echo "$dead_pid" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu
check "stale lock mid-takeover by another run: exit 0" "$RC" "0"
[[ ! -e "$STATE" ]] && good "mid-takeover: treated as held (no state, no build)" \
  || bad "mid-takeover: treated as held (no state, no build)" "$(cat "$STATE")"

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
STUB_NO_GUI=1 run_fu
expect "primary user logged out (agents installed, load at next login)" 0 applied null
grep -q 'note: tester had no GUI login session' <<<"$OUT" && good "logged out: success logged with a note" \
  || bad "logged out: success logged with a note" "$OUT"

fresh; refs "$C2" "$C2"
STUB_RACE=1 run_fu
expect "manual rebuild replaced the system mid-activation" 1 failed activation-failed
check "race: applied_commit not claimed" "$(field applied_commit)" "null"

echo ""
echo "fleet-update — Dock protection (never silently removes a Dock item)"
# tile <url|SPACER> — one persistent-apps entry; decl/dock wrap them as the
# evaluated declaration (nix-darwin's shape) and tester's current Dock plist.
TILES='def tile: if . == "SPACER" then {"tile-data": {}, "tile-type": "spacer-tile"}
  else {"tile-data": {"file-data": {"_CFURLString": ., "_CFURLStringType": 0}}, "tile-type": "file-tile"} end;'
decl() { jq -cn "$TILES"' $ARGS.positional | map(tile)' --args "$@"; }
DOCK_PLIST_REL="Users/tester/Library/Preferences/com.apple.dock.plist"
dock() {
  mkdir -p "$(dirname "$ROOT/$DOCK_PLIST_REL")"
  jq -n "$TILES"' {"persistent-apps": ($ARGS.positional | map(tile))}' --args "$@" >"$ROOT/$DOCK_PLIST_REL"
}
dockp() { jq -c --arg k "$1" '.dock_protect | getpath($k | split("."))' "$STATE" 2>/dev/null; }

fresh; refs "$C2" "$C2"; dock "file:///Applications/Canva.app/"
run_fu
expect "Dock unmanaged (persistent-apps unset): proceeds" 0 applied null
check "unmanaged: no dock_protect in the state" "$(field dock_protect)" "null"
fresh; refs "$C2" "$C2"   # no Dock plist at all
run_fu
expect "Dock unmanaged, plist unreadable: proceeds (nothing to protect)" 0 applied null

fresh; refs "$C2" "$C2"
dock "file:///Applications/Arc.app/" SPACER "file:///Applications/Google%20Chrome.app/" "/Applications/Ghostty.app"
STUB_DOCK_APPS=$(decl /Applications/Arc.app "/Applications/Google Chrome.app" SPACER \
  /Applications/Ghostty.app /Applications/Slack.app) run_fu
expect "additions only (Dock URLs %-decoded, trailing / dropped): proceeds" 0 applied null
check "additions only: built" "$(builds)" "1"
check "additions only: no dock_protect in the state" "$(field dock_protect)" "null"

fresh; refs "$C1" "$C1"; dock "file:///Applications/Arc.app/"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "Dock unchanged by the update: proceeds" 0 applied null
refs "$C2" "$C2"
STUB_BUILD_FAIL=1 STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "a failed run before the hold" 1 failed build-failed
dock "file:///Applications/Arc.app/" "file:///Applications/Canva.app/" SPACER \
  "file:///Applications/Google%20Chrome.app/" "file:///Applications/Canva.app/"
plist_before=$(cksum <"$ROOT/$DOCK_PLIST_REL")
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "update would remove Dock items" 0 skipped dock-protect
check "held: would_remove is exactly the removed apps, decoded, once each" \
  "$(dockp would_remove)" '["/Applications/Canva.app","/Applications/Google Chrome.app"]'
check "held: no error" "$(dockp error)" "null"
[[ "$(jq -r '.dock_protect.checked_at' "$STATE")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] \
  && good "held: checked_at is ISO-8601 UTC" || bad "held: checked_at is ISO-8601 UTC" "$(cat "$STATE")"
check "held: nothing built (only the earlier two runs)" "$(builds)" "2"
check "held: consecutive_failures not incremented" "$(field consecutive_failures)" "1"
check "held: applied_commit unchanged" "$(field applied_commit)" "$C1"
check "held: generation unchanged" "$(field generation)" "1"
check "held: target_commit is the tip" "$(field target_commit)" "$C2"
check "held: Dock plist untouched (read-only)" "$(cksum <"$ROOT/$DOCK_PLIST_REL")" "$plist_before"
grep -q "would remove from tester's Dock: /Applications/Canva.app, /Applications/Google Chrome.app" <<<"$OUT" \
  && good "held: the removals are logged" || bad "held: the removals are logged" "$OUT"
STUB_DOCK_APPS=$(decl /Applications/Arc.app /Applications/Canva.app "/Applications/Google Chrome.app") run_fu
expect "the apps are declared: the held update proceeds" 0 applied null
check "released: dock_protect cleared" "$(field dock_protect)" "null"
check "released: applied_commit is the tip" "$(field applied_commit)" "$C2"

fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"
STUB_DOCK_APPS='[]' run_fu
expect "managed Dock declared empty: every app would go" 0 skipped dock-protect
check "declared empty: lists them" "$(dockp would_remove)" '["/Applications/Arc.app"]'

fresh; refs "$C2" "$C2"
many=(); for i in $(seq 1 35); do many+=("$(printf 'file:///Applications/App%02d.app/' "$i")"); done
dock "${many[@]}"
STUB_DOCK_APPS='[]' run_fu
expect "35 removals" 0 skipped dock-protect
check "35 removals: reported list capped at 30" "$(jq '.dock_protect.would_remove | length' "$STATE")" "30"

fresh; refs "$C2" "$C2"   # managed Dock, but no plist to compare against
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "Dock plist missing: held (fail safe)" 0 skipped dock-protect
check "missing plist: error unreadable" "$(dockp error)" '"unreadable"'
check "missing plist: would_remove empty" "$(dockp would_remove)" '[]'
check "missing plist: nothing built" "$(builds)" "0"
check "missing plist: not a failure" "$(field consecutive_failures)" "0"
fresh; refs "$C2" "$C2"; mkdir -p "$(dirname "$ROOT/$DOCK_PLIST_REL")"; echo garbage >"$ROOT/$DOCK_PLIST_REL"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "Dock plist corrupt: held" 0 skipped dock-protect
check "corrupt plist: error unreadable" "$(dockp error)" '"unreadable"'
fresh; refs "$C2" "$C2"; mkdir -p "$(dirname "$ROOT/$DOCK_PLIST_REL")"
echo '{"persistent-apps": [{"tile-data": {}, "tile-type": "file-tile"}]}' >"$ROOT/$DOCK_PLIST_REL"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "Dock entry without a URL that is not a spacer: held" 0 skipped dock-protect
check "URL-less entry: error unreadable" "$(dockp error)" '"unreadable"'

fresh; refs "$C2" "$C2"; dock "file:///Applications/Canva.app/"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu --dry-run
check "dry-run, Dock removal: exit 0" "$RC" "0"
grep -q 'dry-run result: skipped (dock-protect)' <<<"$OUT" && good "dry-run reports dock-protect" \
  || bad "dry-run reports dock-protect" "$OUT"
[[ ! -e "$STATE" ]] && good "dry-run, Dock removal: no state written" || bad "dry-run, Dock removal: no state written" "$(cat "$STATE")"

fresh; refs "$C2" "$C2"
STUB_EVAL_FAIL=1 run_fu
expect "Dock declaration does not evaluate" 1 failed build-failed
check "eval fails: nothing built" "$(builds)" "0"

fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"
STUB_PIN_DURING_BUILD="file:///Applications/Canva.app/" STUB_DOCK_APPS=$(decl /Applications/Arc.app) run_fu
expect "app pinned during the build: re-checked before activation, held" 0 skipped dock-protect
check "pinned during build: lists it" "$(dockp would_remove)" '["/Applications/Canva.app"]'
check "pinned during build: built once" "$(builds)" "1"
check "pinned during build: declaration evaluated once" "$(grep -c ' eval ' "$ROOT/stub.log")" "1"
[[ ! -e "$ROOT/nix/var/nix/profiles/system" ]] && good "pinned during build: profile untouched" \
  || bad "pinned during build: profile untouched" "$(readlink "$ROOT/nix/var/nix/profiles/system")"

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
jq '.last_result = "skipped" | .reason = "channel-behind"' "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/behind.json"
check "skipped/channel-behind -> accepted and passed through" \
  "$(collect_fleet_update "$A/plist" "$A/behind.json" | jq -r '"\(.last_result)/\(.reason)"')" "skipped/channel-behind"
jq '.reason = "made-up"' "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/off.json"
check "reason outside the closed set -> state-unreadable" \
  "$(collect_fleet_update "$A/plist" "$A/off.json")" '{"enabled": true, "error": "state-unreadable"}'
jq '.last_result = "skipped" | .reason = "dock-protect"
    | .dock_protect = {"checked_at": "2026-11-11T03:30:00Z", "would_remove": ["/Applications/Canva.app",
        "/Users/kassie/Applications/CC.app", "/System/Applications/Messages.app",
        "/Users/kassie/Projects/Secret Thing.app", "/Applications/../Users/kassie/x.app", "relative.app"]}' \
  "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/dock.json"
got=$(collect_fleet_update "$A/plist" "$A/dock.json")
check "skipped/dock-protect -> accepted" "$(jq -r '"\(.last_result)/\(.reason)"' <<<"$got")" "skipped/dock-protect"
check "dock-protect: app paths relayed, ~/Applications de-personalised, others basename only" \
  "$(jq -c '.dock_protect.would_remove' <<<"$got")" \
  '["/Applications/Canva.app","~/Applications/CC.app","/System/Applications/Messages.app","Secret Thing.app","x.app","relative.app"]'
check "dock-protect: checked_at relayed" "$(jq -r '.dock_protect.checked_at' <<<"$got")" "2026-11-11T03:30:00Z"
jq '.last_result = "skipped" | .reason = "dock-protect"
    | .dock_protect = {"would_remove": [], "error": "unreadable", "checked_at": "2026-11-11T03:30:00Z"}' \
  "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/dock.json"
check "dock-protect, unreadable plist -> error relayed" \
  "$(collect_fleet_update "$A/plist" "$A/dock.json" | jq -c '.dock_protect | {error, would_remove}')" \
  '{"error":"unreadable","would_remove":[]}'
for bad_state in '.last_run_at = "garbage"' '.reason = "fetch-failed"' \
                 '.last_result = "refused" | .reason = "on-battery"' \
                 '.last_result = "refused" | .reason = "channel-behind"' 'del(.target_commit)' \
                 '.applied_commit = "abc"' '.consecutive_failures = -1' '.generation = -1' \
                 '.last_result = "refused" | .reason = "dock-protect" | .dock_protect = {"would_remove": [], "checked_at": "2026-11-11T03:30:00Z"}' \
                 '.last_result = "skipped" | .reason = "dock-protect"' \
                 '.dock_protect = {"would_remove": [], "checked_at": "2026-11-11T03:30:00Z"}' \
                 '.last_result = "skipped" | .reason = "dock-protect" | .dock_protect = {"would_remove": [1], "checked_at": "2026-11-11T03:30:00Z"}' \
                 '.last_result = "skipped" | .reason = "dock-protect" | .dock_protect = {"would_remove": [range(31) | "/Applications/A.app"], "checked_at": "2026-11-11T03:30:00Z"}' \
                 '.last_result = "skipped" | .reason = "dock-protect" | .dock_protect = {"would_remove": [], "error": "boom", "checked_at": "2026-11-11T03:30:00Z"}' \
                 '.last_result = "skipped" | .reason = "dock-protect" | .dock_protect = {"would_remove": [], "checked_at": "2026-11-11T03:30:00Z", "user": "kassie"}'; do
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
