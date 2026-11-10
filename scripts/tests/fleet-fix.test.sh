#!/usr/bin/env bash
# Coverage for scripts/fleet-fix.sh — the on-device fixer for fleet action items.
#
# Every external command the script could mutate the machine with (sudo,
# socketfilterfw, fdesetup, nix-collect-garbage, brew, launchctl, open, …) is a
# stub that LOGS its argv, so the properties that matter are asserted on what was
# actually invoked: a dry-run never calls a mutating command; --apply on the
# firewall calls exactly the right one and re-verifies; the Studio exemption (#93)
# holds; usage errors exit 64; an unreachable config service is exit 2, loud.
#
# Runs on Linux CI and macOS alike (uname/hostname are stubbed).
# Run: bash scripts/tests/fleet-fix.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FF="$REPO_ROOT/scripts/fleet-fix.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"; FIX_DIR="$TEST_ROOT/fixtures"; CALLS="$TEST_ROOT/calls.log"
mkdir -p "$FAKE_BIN" "$FIX_DIR"
REAL_CURL="$(command -v curl)"
REAL_PY="$(command -v python3)"
[ -n "$REAL_PY" ] || { echo "python3 required"; exit 1; }

stub() { # stub NAME BODY — BODY runs after the argv is logged
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$FAKE_BIN/$1"
  chmod +x "$FAKE_BIN/$1"
}
stub uname          'echo "${FAKE_OS:-Darwin}"'
stub hostname       'echo "${FAKE_HOST:-Test-Mac.local}"'
stub xcode-select   'exit 0'
stub sudo           '[ "$1" = "-n" ] && { shift; [ "$1" = true ] && exit "${SUDO_N_EXIT:-1}"; }; "$@"'
stub socketfilterfw 'case "$1" in
  --getglobalstate) if [ "$(cat "$TEST_ROOT/fw" 2>/dev/null)" = 1 ]; then echo "Firewall is enabled. (State = 1)"; else echo "Firewall is disabled. (State = 0)"; fi ;;
  --setglobalstate) [ "${FW_CLI_WORKS:-1}" = 1 ] && echo 1 >"$TEST_ROOT/fw"; echo "Firewall is enabled. (State = 1)" ;;
esac'
stub fdesetup       'case "$1" in status) echo "FileVault is Off." ;; esac'
stub nix-collect-garbage 'case "$*" in
  *--dry-run*) echo "/nix/store/aaa-dead"; echo "/nix/store/bbb-dead" ;;
  *--delete-older-than*) echo 50 >"$TEST_ROOT/disk" ;;
esac'
stub brew           'case "$1" in --cache) echo "$TEST_ROOT/brewcache" ;; esac'
stub df             'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/disk1 100 90 10 $(cat "$TEST_ROOT/disk")% /"'
stub sysctl         'echo "total = 2048.00M  used = ${FAKE_SWAP_MB:-100}.00M  free = 0M"'
stub free           'echo "Swap: 2048 100 1948"'
stub launchctl      '[ "$1" = print ] && exit "${LAUNCHCTL_LOADED:-1}"; exit 0'
stub open           'exit 0'
stub tmutil         '[ "${TM_FAIL:-0}" = 1 ] && { echo "tmutil: backupd not responding"; exit 1; }; echo "tmutil: No destinations configured."'
stub defaults       'exit 1'
stub docker         'exit 1'
stub crontab        'exit 1'
stub systemctl      'exit 1'
stub lsblk          'echo "NAME FSTYPE"; echo "sda1 ext4"'
stub rh7-fleet-update 'echo "dry-run result: no-op"'
cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
out=""; wfmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;; -w) wfmt="$2"; shift 2 ;; --max-time) shift 2 ;;
    -*) shift ;; *) url="$1"; shift ;;
  esac
