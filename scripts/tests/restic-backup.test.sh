#!/usr/bin/env bash
# Coverage for scripts/restic-backup.sh (org.rh7.restic-backup) and the
# rh7-restic entry of audit-device.sh's backup_posture.
#
# restic, pmset, curl and hostname are stubs that LOG their argv, so the
# properties that matter are asserted on what was invoked and on the status
# file the rh-device-management backup-coverage contract reads:
#   - unconfigured = a no-op that records not-configured (safe to enable early);
#   - battery < 30 % and an unreachable server skip WITHOUT calling restic, and
#     still write status (snapshot fields carried forward);
#   - EPERM (macOS privacy) is permission-denied and drops that path from
#     `paths`; other unreadable files do not fail the run;
#   - auth / lock failures get their reason token; only existing paths are
#     backed up and recorded; the REST password never reaches argv;
#   - setup refuses a token for another host and never overwrites the key.
# The real-server end-to-end run is scripts/tests/restic-backup-e2e.sh (needs nix).
#
# Run: bash scripts/tests/restic-backup.test.sh   (needs jq, python3)
# "~/…" is literal text here, exactly as the script stores and prints it.
# shellcheck disable=SC2088
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../restic-backup.sh"
AUDIT="$HERE/../audit-device.sh"
for tool in jq python3; do command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool is required" >&2; exit 1; }; done

T="$(mktemp -d "${TMPDIR:-/tmp}/rrb.XXXXXX")"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; CALLS="$T/calls.log"; mkdir -p "$BIN"

stub() { # stub NAME BODY — argv logged first
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$CALLS" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
stub hostname 'echo "${FAKE_HOST:-Test-Mac.local}"'
# curl: the rest-server probe answers CURL_CODE; the config service answers
# its health check when CS_UP is set and the approved list from APPROVED_BODY.
stub curl     'url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/health) [ -n "${CS_UP:-}" ] || exit 7; printf "{\"status\":\"ok\",\"service\":\"config-service\"}"; exit 0 ;;
  */backup-paths) [ -n "${CS_UP:-}" ] && [ -n "${APPROVED_BODY:-}" ] || exit 22; printf "%s" "$APPROVED_BODY"; exit 0 ;;
esac
echo "${CURL_CODE:-401}"'
stub pmset    'printf "%b\n" "${PMSET_OUT:-Now drawing from '"'"'AC Power'"'"'}"'
# restic: backup prints a summary; RESTIC_MODE shapes the failure.
cat >"$BIN/restic" <<STUB
#!/usr/bin/env bash
echo "restic \$* | user=\${RESTIC_REST_USERNAME:-} repo=\${RESTIC_REPOSITORY:-} pwfile=\${RESTIC_PASSWORD_FILE:-} restpw=\${RESTIC_REST_PASSWORD:+set}" >>"$CALLS"
summary='{"message_type":"summary","files_new":3,"data_added":1234,"snapshot_id":"abcdef0123456789abcdef"}'
case "\$1" in
  cat) [ -n "\${CAT_ERR:-}" ] && echo "\$CAT_ERR" >&2; exit "\${CAT_RC:-0}" ;;
  init) exit 0 ;;
  backup)
    while [ "\$1" != "--" ]; do shift; done; shift
    case "\${RESTIC_MODE:-ok}" in
      ok) echo "\$summary"; exit 0 ;;
      eperm) echo "{\"message_type\":\"error\",\"error\":{\"message\":\"open \$1: operation not permitted\"},\"during\":\"scan\",\"item\":\"\$1\"}" >&2
             echo "\$summary"; exit 3 ;;
      eacces) echo "{\"message_type\":\"error\",\"error\":{\"message\":\"open \$1/x: permission denied\"},\"during\":\"archival\",\"item\":\"\$1/x\"}" >&2
              echo "\$summary"; exit 3 ;;
      auth) echo "Fatal: unable to open config file: unexpected HTTP response (401): 401 Unauthorized" >&2; exit 1 ;;
      locked) echo "Fatal: unable to create lock in backend: repository is already locked" >&2; exit 11 ;;
      weird) echo "Fatal: something else entirely" >&2; exit 1 ;;
      wrongkey) echo "Fatal: wrong password or no key found" >&2; exit 12 ;;
      slow) echo started >"\$HOME/restic-started"; trap 'echo "{\"message_type\":\"exit_error\",\"code\":130}" >&2; exit 130' TERM; sleep 20 & wait; exit 0 ;;
    esac ;;
