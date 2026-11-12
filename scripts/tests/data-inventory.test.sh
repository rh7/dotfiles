#!/usr/bin/env bash
# Coverage for audit-device.sh's data_inventory section and the SHARED DATA
# CLASSIFICATION block it shares with pre-wipe-check.sh.
#
# The failures that matter here are silent: a classifier that calls local-only
# data "reinstallable", a coverage check that credits a stale backup, a
# protected folder opened without Full Disk Access (a macOS prompt in a
# headless job), or a collector that blows the audit's time budget. So:
#   - the block is byte-identical in both scripts (drift = one script misjudges);
#   - classification fixtures (~/.dropbox, ~/.ollama, Signal, WhatsApp, clouds);
#   - the collector runs against a fixture HOME with du/tmutil stubbed: FDA
#     denied vs granted, coverage (iCloud D&D, restic fresh/stale, Time
#     Machine, git), Photos unknown vs iCloud Photos on, budget + per-item du
#     timeouts, the weekly size cache, largest files and the contract shape.
#
# Run: bash scripts/tests/data-inventory.test.sh   (needs python3)
# "~/…" is literal display text here, exactly as the collector reports it.
# shellcheck disable=SC2088
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../audit-device.sh"
PWC="$HERE/../pre-wipe-check.sh"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/dinv.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }

block() { sed -n '/^# >>> BEGIN SHARED DATA CLASSIFICATION >>>/,/^# <<< END SHARED DATA CLASSIFICATION <<</p' "$1"; }

echo "== the shared block is identical in both scripts =="
block "$AUDIT" >"$T/a.blk"; block "$PWC" >"$T/p.blk"
check "extracted from audit-device.sh" "$(grep -c '^data_class_rule()' "$T/a.blk")" 1
check "extracted from pre-wipe-check.sh" "$(grep -c '^data_class_rule()' "$T/p.blk")" 1
check "byte-identical" "$(cmp -s "$T/a.blk" "$T/p.blk" && echo same || echo DRIFT)" same

# shellcheck disable=SC1090
source "$T/a.blk"
# The collector as a standalone script: the shared block + the function (its
# Python body has column-0 braces, so cut at the heredoc terminator).
{ cat "$T/a.blk"; sed -n '/^collect_data_inventory() {/,/^PYEOF$/p' "$AUDIT"; echo '}'; echo collect_data_inventory; } >"$T/collector.sh"
grep -q '^collect_data_inventory() {' "$T/collector.sh" || { echo "FATAL: could not extract collect_data_inventory" >&2; exit 1; }

echo "== classification fixtures =="
cls() { local r; r="$(data_class_rule "$1" "$2")" || { echo none; return; }; printf '%s\n' "$r" | cut -d'|' -f2,3; }
check "~/.dropbox is Dropbox internal state: reinstallable, not unprotected" "$(cls home .dropbox)" "app-data|reinstallable"
check "~/.ollama model weights: reinstallable tooling" "$(cls home .ollama)" "tooling|reinstallable"
check "~/.rustup / ~/.cargo / ~/.npm" "$(cls home .rustup) $(cls home .cargo) $(cls home .npm)" "tooling|reinstallable tooling|reinstallable cache|reinstallable"
check "~/.vscode / ~/.cursor" "$(cls home .vscode) $(cls home .cursor)" "tooling|reinstallable tooling|reinstallable"
check "~/.cache" "$(cls home .cache)" "cache|reinstallable"
check "~/Dropbox root is a cloud root" "$(cls home Dropbox)" "dropbox|cloud"
check "~/Dropbox (Personal) too" "$(cls home 'Dropbox (Personal)')" "dropbox|cloud"
check "~/DropboxOld is NOT a cloud root" "$(cls home DropboxOld)" none
check "iCloud Drive (Archive) is local data" "$(cls home 'iCloud Drive (Archive) 2')" "user-data|unprotected"
check "Downloads" "$(cls home Downloads)" "downloads|unprotected"
check "Signal Desktop history: unprotected app-data" "$(cls appdata Signal)" "app-data|unprotected"
check "WhatsApp: reinstallable (history on the phone)" "$(cls appdata net.whatsapp.WhatsApp)" "app-data|reinstallable"
check "unlisted folder: no rule (defaults apply)" "$(cls home Proton)" none
# pre-wipe-check judges through the same rows.
# shellcheck source=../pre-wipe-check.sh
PRE_WIPE_CHECK_SOURCE_ONLY=1 source "$PWC"
check "pre-wipe-check: ~/.dropbox no longer RED-able (kind cache)" "$(home_entry_kind .dropbox)" cache
check "pre-wipe-check: ~/.dropbox level" "$(r="$(home_entry_level cache 999999 0 0 .dropbox)"; printf '%s' "${r%%$'\t'*}")" NONE