done
echo "curl $url" >>"$CALLS"
case "$url" in file://*) exec "$REAL_CURL" -fsSL "$url" ${out:+-o "$out"} ;; esac
[ "${MOCK_ONLINE:-1}" = 1 ] || exit 7
code=200; body=""
case "$url" in
  */api/health)               body='{"status":"ok","service":"config-service"}' ;;
  */api/fleet/health)         body="$(cat "$FIX_DIR/health.json")" ;;
  */api/fleet/backup/*)       [ "${BACKUP_DOWN:-0}" = 1 ] && exit 22; body="$(cat "$FIX_DIR/${BACKUP_FIXTURE:-backup.json}")" ;;
  */api/fleet/retirement/*)   code=403; body='{"error":"admin only"}' ;;
  */api/audit/*)              body="$(cat "$FIX_DIR/audit.json")" ;;
  *) code=404 ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
[ -n "$wfmt" ] && printf '%s' "$code"
[ "$code" = 200 ] || exit 22
FAKE_CURL
chmod +x "$FAKE_BIN/curl"
ln -s "$REAL_PY" "$FAKE_BIN/python3"

# ── fixtures ────────────────────────────────────────────────────────────────
cat >"$FIX_DIR/health.json" <<'JSON'
{"status":"critical","action_items":[
 {"kind":"backup","severity":"critical","hostname":"test-mac","summary":"2 backup blocker(s)","next_action":"Open backup detail","command":null},
 {"kind":"security","severity":"critical","hostname":"test-mac","summary":"Firewall OFF","next_action":"Review","command":null},
 {"kind":"security","severity":"critical","hostname":"test-mac","summary":"FileVault OFF","next_action":"Review","command":null},
 {"kind":"security","severity":"warning","hostname":"test-mac","summary":"Age key missing","next_action":"Create","command":null},
 {"kind":"stale_audit","severity":"warning","hostname":"test-mac","summary":"Audit is 300h old","next_action":"Run","command":"curl -fsSL config.rh7labs.com/collector-runner | bash -s -- --install"},
 {"kind":"resource","severity":"critical","hostname":"test-mac","summary":"Disk 92% full","next_action":"Free","command":null},
 {"kind":"config-drift-collection","severity":"warning","hostname":"test-mac","summary":"Configuration drift collection failed","next_action":"nix not found.","command":"cd ~/dotfiles && ./scripts/audit-config-drift.sh --json"},
 {"kind":"fleet-update-stale","severity":"warning","hostname":"test-mac","summary":"No successful fleet update in over 3 days","next_action":"Check","command":null},
 {"kind":"tailscale_key","severity":"warning","hostname":"test-mac","summary":"Tailscale key expires in 5d","next_action":"Re-authenticate Tailscale","command":null},
 {"kind":"security","severity":"critical","hostname":"rouvens-mac-studio","summary":"Firewall OFF","next_action":"Review","command":null},
 {"kind":"security","severity":"critical","hostname":"other-host","summary":"OTHER-HOST-ITEM","next_action":"x","command":null}
]}
JSON
cat >"$FIX_DIR/backup.json" <<'JSON'
{"hostname":"test-mac","audited_at":"2026-11-01 00:00:00","audit_age_hours":200,
 "paths":[{"path":"~/.ssh","why":"SSH private keys","status":"unprotected"},
          {"path":"~/code","why":"source code","status":"protected"},
          {"path":"~/.config","why":"tool configuration","status":"unprotected"}],
 "at_risk_repos":[{"path":"~/code/gone","dirty":3,"unpushed":1,"branch":"main"}]}
JSON
cat >"$FIX_DIR/backup-repo.json" <<'JSON'
{"hostname":"test-mac","audited_at":"2026-11-01 00:00:00","audit_age_hours":200,"paths":[],
 "at_risk_repos":[{"path":"~/code/my repo","dirty":0,"unpushed":1,"branch":"main"},
                  {"path":"~/code/lonely","dirty":0,"unpushed":1,"branch":"main","has_remote":false}]}
JSON
"$REAL_PY" -c 'import datetime; t=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=300); print("{\"hostname\":\"test-mac\",\"audited_at\":\"%s\"}" % t.strftime("%Y-%m-%d %H:%M:%S"))' >"$FIX_DIR/audit.json"

# ── harness ─────────────────────────────────────────────────────────────────
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }
has()   { if grep -qF -- "$2" <<<"$OUT"; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: output lacks [$2]"; printf '%s\n' "$OUT" | sed 's/^/       | /'; fi; }
hasnt() { if grep -qF -- "$2" <<<"$OUT"; then fail=$((fail + 1)); echo "  FAIL $1: output has [$2]"; else pass=$((pass + 1)); echo "  ok   $1"; fi; }
called()    { grep -qF -- "$1" "$CALLS" 2>/dev/null; }
reset() { : >"$CALLS"; echo 0 >"$TEST_ROOT/fw"; echo 92 >"$TEST_ROOT/disk"; rm -rf "${TEST_ROOT:?}/home"; mkdir -p "$TEST_ROOT/home"; }

ENVV=(env -i PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT"
      CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" FIX_DIR="$FIX_DIR" REAL_CURL="$REAL_CURL"
      CONFIG_SERVICE_PIN_SYSTEM="$TEST_ROOT/no-pin" CONFIG_SERVICE_PIN_USER="$TEST_ROOT/no-pin"
      CONFIG_SERVICE_FALLBACKS="http://mock-studio:3456"
      FLEET_FIX_SOCKETFILTERFW="$FAKE_BIN/socketfilterfw"
      FLEET_FIX_FLEET_UPDATE_ROOT="$TEST_ROOT/fu")
# ff [VAR=val …] -- args : run from the checkout under /bin/bash (the macOS bash 3.2)
ff() {
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done; shift
  OUT="$("${ENVV[@]}" ${extra[@]+"${extra[@]}"} /bin/bash "$FF" "$@" </dev/null 2>&1)"; RC=$?
}
# ffpipe [VAR=val …] -- args : the clone-free `curl … | bash -s --` path
ffpipe() {
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done; shift
  OUT="$("${ENVV[@]}" FLEET_FIX_RAW_BASE="file://$REPO_ROOT" ${extra[@]+"${extra[@]}"} /bin/bash -s -- "$@" <"$FF" 2>&1)"; RC=$?
}

echo "== fix_id_for maps every action-item kind to its fix id =="
eval "$(sed -n '/^fix_id_for() {/,/^}/p' "$FF")"
check "backup"                          "$(fix_id_for backup '2 backup blocker(s)' Darwin)" backup
check "stale_audit -> audit"            "$(fix_id_for stale_audit 'Audit is 300h old' Linux)" audit
check "no_audit -> audit"               "$(fix_id_for no_audit 'Device has never uploaded an audit' Linux)" audit
check "unparseable_audit -> audit"      "$(fix_id_for unparseable_audit 'x' Darwin)" audit
check "Disk -> resources"               "$(fix_id_for resource 'Disk 81% full' Linux)" resources
check "High swap -> resources"          "$(fix_id_for resource 'High swap: 5GB' Darwin)" resources
check "config-drift -> drift"           "$(fix_id_for config-drift '2 risky configuration drift item(s)' Darwin)" drift
check "config-drift-collection -> drift" "$(fix_id_for config-drift-collection 'Configuration drift collection failed' Darwin)" drift
check "fleet-update -> fleet-update"    "$(fix_id_for fleet-update 'Fleet update failed: build-failed' Darwin)" fleet-update
check "fleet-update-stale"              "$(fix_id_for fleet-update-stale 'No successful fleet update recorded' Darwin)" fleet-update
check "Age key missing -> age-key"      "$(fix_id_for security 'Age key missing' Linux)" age-key
check "Firewall OFF -> firewall"        "$(fix_id_for security 'Firewall OFF' Darwin)" firewall
check "FileVault OFF -> filevault"      "$(fix_id_for security 'FileVault OFF' Darwin)" filevault
check "No disk encryption on Linux"     "$(fix_id_for security 'No disk encryption' Linux)" disk-encryption
check "SIP disabled: no device fix"     "$(fix_id_for security 'SIP disabled' Darwin)" ""
check "tailscale_key: no device fix"    "$(fix_id_for tailscale_key 'Tailscale key expires in 5d' Darwin)" ""
check "control-plane-deploy: no fix"    "$(fix_id_for control-plane-deploy 'Config-service auto-deploy: failed' Darwin)" ""

echo "== doctor (clone-free curl|bash path) lists this host's items with fix ids =="
reset; ffpipe -- doctor
check "doctor exits 1 with items open" "$RC" 1
has "backup item -> backup"           "backup: 2 backup blocker(s)  (fix id: backup)"
has "firewall item -> firewall"       "Firewall OFF  (fix id: firewall)"
has "filevault item -> filevault"     "FileVault OFF  (fix id: filevault)"
has "age key -> age-key"              "Age key missing  (fix id: age-key)"
has "stale audit -> audit"            "Audit is 300h old  (fix id: audit)"
has "disk -> resources"               "Disk 92% full  (fix id: resources)"
has "drift collection -> drift"       "drift collection failed  (fix id: drift)"
has "fleet-update-stale"              "(fix id: fleet-update)"
has "unmapped item is MANUAL with next_action" "[MANUAL] [warning] tailscale_key: Tailscale key expires in 5d"
has "commands use the curl form when clone-free" "fleet-fix.sh | bash -s -- backup"
hasnt "other hosts' items are excluded" "OTHER-HOST-ITEM"
has "plans run for each fix id"       "== plan: resources =="
# shellcheck disable=SC2088  # literal "~/" as printed
has "backup plan lists the secret to escrow" "~/.ssh (SSH private keys) is unprotected"
has "retirement 403 is explained"     "admin-gated"
check "helpers were fetched from the raw base" "$(grep -c 'curl file://.*/scripts/lib/config-service.sh' "$CALLS")" 1