esac
STUB
chmod +x "$BIN/restic"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }
called() { grep -cF -- "$1" "$CALLS" 2>/dev/null || true; }

H="$T/home"; STATUS="$H/.local/state/rh7-restic/status.json"; CONF="$H/.config/rh7-restic"
PATHS_SPEC=$'~/.ssh\n~/.config\n~/.gnupg\n~/code\n~/Projects\n/nonexistent-abs'
reset() {
  rm -rf "$H" "$CALLS"; : >"$CALLS"
  mkdir -p "$H/.ssh" "$H/.config/x/Caches" "$H/code/p"
}
configure() { mkdir -p "$CONF"; printf test-mac >"$CONF/server-user"; printf restpw >"$CONF/server-password"; printf key >"$CONF/repo-password"; }
# rb [VAR=val …] -- args
rb() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" TMPDIR="$T" RH7_RESTIC_BIN="$BIN/restic" \
    RH7_RESTIC_PATHS="$PATHS_SPEC" RH7_RESTIC_EXCLUDES=$'node_modules\n~/.config/**/Cache*' \
    RH7_RESTIC_REPO_HOST=studio RH7_RESTIC_PORT=8000 ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
st() { jq -c "$1" "$STATUS" 2>/dev/null; }

echo "== not configured: a no-op that records not-configured =="
reset; rb -- run
check "exit 0" "$RC" 0
check "last_result" "$(st .last_result)" '"not-configured"'
check "configured false" "$(st .configured)" false
check "restic never called" "$(called 'restic ')" 0
check "contract keys present" "$(st 'keys_unsorted')" '["schema","enabled","configured","last_run_at","last_result","reason","last_snapshot_time","snapshot_id","files_new","bytes_added","paths","repo_host","exclude_larger_than","approved_paths","skipped_paths","approved_source"]'
check "nothing fetched before setup: approved fields empty" "$(st '[.approved_paths,.skipped_paths,.approved_source]')" '[[],[],null]'
check "schema 1, enabled, repo_host" "$(st '[.schema,.enabled,.repo_host]')" '[1,true,"studio"]'

echo "== ok run: only existing paths, status per contract =="
reset; configure; rb -- run
check "exit 0" "$RC" 0
check "last_result ok, reason null" "$(st '[.last_result,.reason]')" '["ok",null]'
check "paths = existing ones, ~/ form" "$(st .paths)" '["~/.ssh","~/.config","~/code"]'
check "snapshot_id is 8 hex" "$(st .snapshot_id)" '"abcdef01"'
check "files_new / bytes_added" "$(st '[.files_new,.bytes_added]')" '[3,1234]'
check "last_snapshot_time is ISO UTC" "$(st '.last_snapshot_time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')" true
check "last_run_at is ISO UTC" "$(st '.last_run_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')" true
check "backed up absolute existing paths only" "$(grep -cF -- "-- $H/.ssh $H/.config $H/code |" "$CALLS")" 1
check "REST password via env, never argv" "$(grep '^restic backup' "$CALLS" | grep -c 'restpw ')" 0
check "REST password was set in env" "$(called 'restpw=set')" 1
check "repository URL is the per-host private repo" "$(called 'repo=rest:http://studio:8000/test-mac/')" 1
check "host + tag set" "$(called '--host test-mac --tag rh7-restic')" 1
check "size cap applied" "$(called '--exclude-larger-than 100M')" 1
check "size cap recorded for the audit's coverage check" "$(st .exclude_larger_than)" '"100M"'
check "no temp files left in state dir" "$(find "$H/.local/state/rh7-restic" -name '.status.json.*' | wc -l | tr -d ' ')" 0
check "status 0644" "$(ls -l "$STATUS" | cut -c1-10)" "-rw-r--r--"
check "never forgets / prunes" "$(grep -cE '^restic (forget|prune)' "$CALLS")" 0

