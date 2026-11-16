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

# Fast-lane fixtures: commits that change files. FL_BASE (the channel) carries
# the host's own file configurations/macos/test-host.nix; each variant on top
# of it is one kind of main tip a requested run may or may not fast-lane.
HF_REL=configurations/macos/test-host.nix
HF="$W/work/$HF_REL"
# hf <casks> <packages> <program-arguments> — the host file's three lists.
hf() {
  mkdir -p "$(dirname "$HF")"
  { echo '{ pkgs, ... }:'; echo '{'
    echo '  homebrew.casks = ['; printf '%s\n' "$1"; echo '  ];'
    echo '  environment.systemPackages = ['; printf '%s\n' "$2"; echo '  ];'
    echo '  launchd.daemons.demo.serviceConfig.ProgramArguments = ['; printf '%s\n' "$3"; echo '  ];'
    echo '}'; } >"$HF"
}
CASKS0='    "firefox"          # browser
                       # (a continued comment)
    "zen"'
PKGS0='    pkgs.git'
PROG0='    "/bin/echo"'
# commit_files <key|none> <msg> — commit the work tree as it is, prints its sha.
commit_files() {
  gw add -A
  if [[ "$1" == none ]]; then
    gw -c commit.gpgsign=false commit -q -m "$2"
  else
    gw -c gpg.program="$W/sign-$1" commit -q -m "$2" -S"$(cat "$W/$1.fpr")"
  fi
  gw rev-parse HEAD
}
gw checkout -q --detach "$C2"
echo "other" >"$W/work/other.txt"
hf "$CASKS0" "$PKGS0" "$PROG0"
FL_BASE=$(commit_files pinned "fl: base with the host file")
hf "$CASKS0
    \"newapp\"           # NEW — Kassie asked for it" "$PKGS0" "$PROG0"
FL_CASK=$(commit_files pinned "fl: one cask added")
hf "$CASKS0
    \"newapp\"           # NEW — Kassie asked for it
    \"acme/tap/another\"" "$PKGS0" "$PROG0"
FL_CASK2=$(commit_files pinned "fl: a second (tap-qualified) cask")
echo "changed elsewhere" >"$W/work/other.txt"
FL_NEXT=$(commit_files pinned "fl: an unrelated change after both")
gw checkout -q --detach "$FL_BASE"
hf "$CASKS0" "$PKGS0
    pkgs.jq" "$PROG0"
FL_PKGS=$(commit_files pinned "fl: one package added")
gw checkout -q --detach "$FL_BASE"
hf "$CASKS0
    \"newapp\"" "$PKGS0" "$PROG0"
echo "also touched" >"$W/work/other.txt"
FL_OTHER=$(commit_files pinned "fl: a cask plus another file")
gw checkout -q --detach "$FL_BASE"
hf '    "firefox"          # browser
                       # (a continued comment)' "$PKGS0" "$PROG0"
FL_REMOVE=$(commit_files pinned "fl: a cask removed")
gw checkout -q --detach "$FL_BASE"
hf '    "firefox"          # browser
    "zen"
    "newapp"' "$PKGS0" "$PROG0"
FL_COMMENT=$(commit_files pinned "fl: a comment line dropped, a cask added")
gw checkout -q --detach "$FL_BASE"
hf "$CASKS0" "$PKGS0" '    "reboot"
    "/bin/echo"'
FL_PROG=$(commit_files pinned "fl: a token added to ProgramArguments")
gw checkout -q --detach "$FL_BASE"
hf "$CASKS0" "$PKGS0" "$PROG0"
printf '  system.activationScripts.postActivation.text = %s\n' "''" >>"$HF"
FL_CODE=$(commit_files pinned "fl: code added to the host file")
gw checkout -q --detach "$FL_BASE"
chmod +x "$HF"
FL_MODE=$(commit_files pinned "fl: host file mode changed")
gw checkout -q --detach "$FL_BASE"
hf "$CASKS0
    \"newapp\"" "$PKGS0" "$PROG0"
FL_UNSIGNED=$(commit_files none "fl: one cask added, unsigned")