echo "== dry-run never mutates =="
reset
ffpipe SUDO_N_EXIT=1 FAKE_SWAP_MB=3000 -- doctor   # clone-free: drift has no checkout to run against
for id in backup age-key audit firewall filevault resources fleet-update; do
  ff SUDO_N_EXIT=1 FAKE_SWAP_MB=3000 -- "$id"
done
mk="$(grep -E 'setglobalstate|fdesetup enable|nix-collect-garbage --delete|brew cleanup|launchctl (bootstrap|bootout|load|unload|kickstart)|^open |tmutil (enable|setdestination)' "$CALLS" || true)"
check "no mutating command was invoked" "$mk" ""
check "sudo only ever probed non-interactively" "$(grep '^sudo' "$CALLS" | grep -v '^sudo -n true$' || true)" ""
ff -- firewall;  check "firewall dry-run with FW off exits 1" "$RC" 1; has "firewall dry-run is a FIX" "[FIX]    application firewall is OFF"
has "firewall dry-run names the command" "--setglobalstate on"
ff -- resources; check "resources dry-run (92%) exits 1" "$RC" 1; has "dead store paths counted" "2 dead store paths"
ff -- audit;     has "stale audit detected via the API" "last audit is 300h old"

echo "== doctor --apply stays read-only =="
reset; ffpipe FAKE_SWAP_MB=3000 -- doctor --apply --yes
mk="$(grep -E 'setglobalstate|fdesetup enable|nix-collect-garbage --delete|brew cleanup|launchctl (bootstrap|bootout)|^open |^sudo' "$CALLS" | grep -v '^sudo -n true$' || true)"
check "doctor --apply ran no mutating command" "$mk" ""
has "says --apply is ignored" "doctor is read-only; --apply ignored"