echo "== exclude file: ~ expanded, credentials dir excluded =="
reset; configure
sed 's|rm -rf "\$tmp"|cp "$tmp/excludes" "$HOME/excl"; rm -rf "$tmp"|' "$SCRIPT" >"$T/rb-keep.sh"
SAVE="$SCRIPT"; SCRIPT="$T/rb-keep.sh"; rb -- run; SCRIPT="$SAVE"
check "~/.config/**/Cache* expanded" "$(grep -cxF "$H/.config/**/Cache*" "$H/excl")" 1
check "plain pattern kept" "$(grep -cx 'node_modules' "$H/excl")" 1
check "rh7-restic credentials excluded" "$(grep -cxF "$H/.config/rh7-restic" "$H/excl")" 1
check "no symlinked roots -> no rebased lines" "$(wc -l <"$H/excl" | tr -d ' ')" 3
reset; mkdir -p "$T/realconf/x/Caches"; rm -rf "$H/.config"; ln -s "$T/realconf" "$H/.config"; configure
SCRIPT="$T/rb-keep.sh"; rb -- run; SCRIPT="$SAVE"
RC_REAL="$(realpath "$T/realconf")"
check "symlinked ~/.config: Cache exclude rebased onto the target" "$(grep -cxF "$RC_REAL/**/Cache*" "$H/excl")" 1
check "symlinked ~/.config: credentials dir rebased onto the target" "$(grep -cxF "$RC_REAL/rh7-restic" "$H/excl")" 1
rm -rf "$T/realconf"

echo "== battery: < 30 % skips (no restic), >= 30 % runs =="
reset; configure; rb -- run   # a good snapshot to carry forward
: >"$CALLS"
rb PMSET_OUT="Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t25%; discharging" -- run
check "exit 0" "$RC" 0
check "skipped on-battery" "$(st '[.last_result,.reason]')" '["skipped","on-battery"]'
check "restic not called" "$(called 'restic ')" 0
check "snapshot fields carried forward" "$(st '[.snapshot_id,.files_new,.bytes_added]')" '["abcdef01",3,1234]'
check "configured still true" "$(st .configured)" true
rb PMSET_OUT="Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t45%; discharging" -- run
check "45 % on battery runs" "$(st .last_result)" '"ok"'
rb PMSET_OUT="Now drawing from 'Battery Power'" -- run
check "battery with unreadable charge skips" "$(st .reason)" '"on-battery"'

echo "== offline: unreachable server skips without restic =="
reset; configure; rb CURL_CODE=000 -- run
check "exit 0" "$RC" 0
check "skipped offline" "$(st '[.last_result,.reason]')" '["skipped","offline"]'
check "restic not called" "$(called 'restic ')" 0
check "no snapshot yet -> null" "$(st .last_snapshot_time)" null

echo "== EPERM (macOS privacy) = permission-denied, path dropped =="
reset; configure; mkdir -p "$H/Documents"
PATHS_SPEC=$'~/Documents\n~/code' rb RESTIC_MODE=eperm -- run
check "exit 1" "$RC" 1
check "failed permission-denied" "$(st '[.last_result,.reason]')" '["failed","permission-denied"]'
check "unreadable top-level path not in paths" "$(st .paths)" '["~/code"]'
check "partial snapshot still recorded" "$(st .snapshot_id)" '"abcdef01"'
has_hint="$(grep -c 'Full Disk Access' <<<"$OUT")"; check "log names the fix" "$has_hint" 1

echo "== EACCES on a nested file is a warning, not a failure =="
reset; configure; rb RESTIC_MODE=eacces -- run
check "exit 0" "$RC" 0
check "ok" "$(st '[.last_result,.reason]')" '["ok",null]'
check "paths intact" "$(st .paths)" '["~/.ssh","~/.config","~/code"]'