# ── fixture HOME + stubs ────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"; DU_LOG="$T/du.log"
# du: "<path>/.kb" holds the size in KB (default 4); "<path>/.slow" sleeps.
cat >"$BIN/du" <<'STUB'
#!/usr/bin/env bash
p="${@: -1}"
echo "$p" >>"$DU_LOG"
[ -f "$p/.slow" ] && exec sleep "$(cat "$p/.slow")"
kb=4; [ -f "$p/.kb" ] && kb="$(cat "$p/.kb")"
printf '%s\t%s\n' "$kb" "$p"
STUB
cat >"$BIN/tmutil" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  destinationinfo) printf 'Name          : TM\nKind          : Local\n' ;;
  latestbackup) echo "/Volumes/TM/Backups.backupdb/mac/$TM_AT" ;;
  isexcluded) shift; for p in "$@"; do case "$p" in */Proton) echo "[Included]    $p" ;; *) echo "[Excluded]    $p" ;; esac; done ;;
esac
STUB
chmod +x "$BIN/du" "$BIN/tmutil"
export DU_LOG
PYDIR="$(dirname "$(command -v python3)")"

H="$T/home"; AS="$H/Library/Application Support"
mkfix() {
  chmod -R u+rwx "$H" 2>/dev/null; rm -rf "$H" "$DU_LOG"; : >"$DU_LOG"
  mkdir -p "$H/.dropbox" "$H/.ollama" "$H/Proton" "$H/test" "$H/Downloads" "$H/Desktop" "$H/Documents" \
    "$H/Pictures" "$H/code/clean" "$H/code/dirty" "$H/Library/Caches" "$H/Library/Messages" "$H/Library/Containers/com.apple.Photos" \
    "$H/Library/Containers/net.whatsapp.WhatsApp" "$H/Library/Group Containers" "$H/Library/Preferences" "$H/Library/LaunchAgents" \
    "$AS/com.apple.TCC" "$AS/Signal" "$AS/Exodus" "$AS/BigApp" "$AS/SmallApp" \
    "$AS/Google/Chrome/Default/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn" "$H/.local/state/rh7-restic" "$H/Dropbox"
  echo 2048 >"$H/.dropbox/.kb"; echo 37000000 >"$H/.ollama/.kb"; echo 5000 >"$H/Proton/.kb"; echo 3000 >"$H/test/.kb"
  echo 204800 >"$AS/BigApp/.kb"; echo 10240 >"$AS/SmallApp/.kb"; echo 307200 >"$H/Library/Containers/net.whatsapp.WhatsApp/.kb"
  echo 900000 >"$H/Downloads/.kb"; echo 5000 >"$H/code/.kb"
  : >"$AS/com.apple.TCC/TCC.db"; chmod 000 "$AS/com.apple.TCC/TCC.db"   # FDA denied
  : >"$H/Library/LaunchAgents/org.rh7.restic-backup.plist"; : >"$H/Library/Preferences/com.apple.Photos.plist"
  restic_status "$(at 120 utc)"
  python3 - "$H" <<'PY'
import plistlib, sys
H = sys.argv[1]
plistlib.dump({'FXICloudDriveDesktop': 1}, open(H + '/Library/Preferences/com.apple.finder.plist', 'wb'))
with open(H + '/Proton/big.bin', 'wb') as f: f.truncate(600 * 1024 * 1024)        # sparse
with open(H + '/Library/Caches/huge.bin', 'wb') as f: f.truncate(900 * 1024 * 1024)
with open(H + '/Downloads/movie.mov', 'wb') as f: f.truncate(700 * 1024 * 1024)
PY
}
# at SECONDS utc|local — a timestamp SECONDS from now (backups "just after"
# the fixture was created, so the fixture predates them).
at() { python3 -c 'import sys,time; t=time.time()+int(sys.argv[1]); print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if sys.argv[2]=="utc" else time.strftime("%Y-%m-%d-%H%M%S", time.localtime(t)))' "$1" "$2"; }
restic_status() { printf '{"schema":1,"configured":true,"last_snapshot_time":"%s","paths":["~/Proton","~/.ssh"]}\n' "$1" >"$H/.local/state/rh7-restic/status.json"; }
grant_fda() { chmod 644 "$AS/com.apple.TCC/TCC.db"; }
GIT_REPOS_JSON='{"repos":[{"path":"~/code/clean","at_risk":false,"dirty":0,"has_remote":true,"unpushed":0},{"path":"~/code/dirty","at_risk":true,"dirty":3,"has_remote":true,"unpushed":1}]}'