# ── Stubs ────────────────────────────────────────────────────────────────────
STUBS="$W/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/pmset" <<'EOF'
#!/usr/bin/env bash
echo "Now drawing from '${STUB_POWER:-AC Power}'"
echo " -InternalBattery-0 (id=4653155)	${STUB_BATTERY-80}%; discharging; 4:12 remaining present: true"
EOF
cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
# The public GitHub API (fleet-update's fast-lane CI check) and the config
# service (the deploy-request poller, end to end). STUB_CI: green (default) |
# red | pending | error | truncated. Config service: GET -> $STUB_DR_GET,
# POST -> body appended to $STUB_DR_ACKS, answered $STUB_ACK_CODE (200).
url="" out="" fmt="" method=GET data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time|--proto) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "curl $method $url" >>"$STUB_LOG"
code=200
case "$url" in
  https://api.github.com/repos/rh7/dotfiles/commits/*/check-runs\?per_page=100)
    ok='{"status":"completed","conclusion":"success"}'
    case "${STUB_CI:-green}" in
      error) exit 22 ;;
      red) body="{\"total_count\":2,\"check_runs\":[$ok,{\"status\":\"completed\",\"conclusion\":\"failure\"}]}" ;;
      pending) body="{\"total_count\":2,\"check_runs\":[$ok,{\"status\":\"in_progress\",\"conclusion\":null}]}" ;;
      truncated) body="{\"total_count\":120,\"check_runs\":[$ok]}" ;;
      *) body="{\"total_count\":2,\"check_runs\":[$ok,$ok]}" ;;
    esac ;;
  https://api.github.com/repos/rh7/dotfiles/commits/*/status)
    body='{"total_count":0,"state":"pending","statuses":[]}' ;;
  */api/fleet/deploy-request/*/ack)
    echo "$data" >>"$STUB_DR_ACKS"; code=${STUB_ACK_CODE:-200}; body='{}' ;;
  */api/fleet/deploy-request/*)
    body=$(cat "$STUB_DR_GET") ;;
  *) exit 6 ;;
esac
if [[ -n "$out" ]]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
[[ -z "$fmt" ]] || printf '%s' "$code"
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
# STUB_APPS_RO=1: the brew user cannot write /Applications (a standard account).
case " $* " in *" test -w "*) [[ -z "${STUB_APPS_RO:-}" ]] || exit 1 ;; esac
exit 0
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
  # The checked-out commit's declaration: STUB_DOCK_APPS / _OTHERS are the
  # evaluated persistent-apps / -others (unset = null = unmanaged),
  # STUB_BREW_DECL its Homebrew part (default: tester, no casks).
  [[ -z "${STUB_EVAL_FAIL:-}" ]] || { echo "error: evaluation aborted" >&2; exit 1; }
  brew=${STUB_BREW_DECL:-'{"enable":true,"user":"tester","prefix":"/opt/homebrew","casks":[]}'}
  echo "{\"user\":\"tester\",\"apps\":${STUB_DOCK_APPS:-null},\"others\":${STUB_DOCK_OTHERS:-null},\"brew\":$brew}"
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
if [[ -n "${STUB_PIN_OTHERS_DURING_BUILD:-}" ]]; then
  dp="$FLEET_UPDATE_ROOT/Users/tester/Library/Preferences/com.apple.dock.plist"
  jq --arg u "$STUB_PIN_OTHERS_DURING_BUILD" '.["persistent-others"] += [{"tile-data": {"file-data": {"_CFURLString": $u}}, "tile-type": "directory-tile"}]' \
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
run_fu() { # run_fu [args...] -> OUT, RC   (CHANNEL / PINNED overridable; NO_FLF=1: no host file)
  local flf=(--fast-lane-file "$HF_REL")
  [[ -z "${NO_FLF:-}" ]] || flf=()
  OUT=$(env FLEET_UPDATE_ROOT="$ROOT" FLEET_UPDATE_REPO_URL="file://$W/origin.git" \
        PATH="$STUBS:$PATH" STUB_LOG="$ROOT/stub.log" STUB_STORE="$ROOT/store" \
        bash "$SCRIPT" --channel "${CHANNEL:-fleet/stable}" --flake-attr test-host \
        --signer-key "${PINNED:-$W/pinned.asc}" --primary-user tester "${flf[@]}" "$@" 2>&1)
  RC=$?
}
field() { jq -r --arg k "$1" '.[$k] | if . == null then "null" else tostring end' "$STATE" 2>/dev/null; }
builds() { grep -c ' build ' "$ROOT/stub.log" || true; }

# The rh-device-management `fleet_update` contract, enforced on every state file.
validate_state() {
  jq -e '
    def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def sha: type == "string" and test("^[0-9a-f]{40}$");
    ((keys - ["dock_protect", "request_id", "lane", "fast_lane_reason", "applied_lane"])
      == ["applied_commit","channel","consecutive_failures","enabled","generation",
              "last_result","last_run_at","last_success_at","reason","schema","target_commit"])
    and (has("request_id") == has("lane") and has("lane") == has("fast_lane_reason"))
    and (if has("request_id") then (.request_id | type == "string")
          and (.lane == null or (.lane | IN("fast", "channel")))
          and (.fast_lane_reason == null or (.fast_lane_reason | IN("not-requested", "channel-is-main",
               "no-host-file", "same-as-channel", "signature-invalid", "not-descendant", "other-files",
               "not-list-addition", "ci-not-green", "ci-unknown")))
         else true end)
    and (if has("applied_lane") then .applied_lane == "fast" else true end)
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
STUB_RACE=1 run_fu
expect "manual rebuild replaced the system mid-activation" 1 failed activation-failed
check "race: applied_commit not claimed" "$(field applied_commit)" "null"

echo ""
echo "fleet-update — new casks need a homebrew.user that can write /Applications"
# kassie-mbp-m1 before homebrew.user = rouven: a standard brew user makes
# Homebrew fall back to its own `sudo cp` for every new cask — unattended
# that can only fail, after the profile switched. Refused before building.
brew_decl() { # brew_decl <user> <cask>... — the commit's Homebrew declaration
  local u="$1"; shift
  jq -cn --arg u "$u" '{enable: true, user: $u, prefix: "/opt/homebrew", casks: $ARGS.positional}' --args "$@"
}
caskroom() { mkdir -p "$ROOT/opt/homebrew/Caskroom/$1"; }

fresh; refs "$C2" "$C2"; caskroom firefox
STUB_APPS_RO=1 STUB_BREW_DECL=$(brew_decl kassie firefox zen) run_fu
expect "new cask, brew user cannot write /Applications" 1 failed brew-failed
check "non-admin brew user: nothing built" "$(builds)" "0"
[[ ! -e "$ROOT/nix/var/nix/profiles/system" ]] && good "non-admin brew user: profile untouched" \
  || bad "non-admin brew user: profile untouched" "$(readlink "$ROOT/nix/var/nix/profiles/system")"
grep -q "brew-user: .* would install zen as homebrew.user 'kassie', who cannot write /Applications" <<<"$OUT" \
  && good "non-admin brew user: the log names the cask and the user (installed firefox not counted)" \
  || bad "non-admin brew user: log names cask and user" "$OUT"
grep -q "Fix: set homebrew.user to an admin account" <<<"$OUT" \
  && good "non-admin brew user: the log names the fix" || bad "non-admin brew user: the log names the fix" "$OUT"
grep -q 'sudo -n -u kassie test -w ' "$ROOT/stub.log" \
  && good "asked as the brew user (sudo -n -u kassie test -w)" || bad "asked as the brew user" "$(cat "$ROOT/stub.log")"

STUB_APPS_RO=1 STUB_BREW_DECL=$(brew_decl kassie firefox zen) run_fu --dry-run
check "dry-run: reports the same refusal (exit 1)" "$RC" "1"
grep -q 'dry-run result: failed (brew-failed)' <<<"$OUT" && good "dry-run: failed (brew-failed), state not written" \
  || bad "dry-run: failed (brew-failed)" "$OUT"

# The sandbox prefix belongs to whoever runs this suite: use that account as
# the brew user wherever a prefix exists and must count as migrated.
ME=$(id -un)
fresh; refs "$C2" "$C2"; caskroom firefox; caskroom zen
STUB_APPS_RO=1 STUB_BREW_DECL=$(brew_decl "$ME" firefox acme/tap/zen) run_fu
expect "no new cask (tap-qualified name resolved to its token): a non-admin brew user is fine" 0 applied null

# homebrew.user changed (kassie → rouven) but nobody migrated the prefix yet:
# brew as the new user would fail on it mid-activation. Refused before building.
fresh; refs "$C2" "$C2"; caskroom firefox
STUB_BREW_DECL=$(brew_decl nobody firefox) run_fu
expect "prefix not the brew user's" 1 failed brew-failed
check "prefix not the brew user's: nothing built" "$(builds)" "0"
grep -q "brew-user: .* runs Homebrew as homebrew.user 'nobody', but $ROOT/opt/homebrew is not nobody's" <<<"$OUT" \
  && good "prefix not the brew user's: the log names user and prefix" || bad "prefix log" "$OUT"
grep -q "Fix: run rebuild.sh from an admin account; it offers the chown to nobody" <<<"$OUT" \
  && good "prefix not the brew user's: the log names the fix" || bad "prefix fix logged" "$OUT"
fresh; refs "$C2" "$C2"; caskroom firefox
STUB_BREW_DECL=$(brew_decl no-such-user-x firefox) run_fu
expect "brew user that does not exist on this Mac" 1 failed brew-failed
grep -q '(no such user: no-such-user-x)' <<<"$OUT" && good "missing brew user: says so" || bad "missing brew user: says so" "$OUT"

fresh; refs "$C2" "$C2"
STUB_BREW_DECL=$(brew_decl maint zen ghostty) run_fu
expect "new casks, brew user can write /Applications" 0 applied null
grep -q 'brew: .* installs zen ghostty as homebrew.user maint' <<<"$OUT" \
  && good "admin brew user: logged" || bad "admin brew user: logged" "$OUT"
grep -q 'sudo -n -u maint -- sudo -K' "$ROOT/stub.log" && grep -q 'sudo -n -u tester -- sudo -K' "$ROOT/stub.log" \
  && good "closes the brew user's AND the primary user's sudo window" \
  || bad "closes both sudo windows" "$(cat "$ROOT/stub.log")"

fresh; refs "$C2" "$C2"
STUB_APPS_RO=1 STUB_BREW_DECL='{"enable":false,"user":"kassie","prefix":"/opt/homebrew","casks":["zen"]}' run_fu
expect "homebrew.enable = false: no cask is installed, nothing to check" 0 applied null

fresh; refs "$C2" "$C2"
STUB_BREW_DECL='{"enable":true,"user":"kassie"}' run_fu
expect "malformed Homebrew declaration" 1 failed build-failed
check "malformed Homebrew declaration: nothing built" "$(builds)" "0"

echo ""
echo "fleet-update — Dock protection (never silently removes a Dock item)"
# tile <url|SPACER> — one Dock entry; decl/dock wrap them as the evaluated
# declaration (nix-darwin's shape) and tester's current Dock plist (apps
# side); others <url>... sets its right-hand side (directory tiles; a
# "WEB:<url>" argument is a web-link tile).
TILES='def tile: if . == "SPACER" then {"tile-data": {}, "tile-type": "spacer-tile"}
  elif startswith("WEB:") then {"tile-data": {"url": {"_CFURLString": .[4:], "_CFURLStringType": 15}}, "tile-type": "url-tile"}
  else {"tile-data": {"file-data": {"_CFURLString": ., "_CFURLStringType": 0}}, "tile-type": "file-tile"} end;'
decl() { jq -cn "$TILES"' $ARGS.positional | map(tile)' --args "$@"; }
DOCK_PLIST_REL="Users/tester/Library/Preferences/com.apple.dock.plist"
dock() {
  mkdir -p "$(dirname "$ROOT/$DOCK_PLIST_REL")"
  jq -n "$TILES"' {"persistent-apps": ($ARGS.positional | map(tile))}' --args "$@" >"$ROOT/$DOCK_PLIST_REL"
}
others() {
  jq "$TILES"' .["persistent-others"] = ($ARGS.positional | map(tile | .["tile-type"] |= (if . == "file-tile" then "directory-tile" else . end)))' \
    --args "$@" <"$ROOT/$DOCK_PLIST_REL" >"$ROOT/$DOCK_PLIST_REL.tmp" && mv "$ROOT/$DOCK_PLIST_REL.tmp" "$ROOT/$DOCK_PLIST_REL"
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

fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"; others "file:///Users/tester/Downloads/"
run_fu
expect "right side unmanaged (persistent-others unset): proceeds" 0 applied null
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"; others "file:///Users/tester/Downloads/"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) STUB_DOCK_OTHERS='[]' run_fu
expect "Downloads stack added by the user, persistent-others declared []" 0 skipped dock-protect
check "Downloads stack: listed" "$(dockp would_remove)" '["/Users/tester/Downloads"]'
check "Downloads stack: nothing built" "$(builds)" "0"
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"; others "file:///Users/tester/Downloads/"
STUB_DOCK_OTHERS='[]' run_fu
expect "only the right side managed: still protected" 0 skipped dock-protect
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/" "file:///Applications/Canva.app/"
others "file:///Users/tester/Documents%20Old/" "WEB:https://user@news.example.com/a?b"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) STUB_DOCK_OTHERS=$(decl "file:///Users/tester/Downloads") run_fu
expect "both sides would lose items" 0 skipped dock-protect
check "both sides: apps first, then folders and web links (host only)" "$(dockp would_remove)" \
  '["/Applications/Canva.app","/Users/tester/Documents Old","web link: news.example.com"]'
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"; others "file:///Users/tester/Downloads/"
STUB_DOCK_APPS=$(decl /Applications/Arc.app) STUB_DOCK_OTHERS=$(decl "file:///Users/tester/Downloads" "file:///Users/tester/Projects") run_fu
expect "right side: additions only (declared file:// URLs normalised)" 0 applied null
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"   # no persistent-others key at all
STUB_DOCK_APPS=$(decl /Applications/Arc.app) STUB_DOCK_OTHERS='[]' run_fu
expect "no persistent-others key = empty right side: proceeds" 0 applied null
fresh; refs "$C2" "$C2"; dock "file:///Applications/Arc.app/"; others "file:///Users/tester/Downloads/"
STUB_PIN_OTHERS_DURING_BUILD="file:///Users/tester/Desktop/" STUB_DOCK_OTHERS=$(decl "file:///Users/tester/Downloads") run_fu
expect "folder added during the build: held before activation" 0 skipped dock-protect
check "folder during build: listed" "$(dockp would_remove)" '["/Users/tester/Desktop"]'

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
run_fu --fast-lane
check "--fast-lane without --requested rejected" "$RC" "64"
run_fu --requested 'r1;reboot'
check "request id outside [A-Za-z0-9-] rejected" "$RC" "64"
run_fu --requested r1 --scheduled
check "--requested with --scheduled rejected" "$RC" "64"
NO_FLF=1 run_fu --fast-lane-file ../../etc/x.nix
check "--fast-lane-file outside configurations/macos rejected" "$RC" "64"

echo ""
echo "fleet-update — requested runs: the fast lane (eligible)"
ciq() { grep -c 'api.github.com' "$ROOT/stub.log" || true; }
# lane <label> <lane|null> <fast_lane_reason|null> <request id>
lane() {
  check "$1: lane=$2" "$(field lane)" "$2"
  check "$1: fast_lane_reason=$3" "$(field fast_lane_reason)" "$3"
  check "$1: request_id recorded" "$(field request_id)" "$4"
}
fresh; refs "$FL_CASK" "$FL_BASE"
run_fu --requested req-1 --fast-lane
expect "cask added to the host's own file" 0 applied null
lane "cask added" fast null req-1
check "cask added: the main tip is applied" "$(field applied_commit)" "$FL_CASK"
check "cask added: applied_lane fast" "$(field applied_lane)" "fast"
check "cask added: CI asked (check runs + status)" "$(ciq)" "2"
check "cask added: checkout is the main tip" "$(git -C "$ROOT/var/lib/rh7-fleet-update/dotfiles" rev-parse HEAD)" "$FL_CASK"
check "cask added: the channel is not moved" "$(git -C "$W/origin.git" rev-parse refs/heads/fleet/stable)" "$FL_BASE"
cp "$STATE" "$W/fast-state.json"
run_fu
expect "nightly run after a fast-lane apply: channel behind it" 0 skipped channel-behind
check "behind fast lane: not counted as a failure" "$(field consecutive_failures)" "0"
check "behind fast lane: no request keys on a nightly state" "$(field request_id)" "null"
check "behind fast lane: applied_lane carried" "$(field applied_lane)" "fast"
check "behind fast lane: nothing built" "$(builds)" "1"
run_fu --requested req-2 --fast-lane
expect "requested again, main unchanged (main tip == applied)" 0 no-op null
lane "requested again" fast null req-2
check "requested again: still ahead of the channel, applied_lane kept" "$(field applied_lane)" "fast"
refs "$FL_NEXT" "$FL_CASK2"
run_fu
expect "the channel catches up past the fast-laned commit" 0 applied null
check "caught up: applied_commit is the channel tip" "$(field applied_commit)" "$FL_CASK2"
check "caught up: applied_lane cleared" "$(field applied_lane)" "null"

fresh; refs "$FL_CASK" "$FL_BASE"
run_fu --requested req-x --fast-lane
refs "$FL_CASK" "$FL_CASK"      # the channel reaches exactly the fast-laned commit
run_fu
expect "channel caught up exactly with the fast-laned commit" 0 no-op null
check "caught up exactly: applied_lane cleared" "$(field applied_lane)" "null"
refs "$FL_CASK" "$FL_BASE"      # then the channel is rewound
run_fu
expect "channel rewound after catching up: refused again" 3 refused not-fast-forward

fresh; refs "$FL_CASK2" "$FL_BASE"
run_fu --requested req-3 --fast-lane
expect "two casks (one tap-qualified) in one go" 0 applied null
lane "two casks" fast null req-3
fresh; refs "$FL_PKGS" "$FL_BASE"
run_fu --requested req-4 --fast-lane
lane "pkgs.<name> added to environment.systemPackages" fast null req-4
fresh; refs "$FL_COMMENT" "$FL_BASE"
run_fu --requested req-5 --fast-lane
lane "a comment line removed, a cask added" fast null req-5

fresh; refs "$FL_CASK" "$FL_BASE"
run_fu --requested req-6 --fast-lane --dry-run
check "dry-run, fast lane: exit 0" "$RC" "0"
grep -q "dry-run result: would-apply target=$FL_CASK lane=fast" <<<"$OUT" \
  && good "dry-run reports the fast-lane target" || bad "dry-run fast lane" "$OUT"
[[ ! -e "$STATE" ]] && good "dry-run, fast lane: no state written" || bad "dry-run fast lane: no state" "$(cat "$STATE")"

echo ""
echo "fleet-update — requested runs: the channel lane (fast lane not eligible)"
# channel_lane <label> <main tip> <fast_lane_reason> [run_fu args...]
channel_lane() {
  local label="$1" tip="$2" why="$3"; shift 3
  fresh; refs "$tip" "$FL_BASE"
  run_fu --requested req-c "$@"
  expect "$label" 0 applied null
  lane "$label" channel "$why" req-c
  check "$label: the channel tip is applied" "$(field applied_commit)" "$FL_BASE"
  check "$label: no applied_lane" "$(field applied_lane)" "null"
}
channel_lane "diff touches another file" "$FL_OTHER" other-files --fast-lane
check "another file: CI not even asked" "$(ciq)" "0"
channel_lane "host file mode changed" "$FL_MODE" other-files --fast-lane
channel_lane "a cask line removed" "$FL_REMOVE" not-list-addition --fast-lane
check "removal: CI not even asked" "$(ciq)" "0"
channel_lane "a token added to a non-package list (ProgramArguments)" "$FL_PROG" not-list-addition --fast-lane
channel_lane "code added to the host file" "$FL_CODE" not-list-addition --fast-lane
channel_lane "main tip not signed" "$FL_UNSIGNED" signature-invalid --fast-lane
STUB_CI=red channel_lane "CI red" "$FL_CASK" ci-not-green --fast-lane
STUB_CI=pending channel_lane "CI still running" "$FL_CASK" ci-not-green --fast-lane
STUB_CI=error channel_lane "GitHub API unreachable" "$FL_CASK" ci-unknown --fast-lane
STUB_CI=truncated channel_lane "more check runs than one page" "$FL_CASK" ci-unknown --fast-lane
channel_lane "owner did not allow the fast lane" "$FL_CASK" not-requested
check "not allowed: CI not asked" "$(ciq)" "0"
NO_FLF=1 channel_lane "host without a host file of its own" "$FL_CASK" no-host-file --fast-lane
channel_lane "main is the channel tip" "$FL_BASE" same-as-channel --fast-lane
fresh; refs "$FL_CASK"
CHANNEL=main run_fu --requested req-m --fast-lane
expect "canary (follows main): requested" 0 applied null
lane "canary" channel channel-is-main req-m

fresh; refs "$FL_CASK" "$FL_CASK"; installed "$FL_CASK"
run_fu
refs "$FL_OTHER" "$FL_BASE"     # never: fleet/stable rewound below what was applied
run_fu --requested req-r --fast-lane
expect "channel rewound below a CHANNEL apply, fast lane not eligible" 3 refused not-fast-forward

echo ""
echo "fleet-update — requested runs: trust, power, lock"
fresh; refs "$FL_CASK" "$UNSIGNED"
run_fu --requested req-s --fast-lane
expect "unsigned channel tip, eligible main: still refused" 3 refused signature-invalid
check "unsigned channel: lane never chosen" "$(field lane)" "null"
check "unsigned channel: request_id recorded" "$(field request_id)" "req-s"
check "unsigned channel: nothing built" "$(builds)" "0"

fresh; refs "$FL_CASK" "$FL_BASE"
STUB_POWER='Battery Power' STUB_BATTERY=62 run_fu --requested req-b --fast-lane
expect "requested on battery at 62%" 0 applied null
fresh; refs "$FL_CASK" "$FL_BASE"
STUB_POWER='Battery Power' STUB_BATTERY=50 run_fu --requested req-b --fast-lane
expect "requested on battery at exactly 50%" 0 applied null
fresh; refs "$FL_CASK" "$FL_BASE"
STUB_POWER='Battery Power' STUB_BATTERY=49 run_fu --requested req-b --fast-lane
expect "requested on battery at 49%" 0 skipped on-battery
check "49%: request recorded, lane not chosen" "$(field request_id)/$(field lane)" "req-b/null"
fresh; refs "$FL_CASK" "$FL_BASE"
STUB_POWER='Battery Power' STUB_BATTERY='' run_fu --requested req-b --fast-lane
expect "requested on battery, charge unknown" 0 skipped on-battery
fresh; refs "$FL_CASK" "$FL_BASE"
STUB_POWER='Battery Power' STUB_BATTERY=95 run_fu
expect "nightly run on battery at 95%: still never" 0 skipped on-battery

fresh; refs "$FL_CASK" "$FL_BASE"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"; echo "$$ $(date +%s)" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_fu --requested req-l --fast-lane
check "requested while the nightly run holds the lock: exit 0" "$RC" "0"
[[ ! -e "$STATE" ]] && good "requested, lock held: state left to the holder" || bad "requested lock-held: state" "$(cat "$STATE")"
check "requested, lock held: nothing built" "$(builds)" "0"

echo ""
echo "deploy-request poller -> fleet-update, end to end"
POLLER="$HERE/../deploy-request.sh"
cat >"$W/fu-wrapper" <<EOF
#!/usr/bin/env bash
exec bash '$SCRIPT' --channel fleet/stable --flake-attr test-host --signer-key '$W/pinned.asc' \\
  --primary-user tester --fast-lane-file '$HF_REL' "\$@"
EOF
chmod +x "$W/fu-wrapper"
run_dr() { # run_dr <GET body>
  printf '%s' "$1" >"$ROOT/dr-get"
  env DEPLOY_REQUEST_ROOT="$ROOT" FLEET_UPDATE_ROOT="$ROOT" FLEET_UPDATE_REPO_URL="file://$W/origin.git" \
      PATH="$STUBS:$PATH" STUB_LOG="$ROOT/stub.log" STUB_STORE="$ROOT/store" \
      STUB_DR_GET="$ROOT/dr-get" STUB_DR_ACKS="$ROOT/acks" \
      bash "$POLLER" --hostname test-host --fleet-update "$W/fu-wrapper" >/dev/null 2>&1
  RC=$?
}
dr_fresh() { fresh; mkdir -p "$ROOT/etc/rh7"; echo "http://127.0.0.1:3456" >"$ROOT/etc/rh7/config-service"; : >"$ROOT/acks"; }
REQ='{"hostname":"test-host","requested":true,"request_id":"7c1e0a52-e2e","requested_at":"2026-11-16T09:58:00Z","fast_lane":true,"last_result":null}'
dr_fresh; refs "$FL_CASK" "$FL_BASE"
run_dr '{"hostname":"test-host","requested":false,"request_id":null,"requested_at":null,"fast_lane":false,"last_result":null}'
check "no request: nothing run, nothing acked" "$(builds)/$(wc -l <"$ROOT/acks" | tr -d ' ')" "0/0"
[[ ! -e "$STATE" ]] && good "no request: no state" || bad "no request: no state" "$(cat "$STATE")"

dr_fresh; refs "$FL_CASK" "$FL_BASE"
mkdir -p "$ROOT/var/run/rh7-fleet-update.lock"; echo "$$ $(date +%s)" >"$ROOT/var/run/rh7-fleet-update.lock/pid"
run_dr "$REQ"
check "nightly run holds the lock: only started acked" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started"
check "lock held: nothing built" "$(builds)" "0"
rm -rf "$ROOT/var/run/rh7-fleet-update.lock"
run_dr "$REQ"
check "lock released, next poll: started once, then applied" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started applied"
check "final ack: same request_id, fast lane, the main tip" "$(tail -n 1 "$ROOT/acks" | jq -c '{request_id, lane, commit}')" \
  "{\"request_id\":\"7c1e0a52-e2e\",\"lane\":\"fast\",\"commit\":\"$FL_CASK\"}"
check "state.json carries the request id" "$(field request_id)" "7c1e0a52-e2e"
expect "end to end" 0 applied null

dr_fresh; refs "$FL_OTHER" "$FL_BASE"
STUB_ACK_CODE=503 run_dr "$REQ"
check "final ack refused by a 503: built once" "$(builds)" "1"
run_dr "$REQ"
check "next poll: result re-sent from state.json, not rebuilt" "$(builds)" "1"
check "re-sent ack: channel lane, the reason, the channel tip" "$(tail -n 1 "$ROOT/acks" | jq -c '{status, lane, reason, commit}')" \
  "{\"status\":\"applied\",\"lane\":\"channel\",\"reason\":\"fast-lane:other-files\",\"commit\":\"$FL_BASE\"}"

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
        "/Users/kassie/Projects/Secret Thing.app", "/Applications/../Users/kassie/x.app", "relative.app",
        "/Users/kassie/Downloads", "/Volumes/Backup/Stuff", "web link: news.example.com"]}' \
  "$W/case1/var/lib/rh7-fleet-update/state.json" >"$A/dock.json"
got=$(collect_fleet_update "$A/plist" "$A/dock.json")
check "skipped/dock-protect -> accepted" "$(jq -r '"\(.last_result)/\(.reason)"' <<<"$got")" "skipped/dock-protect"
check "dock-protect: app paths relayed, home paths as ~/..., others basename only" \
  "$(jq -c '.dock_protect.would_remove' <<<"$got")" \
  '["/Applications/Canva.app","~/Applications/CC.app","/System/Applications/Messages.app","~/Projects/Secret Thing.app","x.app","relative.app","~/Downloads","Stuff","web link: news.example.com"]'
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
got=$(collect_fleet_update "$A/plist" "$W/fast-state.json")
check "requested fast-lane state -> request keys and applied_lane relayed" \
  "$(jq -c '{request_id, lane, fast_lane_reason, applied_lane}' <<<"$got")" \
  '{"request_id":"req-1","lane":"fast","fast_lane_reason":null,"applied_lane":"fast"}'
check "plain nightly state -> no request keys" "$(collect_fleet_update "$A/plist" "$A/state.json" | jq -c 'has("request_id") or has("lane")')" "false"
for bad_state in 'del(.lane)' '.lane = "slow"' '.fast_lane_reason = "because"' '.request_id = "a b"' \
                 '.applied_lane = "channel"' '.applied_commit = null'; do
  jq "$bad_state" "$W/fast-state.json" >"$A/off.json"
  check "requested-state violation ($bad_state) -> state-unreadable" \
    "$(collect_fleet_update "$A/plist" "$A/off.json")" '{"enabled": true, "error": "state-unreadable"}'
done
# shellcheck disable=SC2034
OS=Linux
check "Linux -> disabled" "$(collect_fleet_update "$A/plist" "$A/state.json")" '{"enabled": false}'

echo ""
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