echo "== fatal failures are classified; snapshot fields carried forward =="
reset; configure; rb -- run
rb RESTIC_MODE=auth -- run;   check "401 -> auth-failed" "$(st '[.last_result,.reason]')" '["failed","auth-failed"]'; check "exit 1" "$RC" 1
check "previous snapshot kept" "$(st .snapshot_id)" '"abcdef01"'
rb RESTIC_MODE=locked -- run; check "exit 11 -> repo-locked" "$(st .reason)" '"repo-locked"'
rb RESTIC_MODE=weird -- run;  check "anything else -> unknown" "$(st .reason)" '"unknown"'
grep -q 'auth-failed — REST token' "$H/.local/state/rh7-restic/backup.log"; check "401 logged as the REST token" "$?" 0
rb RESTIC_MODE=wrongkey -- run; check "exit 12 -> auth-failed" "$(st .reason)" '"auth-failed"'
check "exit 12 logged as the encryption key" "$(grep 'failed: auth-failed' "$H/.local/state/rh7-restic/backup.log" | tail -1 | grep -c 'encryption key')" 1

echo "== carried snapshot keeps ITS paths (no credit for a newly added path) =="
reset; configure; rb -- run
mkdir -p "$H/Projects"
rb CURL_CODE=000 -- run
check "offline run after adding ~/Projects: paths of the carried snapshot" "$(st '[.last_result,.paths]')" '["skipped",["~/.ssh","~/.config","~/code"]]'
rb RESTIC_MODE=auth -- run
check "failed run: same" "$(st .paths)" '["~/.ssh","~/.config","~/code"]'
rb -- run
check "next snapshot: new path credited" "$(st .paths)" '["~/.ssh","~/.config","~/code","~/Projects"]'

echo "== a stop signal to the job group still records the run =="
reset; configure
python3 - "$T" "$H" "$BIN" "$SCRIPT" "$PATHS_SPEC" <<'PY'
import os, signal, subprocess, sys, time
T, H, BIN, SCRIPT, PATHS = sys.argv[1:6]
env = {"PATH": BIN + ":/usr/bin:/bin", "HOME": H, "TMPDIR": T, "RH7_RESTIC_BIN": BIN + "/restic",
       "RH7_RESTIC_PATHS": PATHS, "RH7_RESTIC_REPO_HOST": "studio", "RESTIC_MODE": "slow"}