echo "== doctor propagates a plan error (backup endpoint down) as exit 2 =="
reset; ffpipe BACKUP_DOWN=1 -- doctor
check "plan error -> exit 2" "$RC" 2

echo "== backup re-checks EVERY local branch, quotes paths =="
reset
R="$TEST_ROOT/home/code/my repo"; G=(git -c user.name=t -c user.email=t@t -c init.defaultBranch=main)
rm -rf "${TEST_ROOT:?}/remote.git"
"${G[@]}" init -q --bare "$TEST_ROOT/remote.git"
"${G[@]}" init -q "$R" && "${G[@]}" -C "$R" commit -q --allow-empty -m one \
  && "${G[@]}" -C "$R" remote add origin "$TEST_ROOT/remote.git" && "${G[@]}" -C "$R" push -q origin main 2>/dev/null \
  && "${G[@]}" -C "$R" switch -q -c feature && "${G[@]}" -C "$R" commit -q --allow-empty -m two \
  && "${G[@]}" -C "$R" switch -q main
"${G[@]}" init -q "$TEST_ROOT/home/code/lonely" && "${G[@]}" -C "$TEST_ROOT/home/code/lonely" commit -q --allow-empty -m solo
ff BACKUP_FIXTURE=backup-repo.json -- backup
# shellcheck disable=SC2088  # literal "~/" as printed
has "unpushed feature branch is caught though HEAD is pushed" "~/code/my repo: 1 commit(s) on local branches no remote has"
has "path is shell-quoted in the command" "git -C $TEST_ROOT/home/code/my\\ repo push origin 'refs/heads/*:refs/heads/backup/test-mac-"
has "remote-less repo: create a remote, no push to a missing origin" "NO git remote — create a private remote first"
has "remote-less repo: gh repo create command" "gh repo create lonely --private --source $TEST_ROOT/home/code/lonely"

echo "== --apply firewall: right command, verified =="
reset; ff FW_CLI_WORKS=1 -- firewall --apply --yes
check "apply exits 0 once verified on" "$RC" 0
check "called sudo socketfilterfw --setglobalstate on" "$(called "sudo $FAKE_BIN/socketfilterfw --setglobalstate on" && echo y)" y
check "re-verified state after enabling" "$(grep -c 'socketfilterfw --getglobalstate' "$CALLS")" 2
has "reports verified" "application firewall enabled (verified)"

echo "== --apply firewall when the CLI is a TCC no-op: hand off to System Settings =="
reset; ff FW_CLI_WORKS=0 -- firewall --apply --yes
check "still off -> exit 1" "$RC" 1
check "opened the Firewall settings pane" "$(grep -c '^open x-apple.systempreferences' "$CALLS")" 1
has "says it is still off" "application firewall is still OFF"