inv() { # inv [VAR=val …] — runs the collector into $OUT
  OUT="$(env -i PATH="$BIN:$PYDIR:/usr/bin:/bin" HOME="$H" DU_LOG="$DU_LOG" GIT_REPOS_JSON="$GIT_REPOS_JSON" TM_AT="${TM_AT:-$(at 120 local)}" \
    AUDIT_DATA_PLATFORM=Darwin "$@" bash "$T/collector.sh")"
}
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$OUT" "$1"; }
item() { q "next(((i['status'], i['category'], i['size_bytes'], sorted(i['coverage'])) for i in d['items'] if i['path'] == '$1'), 'absent')"; }
note() { q "next((i['note'] or '' for i in d['items'] if i['path'] == '$1'), 'absent')"; }

echo "== FDA denied: protected folders untouched, reported not-inspected =="
mkfix; inv
check "valid JSON, schema 1" "$(q "d['schema']")" 1
check "protected_access denied" "$(q "d['protected_access']")" denied
check "account" "$(q "d['account']")" "$(id -un)"
check "Downloads not-inspected, size null" "$(item '~/Downloads')" "('not-inspected', 'downloads', None, [])"
check "Desktop iCloud-synced (Finder pref): covered, not opened" "$(item '~/Desktop')" "('covered', 'user-data', None, ['icloud'])"
check "Documents not synced -> not-inspected" "$(item '~/Documents')" "('not-inspected', 'user-data', None, [])"
check "Messages not-inspected" "$(item '~/Library/Messages')" "('not-inspected', 'messages', None, [])"
check "Containers: one aggregate not-inspected item" "$(item '~/Library/Containers')" "('not-inspected', 'app-data', None, [])"
check "Photos unknown -> unprotected (owner rule), size null" "$(item '~/Pictures/Photos Library.photoslibrary')" "('unprotected', 'photos', None, [])"
check "Photos note says iCloud Photos not confirmed" "$(note '~/Pictures/Photos Library.photoslibrary' | grep -c 'iCloud Photos not confirmed')" 1
check "no protected folder was du'ed" "$(grep -cE "/(Downloads|Desktop|Documents|Pictures|Library/Messages|Library/Containers)" "$DU_LOG")" 0
check "~/.dropbox reinstallable" "$(item '~/.dropbox')" "('reinstallable', 'app-data', 2097152, [])"
check "~/.ollama reinstallable tooling" "$(item '~/.ollama')" "('reinstallable', 'tooling', 37888000000, [])"
check "~/Proton: restic (fresh) + Time Machine" "$(item '~/Proton')" "('covered', 'user-data', 5120000, ['restic', 'time-machine'])"
check "~/test: TM-excluded, unprotected" "$(item '~/test')" "('unprotected', 'user-data', 3072000, [])"
check "cloud root ~/Dropbox is not an item" "$(item '~/Dropbox')" absent
check "Signal app data: unprotected even when small" "$(item '~/Library/Application Support/Signal')" "('unprotected', 'app-data', 4096, [])"
check "app data >= 100 MB listed" "$(item '~/Library/Application Support/BigApp')" "('unprotected', 'app-data', 209715200, [])"
check "app data < 100 MB omitted" "$(item '~/Library/Application Support/SmallApp')" absent
check "Exodus wallet (size only)" "$(item '~/Library/Application Support/Exodus')" "('unprotected', 'wallet', 4096, [])"
check "MetaMask extension wallet" "$(q "[i['category'] for i in d['items'] if i['path'].endswith('nkbihfbeogaeaoehlefnkodbefgpgknn')]")" "['wallet']"
check "at-risk repo is an item" "$(q "next(i['category'] + '/' + i['note'] for i in d['items'] if i['path'] == '~/code/dirty')")" "repo/git: 3 uncommitted change(s), 1 unpushed commit(s)"
check "clean pushed repo is not an item" "$(item '~/code/clean')" absent
check "~/code says what it holds" "$(note '~/code')" "holds 2 git repo(s), 1 at risk"
check "largest: sparse 600 MB file found, caches and protected folders skipped" "$(q "[f['path'] for f in d['largest_files']]")" "['~/Proton/big.bin']"
check "largest: size + mtime" "$(q "(d['largest_files'][0]['size_bytes'], len(d['largest_files'][0]['mtime']))")" "(629145600, 20)"
check "budget not exhausted" "$(q "d['budget_exhausted']")" False
CONTRACT="$(q "all(set(i) == {'path','category','size_bytes','files','newest_mtime','coverage','status','note'}
  and i['category'] in {'user-data','downloads','photos','messages','mail','app-data','wallet','repo','tooling','cache'}
  and i['status'] in {'covered','unprotected','not-inspected','reinstallable'}
  and set(i['coverage']) <= {'icloud','dropbox','cloud-storage','git-remote','restic','time-machine'}
  and i['path'].startswith('~/') for i in d['items']) and {'schema','collected_at','account','protected_access','budget_exhausted','items','largest_files'} <= set(d)")"