p = subprocess.Popen(["bash", SCRIPT, "run"], env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if os.path.exists(H + "/restic-started"):
        break
    time.sleep(0.05)
os.killpg(p.pid, signal.SIGTERM)   # what the launcher relays: the whole group
p.wait(timeout=10)
PY
check "stopped run recorded as failed" "$(st '[.last_result,.reason]')" '["failed","unknown"]'
check "log says it was terminated" "$(grep -c 'terminated by signal' "$H/.local/state/rh7-restic/backup.log")" 1
check "lock released" "$([ -d "$H/.local/state/rh7-restic/run.lock" ] && echo held || echo free)" free

echo "== a symlinked root is backed up through its target, reported by its name =="
reset; configure; mkdir -p "$T/realdot"; echo x >"$T/realdot/f"; ln -s "$T/realdot" "$H/dotfiles"
PATHS_SPEC=$'~/dotfiles\n~/code' rb -- run
check "restic gets the target, not the link" "$(grep -cF -- "-- $(realpath "$T/realdot") $H/code |" "$CALLS")" 1
check "paths report the configured name" "$(st .paths)" '["~/dotfiles","~/code"]'
rm -rf "$T/realdot"

echo "== no configured path exists =="
reset; configure; PATHS_SPEC='~/nope' rb -- run
check "failed unknown, exit 1" "$(st '[.last_result,.reason]')/$RC" '["failed","unknown"]/1'
check "paths empty" "$(st .paths)" '[]'

echo "== run without the wrapper's paths is a usage error =="
reset; configure; PATHS_SPEC='' rb -- run
check "exit 2" "$RC" 2

echo "== setup =="
reset
printf 'rh7-restic:other-mac:pw\n' | { rb -- setup; }
check "token for another host refused (exit 2)" "$RC" 2
check "nothing written" "$(ls "$CONF" 2>/dev/null | wc -l | tr -d ' ')" 0
OUT="$(printf 'rh7-restic:test-mac:s3cr:et\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" RH7_RESTIC_REPO_HOST=studio CAT_RC=10 bash "$SCRIPT" setup 2>&1)"; RC=$?
check "setup ok" "$RC" 0
check "password keeps everything after host:" "$(cat "$CONF/server-password")" "s3cr:et"
check "server-user" "$(cat "$CONF/server-user")" test-mac
check "files 0600" "$(ls -l "$CONF/server-password" "$CONF/repo-password" "$CONF/server-user" | cut -c1-10 | sort -u)" "-rw-------"
check "dir 0700" "$(ls -ld "$CONF" | cut -c1-10)" "drwx------"
check "key generated (>= 32 chars)" "$([ "$(wc -c <"$CONF/repo-password")" -ge 32 ] && echo y)" y
check "missing repo -> restic init" "$(called 'restic init')" 1
check "prints the escrow command" "$(grep -c 'escrow-secrets-1password.sh --env ~/.config/rh7-restic/repo-password' <<<"$OUT")" 2
key="$(cat "$CONF/repo-password")"; : >"$CALLS"
printf 'rh7-restic:test-mac:pw2\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" CAT_RC=0 bash "$SCRIPT" setup >/dev/null 2>&1
check "re-setup keeps the existing key" "$(cat "$CONF/repo-password")" "$key"
check "existing repo -> no init" "$(called 'restic init')" 0
check "rotated REST password stored" "$(cat "$CONF/server-password")" pw2
printf 'rh7-restic:test-mac:pw2\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" CAT_RC=12 bash "$SCRIPT" setup >"$T/o" 2>&1; RC=$?
check "key does not open repo -> exit 2, never init" "$RC/$(called 'restic init')" "2/0"
check "says restore from 1Password" "$(grep -c '1Password' "$T/o")" 1
printf 'garbage\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" bash "$SCRIPT" setup >/dev/null 2>&1; check "non-token rejected" "$?" 2
printf 'rh7-restic:other-mac:pw\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" bash "$SCRIPT" setup --force >/dev/null 2>&1
check "--force accepts a registry name that differs" "$(cat "$CONF/server-user")" other-mac
printf 'rh7-restic:other-mac:typo\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" CAT_RC=1 \
  CAT_ERR='Fatal: unable to open config file: unexpected HTTP response (401): 401 Unauthorized' bash "$SCRIPT" setup --force >"$T/o" 2>&1; RC=$?
check "rejected replacement token -> exit 2" "$RC" 2
check "working credentials kept" "$(cat "$CONF/server-password")" pw
check "says nothing changed" "$(grep -c 'nothing changed' "$T/o")" 1
printf 'rh7-restic:other-mac:pw9\n' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" RH7_RESTIC_BIN="$BIN/restic" CURL_CODE=000 bash "$SCRIPT" setup --force >/dev/null 2>&1
check "unreachable server -> credentials untouched" "$(cat "$CONF/server-password")" pw

echo "== restore-hint / status =="
OUT="$(env -i PATH="$BIN:/usr/bin:/bin" HOME="$H" bash "$SCRIPT" restore-hint 2>&1)"
check "restore command shown" "$(grep -c 'restore latest --host other-mac --target' <<<"$OUT")" 1
check "no password printed" "$(grep -c 'pw2' <<<"$OUT")" 0
reset; configure; rb -- run; rb -- status
check "status shows result" "$(grep -c 'last run: .* — ok' <<<"$OUT")" 1