echo "== rouvens-mac-studio is exempt (#93) =="
reset; ff FAKE_HOST=Rouvens-Mac-Studio.local -- firewall --apply --yes
check "studio: exit 0" "$RC" 0
check "studio: firewall untouched" "$(grep -c 'socketfilterfw' "$CALLS")" 0
has "studio: says exempt" "exempt on rouvens-mac-studio by design (#93)"
reset; ff FAKE_HOST=Rouvens-Mac-Studio.local -- firewall --apply --yes --force
check "studio --force: enables" "$(called "socketfilterfw --setglobalstate on" && echo y)" y
reset; ff FAKE_HOST=Rouvens-Mac-Studio.local -- doctor
has "doctor marks the studio firewall item OK" "[OK]     [critical] security: Firewall OFF — exempt"

echo "== usage errors exit 64 =="
ff -- no-such-fix;        check "unknown fix id" "$RC" 64; has "names it" "unknown fix id: no-such-fix"
ff -- firewall --bogus;   check "unknown flag" "$RC" 64
ff --;                    check "no fix id" "$RC" 64
ff -- firewall backup;    check "two fix ids" "$RC" 64

echo "== offline config service: doctor degrades, exit 2 =="
reset; ff MOCK_ONLINE=0 -- doctor
check "doctor offline exits 2" "$RC" 2
has "clear message" "config service unreachable"
reset; ff MOCK_ONLINE=0 -- backup
check "backup offline exits 2" "$RC" 2
has "backup still reports local Time Machine state" "Time Machine: no destination configured"
reset; ffpipe FLEET_FIX_RAW_BASE="file://$TEST_ROOT/nowhere" -- doctor
check "clone-free, helpers unfetchable, no ~/dotfiles -> exit 2" "$RC" 2
has "says why" "could not fetch helpers"

echo "== a tmutil failure is unknown, never a false OK =="
reset; ff MOCK_ONLINE=0 TM_FAIL=1 -- backup
has "tmutil error -> MANUAL unknown" "Time Machine: status unknown (tmutil exit 1"
hasnt "never reported configured" "destination configured"

echo "== --apply resources: only GC + brew cleanup =="
reset; ff -- resources --apply
check "cleanup brought the disk under the threshold" "$RC" 0
check "nix-collect-garbage --delete-older-than 30d" "$(called "nix-collect-garbage --delete-older-than 30d" && echo y)" y
check "brew cleanup" "$(called "brew cleanup" && echo y)" y
check "no sudo for cleanup" "$(grep -c '^sudo' "$CALLS")" 0

echo "== Linux disk-encryption is report-only =="
reset; ff FAKE_OS=Linux -- disk-encryption --apply --yes
check "no LUKS -> exit 1" "$RC" 1
has "explains in-place is impossible" "cannot be encrypted in place"
check "nothing privileged ran" "$(grep -c '^sudo' "$CALLS")" 0

echo "== fleet-update: state + log, dry-run needs sudo =="
reset; mkdir -p "$TEST_ROOT/fu/var/lib/rh7-fleet-update" "$TEST_ROOT/fu/var/log"
printf '{"last_result": "failed", "reason": "build-failed"}\n' >"$TEST_ROOT/fu/var/lib/rh7-fleet-update/state.json"
printf 'line-a\nlast-log-line\n' >"$TEST_ROOT/fu/var/log/rh7-fleet-update.log"
ff SUDO_N_EXIT=1 -- fleet-update
check "failed state -> exit 1" "$RC" 1
has "shows the state" '"reason": "build-failed"'
has "shows the log tail" "last-log-line"
has "prints the root dry-run command" "sudo rh7-fleet-update --dry-run"
check "did not run it without cached sudo" "$(grep -c 'rh7-fleet-update --dry-run' "$CALLS")" 0
reset; mkdir -p "$TEST_ROOT/fu/var/lib/rh7-fleet-update"
recent="$("$REAL_PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"last_result": "applied", "last_success_at": "%s"}\n' "$recent" >"$TEST_ROOT/fu/var/lib/rh7-fleet-update/state.json"
ff SUDO_N_EXIT=0 -- fleet-update
check "cached sudo: dry-run runs non-interactively" "$(called "sudo -n rh7-fleet-update --dry-run" && echo y)" y
check "applied, recent success, ok dry-run -> exit 0" "$RC" 0
printf '{"last_result": "no-op", "last_success_at": "2020-01-01T00:00:00Z"}\n' >"$TEST_ROOT/fu/var/lib/rh7-fleet-update/state.json"
ff SUDO_N_EXIT=0 -- fleet-update
check "old last_success_at stays unresolved (stale)" "$RC" 1
has "says how stale" "last successful fleet update"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