check "every item conforms to the contract" "$CONTRACT" True
check "cache written 0600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$H/.local/state/rh7-audit/data-inventory-cache.json")" 0o600

echo "== weekly cache: a warm run does not re-measure; a changed folder does =="
: >"$DU_LOG"; inv
check "warm run: du not called" "$(grep -c . "$DU_LOG")" 0
check "warm run: sizes from cache" "$(item '~/Proton')" "('covered', 'user-data', 5120000, ['restic', 'time-machine'])"
touch -t 202001010000 "$H/Proton"; : >"$DU_LOG"; inv
check "mtime changed: only that folder re-measured" "$(grep -c . "$DU_LOG")/$(grep -c '/Proton$' "$DU_LOG")" "1/1"

echo "== coverage: stale restic snapshot is not coverage =="
restic_status "2020-01-01T00:00:00Z"; inv
check "~/Proton only Time Machine" "$(item '~/Proton')" "('covered', 'user-data', 5120000, ['time-machine'])"
rm -f "$H/Library/LaunchAgents/org.rh7.restic-backup.plist"; restic_status "$(at 120 utc)"; inv
check "status file left behind by a removed job is ignored" "$(item '~/Proton')" "('covered', 'user-data', 5120000, ['time-machine'])"

echo "== coverage: a folder created after the latest backup is in neither backup =="
mkfix; restic_status "$(at -3600 utc)"; TM_AT="$(at -3600 local)" inv
check "~/Proton (created now, backups 1h old): not covered" "$(item '~/Proton')" "('unprotected', 'user-data', 5120000, [])"

echo "== FDA granted: protected folders measured =="
mkfix; grant_fda
mkdir -p "$H/Pictures/Photos Library.photoslibrary"; echo 1048576 >"$H/Pictures/Photos Library.photoslibrary/.kb"; echo 1049600 >"$H/Pictures/.kb"
inv
check "protected_access granted" "$(q "d['protected_access']")" granted
check "Downloads measured, unprotected" "$(item '~/Downloads')" "('unprotected', 'downloads', 921600000, [])"
check "Photos library measured, unprotected (iCloud Photos unknown)" "$(item '~/Pictures/Photos Library.photoslibrary')" "('unprotected', 'photos', 1073741824, [])"
check "~/Pictures excludes the library" "$(item '~/Pictures')" "('unprotected', 'user-data', 1048576, [])"
check "WhatsApp container listed per app: reinstallable" "$(item '~/Library/Containers/net.whatsapp.WhatsApp')" "('reinstallable', 'app-data', 314572800, [])"
check "largest now includes Downloads" "$(q "sorted(f['path'] for f in d['largest_files'])")" "['~/Downloads/movie.mov', '~/Proton/big.bin']"

echo "== iCloud Photos on -> Photos covered =="
python3 - "$H" <<'PY'
import plistlib, sys
plistlib.dump({'Accounts': [{'Services': [{'Name': 'PHOTO_STREAM', 'Enabled': True}]}]},
              open(sys.argv[1] + '/Library/Preferences/MobileMeAccounts.plist', 'wb'))
PY
inv
check "Photos covered by iCloud" "$(item '~/Pictures/Photos Library.photoslibrary')" "('covered', 'photos', 1073741824, ['icloud'])"

echo "== budget: per-item du timeout and the total cap =="
mkfix; echo 3 >"$H/Proton/.slow"
START=$SECONDS; inv AUDIT_DATA_DU_TIMEOUT=1
check "slow du is cut at its cap (run < 3s for that item)" "$([ $((SECONDS - START)) -lt 8 ] && echo fast || echo slow)" fast
check "timed-out item: size null + note" "$(item '~/Proton')/$(note '~/Proton' | grep -c 'du exceeded')" "('covered', 'user-data', None, ['restic', 'time-machine'])/1"
check "budget_exhausted set" "$(q "d['budget_exhausted']")" True
: >"$DU_LOG"; inv AUDIT_DATA_DU_TIMEOUT=1
check "timed-out folder not retried the next day" "$(grep -c '/Proton$' "$DU_LOG")" 0
mkfix; START=$SECONDS; inv AUDIT_DATA_BUDGET=0
check "zero budget: nothing sized" "$(grep -c . "$DU_LOG")" 0
check "zero budget: budget_exhausted, sizes null with a note" "$(q "d['budget_exhausted']")/$(item '~/test')/$(note '~/test' | grep -c 'time budget')" "True/('unprotected', 'user-data', None, [])/1"
check "zero budget still answers fast" "$([ $((SECONDS - START)) -lt 10 ] && echo fast || echo slow)" fast

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