echo "== approved paths: fetched, validated, merged, cached =="
CS=(CONFIG_SERVICE_URL=http://cs CS_UP=1)
reset; configure; mkdir -p "$H/Proton" "$H/test" "$H/code/p" "$H/Library/Caches/x" "$H/Dropbox/a" "$T/outside"
ln -s "$T/outside" "$H/out"; ln -s "$H/Library/Caches" "$H/cachelink"
BODY='{"hostname":"test-mac","updated_at":"2026-11-11T00:00:00Z","paths":["~/Proton","~/../etc","~/Library/Caches/x","~/library/CACHES/x","~/.TRASH/x","~/library/cloudstorage/x","~/LIBRARY/Mobile Documents/x","~/DROPBOX (Personal)/x","~/Dropbox/a","~/nope","~/code/p","/etc","~/","~/test/","~/Proton","~/Proton//","~/out","~/cachelink","~/.Trash","~/Library/Mobile Documents/x","~/a\nb","~/a\u0000b","~/./Proton"]}'
rb "${CS[@]}" APPROVED_BODY="$BODY" -- run
check "exit 0" "$RC" 0
check "approved_source control-plane" "$(st .approved_source)" '"control-plane"'
check "approved: valid ones, trailing slashes normalized, deduped" "$(st .approved_paths)" '["~/Proton","~/code/p","~/test"]'
check "skipped with reasons (forbidden roots matched case-insensitively)" "$(st '[.skipped_paths[] | "\(.path)=\(.reason)"] | join(" ")')" \
  '"~/../etc=dot-segment ~/Library/Caches/x=excluded-location ~/library/CACHES/x=excluded-location ~/.TRASH/x=excluded-location ~/library/cloudstorage/x=excluded-location ~/LIBRARY/Mobile Documents/x=excluded-location ~/DROPBOX (Personal)/x=excluded-location ~/Dropbox/a=excluded-location ~/nope=not-found /etc=not-home-relative ~=home-root ~/out=outside-home ~/cachelink=excluded-location ~/.Trash=excluded-location ~/Library/Mobile Documents/x=excluded-location \"~/a\\nb\"=control-character \"~/a\\u0000b\"=control-character ~/./Proton=dot-segment"'
check "merged with module paths; ~/code/p not given twice" "$(grep -cF -- "-- $H/.ssh $H/.config $H/code $H/Proton $H/test |" "$CALLS")" 1
check "status paths include the approved ones" "$(st .paths)" '["~/.ssh","~/.config","~/code","~/Proton","~/test"]'
check "fetched from the resolver's service, 10s cap" "$(called 'curl -fsS --connect-timeout 5 --max-time 10 http://cs/api/fleet/data/test-mac/backup-paths')" 1
check "last good list cached 0600" "$(ls -l "$H/.local/state/rh7-restic/approved-paths.json" | cut -c1-10)" "-rw-------"

echo "== approved paths: fetch failure falls back to the cached list =="
: >"$CALLS"; rb CONFIG_SERVICE_URL=http://cs -- run
check "approved_source cache" "$(st .approved_source)" '"cache"'
check "same approved paths from the cache" "$(st .approved_paths)" '["~/Proton","~/code/p","~/test"]'
check "still backed up" "$(grep -cF -- "$H/Proton $H/test |" "$CALLS")" 1
check "log says the cache was used" "$(grep -c 'using the last good list' <<<"$OUT")" 1
rmdir "$H/test"; rb CONFIG_SERVICE_URL=http://cs -- run
check "cached entry re-validated: vanished folder skipped" "$(st '[.approved_paths, [.skipped_paths[] | select(.path == "~/test") | .reason]]')" '[["~/Proton","~/code/p"],["not-found"]]'
rb "${CS[@]}" APPROVED_BODY='{"hostname":"other-mac","paths":["~/code"]}' -- run
check "a list for another host is refused (cache used)" "$(st .approved_source)" '"cache"'
rb "${CS[@]}" APPROVED_BODY='<html>oops</html>' -- run
check "a non-JSON answer is refused (cache used)" "$(st .approved_source)" '"cache"'
rb CURL_CODE=000 -- run
check "offline run carries the approved fields forward" "$(st '[.last_result,.approved_source,.approved_paths]')" '["skipped","cache",["~/Proton","~/code/p"]]'
rm -f "$H/.local/state/rh7-restic/approved-paths.json"; : >"$CALLS"
rb CONFIG_SERVICE_URL=http://cs -- run
check "no service, no cache: module paths only" "$(st '[.approved_source,.approved_paths,.skipped_paths]')" '["none",[],[]]'
check "restic got the module paths only" "$(grep -cF -- "-- $H/.ssh $H/.config $H/code |" "$CALLS")" 1
rb "${CS[@]}" APPROVED_BODY='{"hostname":"test-mac","paths":[]}' -- run
check "an emptied list stops the extra backups" "$(st '[.approved_source,.approved_paths]')" '["control-plane",[]]'
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$H/locked"; chmod 000 "$H/locked"
  rb "${CS[@]}" APPROVED_BODY='{"hostname":"test-mac","paths":["~/locked"]}' -- run
  check "unlistable folder refused up front (no failed run)" "$(st '[.last_result,.skipped_paths[0].reason]')" '["ok","permission-denied"]'
  chmod 755 "$H/locked"
fi
rb "${CS[@]}" APPROVED_BODY='{"paths":["~/code/p"]}' -- run
check "cache stamped with the identity it was fetched for" "$(jq -c '[.hostname,.paths]' "$H/.local/state/rh7-restic/approved-paths.json")" '["test-mac",["~/code/p"]]'
printf other-mac >"$CONF/server-user"; rb CONFIG_SERVICE_URL=http://cs -- run
check "re-setup under another name: the old host's cached approvals are not used" "$(st '[.approved_source,.approved_paths]')" '["none",[]]'
printf test-mac >"$CONF/server-user"
rm -rf "$T/outside"

echo "== audit-device.sh: rh7-restic entry in backup_posture =="
# The Python body has its own column-0 braces: cut at the heredoc terminator.
eval "$(sed -n '/^collect_backup_posture() {/,/^PYEOF$/p' "$AUDIT"; echo '}')"
declare -f collect_backup_posture >/dev/null || { echo "FATAL: could not extract collect_backup_posture" >&2; exit 1; }
reset; configure; rb -- run
mkdir -p "$H/Library/LaunchAgents"; : >"$H/Library/LaunchAgents/org.rh7.restic-backup.plist"   # the job exists
J="$(HOME="$H" collect_backup_posture)"
check "entry from the status file" "$(jq -c '[.programmatic[] | select(.source == "rh7-restic")] | length' <<<"$J")" 1
check "contract fields" "$(jq -c '.programmatic[] | select(.source == "rh7-restic") | [.tool,.present,.repo_configured,.paths,.last_result,(.latest_snapshot_time | test("Z$"))]' <<<"$J")" \
  '["restic",true,true,["~/.ssh","~/.config","~/code"],"ok",true]'
check "exactly one restic entry" "$(jq '[.programmatic[] | select(.tool == "restic")] | length' <<<"$J")" 1
rm -rf "$CONF"; rb -- run
J="$(HOME="$H" collect_backup_posture)"
check "not-configured -> repo_configured false" "$(jq -c '.programmatic[] | select(.source == "rh7-restic") | [.repo_configured,.last_result]' <<<"$J")" '[false,"not-configured"]'
echo '{not json' >"$STATUS"
J="$(HOME="$H" collect_backup_posture)"
check "corrupt status -> no rh7-restic entry" "$(jq '[(.programmatic // [])[] | select(.source == "rh7-restic")] | length' <<<"$J")" 0
rb -- run; rm -f "$H/Library/LaunchAgents/org.rh7.restic-backup.plist"
J="$(HOME="$H" PATH="/usr/bin:/bin" collect_backup_posture)"
check "status left by a removed job is ignored" "$(jq '[(.programmatic // [])[] | select(.source == "rh7-restic")] | length' <<<"$J")" 0

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
