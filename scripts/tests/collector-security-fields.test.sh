#!/usr/bin/env bash
# Coverage for audit-device.sh's account / FileVault / macOS-update / Time
# Machine fields (security.filevault_status, user_accounts, macos_update,
# backup_posture.time_machine).
#
# The collector runs on every Mac daily and its output is relayed to the
# control plane, so what matters is: the parsers read the real formats, an
# unreadable source reports unknown (never a guess), and nothing private leaks
# — no full name, no share host/IP/user, no file name inside a home folder.
# macOS tools are stubbed on PATH and every macOS path is rebased with
# AUDIT_MACOS_ROOT, so this runs on Linux CI too.
#
# Run: bash scripts/tests/collector-security-fields.test.sh   (needs python3)
# "~/…" is literal display text here, exactly as the collector reports it.
# shellcheck disable=SC2088
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../audit-device.sh"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/csf.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$OUT" "$1"; }

# The functions as one standalone script (python bodies cut at PYEOF).
{
  sed -n '/^parse_filevault_status() {/,/^}/p' "$AUDIT"
  for f in collect_time_machine collect_user_accounts collect_macos_update; do
    sed -n "/^$f() {/,/^PYEOF\$/p" "$AUDIT"; echo '}'
  done
} >"$T/fns.sh"
for f in parse_filevault_status collect_time_machine collect_user_accounts collect_macos_update; do
  grep -q "^$f() {" "$T/fns.sh" || { echo "FATAL: could not extract $f" >&2; exit 1; }
done
# shellcheck disable=SC1091
source "$T/fns.sh"
# shellcheck disable=SC2034 # read by the sourced collectors
OS=Darwin

BIN="$T/bin"; FX="$T/fx"; R="$T/root"; mkdir -p "$BIN" "$FX"
export FX
cat >"$BIN/tmutil" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  destinationinfo)
    if [ "${2:-}" = -X ]; then [ -f "$FX/dest.xml" ] && cat "$FX/dest.xml"; exit "${TM_X_RC:-0}"; fi
    cat "$FX/dest.txt" 2>/dev/null ;;
  isexcluded) cat "$FX/isexcluded" 2>/dev/null ;;
  latestbackup) cat "$FX/latest" 2>/dev/null ;;
esac
STUB
cat >"$BIN/dscl" <<'STUB'
#!/usr/bin/env bash
cat "$FX/dscl"
STUB
cat >"$BIN/dseditgroup" <<'STUB'
#!/usr/bin/env bash
# dseditgroup -o checkmember -m USER admin
grep -qx "$4" "$FX/admins" && echo "yes $4 is a member of admin" || { echo "no $4 is NOT a member of admin"; exit 1; }
STUB
cat >"$BIN/scutil" <<'STUB'
#!/usr/bin/env bash
echo Fixture
STUB
cat >"$BIN/sw_vers" <<'STUB'
#!/usr/bin/env bash
case "$1" in -productVersion) echo 26.5.2 ;; -buildVersion) echo 25F84 ;; esac
STUB
# defaults export DOMAIN - : cfprefsd's view — "<DOMAIN>.plist.cfprefs" when
# present (the file itself may be unreadable, as TCC makes it), else the file.
cat >"$BIN/defaults" <<'STUB'
#!/usr/bin/env bash
[ "$1" = export ] || exit 1
if [ -f "$2.plist.cfprefs" ]; then cat "$2.plist.cfprefs"; else cat "$2.plist" 2>/dev/null; fi
STUB
chmod +x "$BIN"/*
P="$BIN:$PATH"

echo "== FileVault: fdesetup status -> on|off|encrypting|decrypting|unknown =="
fv() { printf '%b' "$1" | parse_filevault_status; }
check "on" "$(fv 'FileVault is On.\n')" on
check "off" "$(fv 'FileVault is Off.\n')" off
check "decrypting" "$(fv 'FileVault is Off.\nDecryption in progress: Percent completed = 80.1\n')" decrypting
check "deferred enablement is still off" "$(fv 'FileVault is Off, but will be enabled after the next restart.\n')" off
check "no output (timeout) -> unknown" "$(fv '')" unknown
check "unrecognised -> unknown" "$(fv 'Error: something\n')" unknown

# ── Time Machine ────────────────────────────────────────────────────────────
plist() { python3 -c 'import json,plistlib,sys,datetime
def conv(o):
    if isinstance(o, dict): return {k: conv(v) for k, v in o.items()}
    if isinstance(o, list): return [conv(v) for v in o]
    if isinstance(o, str) and o.startswith("@date:"): return datetime.datetime.strptime(o[6:], "%Y-%m-%dT%H:%M:%S")
    return o
sys.stdout.buffer.write(plistlib.dumps(conv(json.loads(sys.argv[1]))))' "$1"; }
# shellcheck disable=SC2163 # "$@" holds VAR=value words to export
tm() { OUT="$( [ $# -gt 0 ] && export "$@"; PATH="$P" HOME=/Users/tester AUDIT_MACOS_ROOT="$R" collect_time_machine)"; }
TMP_PLIST="$R/Library/Preferences/com.apple.TimeMachine.plist"
mkdir -p "$(dirname "$TMP_PLIST")"

echo "== Time Machine: two destinations, encryption, exclusions (plist form) =="
plist '{"Destinations":[
  {"ID":"AAAA","Kind":"Network","Name":"timemachineRH","URL":"smb://alice@192.168.1.5/TM%20Share/sub","MountPoint":"/Volumes/.timemachine/x","LastDestination":1},
  {"ID":"BBBB","Kind":"Local","Name":"Ext SSD","MountPoint":"/Volumes/Ext SSD","LastDestination":0}]}' >"$FX/dest.xml"
plist '{"AutoBackup":true,"SkipSystemFiles":true,
  "Destinations":[{"DestinationID":"AAAA","LastKnownEncryptionState":"Encrypted"},{"DestinationID":"BBBB","LastKnownEncryptionState":"NotEncrypted"}],
  "SkipPaths":["/Users/tester/Downloads/secret-file.mov","~/Library/Application Support/Foo/Bar/baz.db","/Applications",
               "/Volumes/Ext/stuff/x","/Users/bob/Movies/clip.mp4","/opt/homebrew/Library/Taps/x","~/Projects",
               "/Users/tester/../tester/Pictures/a.jpg","bad\npath"]}' >"$TMP_PLIST"
echo '/Volumes/.timemachine/x/2026-11-15-031719.backup/2026-11-15-031719.backup' >"$FX/latest"
tm
check "configured" "$(q "d['configured']")" True
check "destinations: name, kind, share name only, encryption" "$(q "d['destinations']")" \
  "[{'name': 'timemachineRH', 'kind': 'Network', 'share_name': 'TM Share', 'encrypted': True}, {'name': 'Ext SSD', 'kind': 'Local', 'encrypted': False}]"
check "no host, IP, user or sub-path from the URL" "$(printf '%s' "$OUT" | grep -cE 'alice|192\.168|smb:|sub')" 0
check "auto_backup" "$(q "d['auto_backup']")" True
check "skip paths privacy-reduced" "$(q "d['exclusions']['skip_paths']")" \
  "['~/Downloads/…', '~/Library/Application Support/Foo/…', '/Applications', '/Volumes/Ext/…', '/Users/bob/Movies/…', '/opt/homebrew/Library/…', '~/Projects', '~/Pictures/…']"
check "no file name from a home folder" "$(printf '%s' "$OUT" | grep -cE 'secret-file|baz\.db|clip\.mp4|a\.jpg')" 0
check "skip_paths_count counts every string entry" "$(q "d['exclusions']['skip_paths_count']")" 9
check "skip_system_files / readable" "$(q "(d['exclusions']['skip_system_files'], d['exclusions']['readable'])")" "(True, True)"
check "/Applications in SkipPaths -> excluded" "$(q "d['exclusions']['applications_excluded']")" True
check "latest backup + age" "$(q "(d['latest_backup'].endswith('.backup'), isinstance(d['latest_backup_age_hours'], float))")" "(True, True)"

echo "== Time Machine: /Applications excluded or not per tmutil isexcluded =="
plist '{"SkipPaths":["~/Downloads"]}' >"$TMP_PLIST"
echo '[Included]    /Applications' >"$FX/isexcluded"; tm
check "included" "$(q "d['exclusions']['applications_excluded']")" False
check "encryption unknown when prefs carry no destinations" "$(q "[x['encrypted'] for x in d['destinations']]")" "[None, None]"
echo '[Excluded]    /Applications' >"$FX/isexcluded"; tm
check "excluded (sticky / fixed)" "$(q "d['exclusions']['applications_excluded']")" True
: >"$FX/isexcluded"; tm
check "no answer -> null" "$(q "d['exclusions']['applications_excluded']")" None

echo "== Time Machine: prefs file TCC-denied, cfprefsd still answers =="
cp "$TMP_PLIST" "$TMP_PLIST.cfprefs"; chmod 000 "$TMP_PLIST"; tm
check "exclusions readable via defaults export" "$(q "(d['exclusions']['readable'], d['exclusions']['skip_paths'])")" "(True, ['~/Downloads'])"
chmod 644 "$TMP_PLIST"; rm -f "$TMP_PLIST.cfprefs"

echo "== Time Machine: no destinations =="
plist '{}' >"$FX/dest.xml"; rm -f "$FX/latest"; tm
check "not configured, nothing listed" "$(q "(d['configured'], d['destinations'], d['exclusions']['applications_excluded'])")" "(False, [], None)"
check "no latest backup key" "$(q "'latest_backup' in d")" False

echo "== Time Machine: -X unusable -> text form; prefs unreadable -> unknown =="
rm -f "$FX/dest.xml" "$TMP_PLIST"
cat >"$FX/dest.txt" <<'TXT'
====================================================
Name          : NAS
Kind          : Network
URL           : afp://bob@nas.local./Backups
ID            : CCCC
TXT
tm TM_X_RC=1
check "text fallback parsed" "$(q "d['destinations']")" "[{'name': 'NAS', 'kind': 'Network', 'share_name': 'Backups', 'encrypted': None}]"
check "prefs unreadable: readable false, nulls" "$(q "(d['exclusions']['readable'], d['exclusions']['skip_paths'], d['auto_backup'], d['exclusions']['skip_system_files'])")" "(False, [], None, None)"

# ── Accounts ────────────────────────────────────────────────────────────────
ME="$(id -un)"
printf '%s\n' "_mbsetupuser 248" "root 0" "nobody -2" "_hidden 600" "alice 501" "kassie 502" "$ME 503" "bad;name 504" >"$FX/dscl"
printf '%s\n' alice "$ME" >"$FX/admins"
ua() { OUT="$(PATH="$P" AUDIT_MACOS_ROOT="$R" collect_user_accounts)"; }
user() { q "next(({k: v for k, v in u.items() if k != 'uid'} for u in d['users'] if u['username'] == '$1'), 'absent')"; }

echo "== Accounts: admin, nix primary user, Homebrew owner =="
mkdir -p "$R/run/current-system" "$R/opt/homebrew"
printf '%s\n' '#!/bin/sh' 'set -e' 'primaryUser=kassie' 'if ! id -- "$primaryUser"; then exit 1; fi' >"$R/run/current-system/activate"
ua
check "human accounts only" "$(q "[u['username'] for u in d['users']]")" "['alice', 'kassie', '$ME']"
check "alice: admin, not primary, not brew owner" "$(user alice)" "{'username': 'alice', 'admin': True, 'nix_primary_user': False, 'homebrew_owner': False}"
check "kassie: standard, nix primary user" "$(user kassie)" "{'username': 'kassie', 'admin': False, 'nix_primary_user': True, 'homebrew_owner': False}"
check "prefix owner flagged" "$(user "$ME")" "{'username': '$ME', 'admin': True, 'nix_primary_user': False, 'homebrew_owner': True}"
check "top level" "$(q "(d['nix_primary_user'], d['homebrew_prefix'], d['homebrew_prefix_owner'] == '$ME')")" "('kassie', '/opt/homebrew', True)"
check "no full names" "$(q "any('realname' in u for u in d['users'])")" False

echo "== Accounts: nothing derivable -> null top level, flags omitted =="
rm -rf "${R:?}/run" "${R:?}/opt"; ua
check "top level nulls" "$(q "(d['nix_primary_user'], d['homebrew_prefix'], d['homebrew_prefix_owner'])")" "(None, None, None)"
check "flags omitted, admin kept" "$(user kassie)" "{'username': 'kassie', 'admin': False}"
mkdir -p "$R/usr/local/Homebrew"; ua
check "Intel prefix" "$(q "(d['homebrew_prefix'], d['homebrew_prefix_owner'] == '$ME')")" "('/usr/local/Homebrew', True)"
rm -rf "${R:?}/usr"

echo "== Accounts: non-Darwin is empty =="
check "Linux" "$(OS=Linux collect_user_accounts)" "{}"

# ── macOS update context ────────────────────────────────────────────────────
mu() { OUT="$(PATH="$P" AUDIT_MACOS_ROOT="$R" collect_macos_update)"; }
mkdir -p "$R/Library/Receipts" "$R/Library/Preferences" "$R/Library/Managed Preferences"

echo "== macOS update: install history, policy, pending =="
plist '[
  {"displayName":"macOS Sequoia 15.6","displayVersion":"15.6","date":"@date:2025-08-01T10:00:00","processName":"softwareupdated"},
  {"displayName":"XProtectPlistConfigData","displayVersion":"5342","date":"@date:2025-09-01T10:00:00","contentType":"config-data","processName":"softwareupdated"},
  {"displayName":"macOS Tahoe 26","displayVersion":"26.0","date":"@date:2025-09-20T08:30:00","processName":"macOS Installer"},
  {"displayName":"Node.js","displayVersion":"","date":"@date:2025-10-01T10:00:00","processName":"Installer"},
  {"displayName":"macOS 26.3.1 (a)","displayVersion":"26.3.1 (a)","date":"@date:2026-03-18T21:00:00","processName":"softwareupdated"},
  {"displayName":"macOS 26.5.2","displayVersion":"26.5.2","date":"@date:2026-07-23T06:30:30","processName":"softwareupdated"}]' \
  >"$R/Library/Receipts/InstallHistory.plist"
plist '{"AutomaticCheckEnabled":true,"AutomaticDownload":1,"AutomaticallyInstallMacOSUpdates":0,"CriticalUpdateInstall":true,
  "LastFullSuccessfulDate":"@date:2026-11-14T15:09:28",
  "RecommendedUpdates":[{"Display Name":"macOS Tahoe 26.7.3","Display Version":"26.7.3"},
                        {"Display Name":"macOS 27.2.1","Display Version":"27.2.1"},
                        {"Display Name":"Safari","Display Version":"27.2"},
                        {"Display Name":"macOS 27.2.1","Display Version":"27.2.1"}]}' >"$R/Library/Preferences/com.apple.SoftwareUpdate.plist"
plist '{"AutomaticallyInstallMacOSUpdates":true}' >"$R/Library/Managed Preferences/com.apple.SoftwareUpdate.plist"
plist '{"AutoUpdate":true}' >"$R/Library/Preferences/com.apple.commerce.plist"
mu
check "current version + build" "$(q "(d['current_version'], d['current_build'])")" "('26.5.2', '25F84')"
check "macOS installs only, newest first" "$(q "[(i['version'], i['date']) for i in d['installs']]")" \
  "[('26.5.2', '2026-07-23T06:30:30Z'), ('26.3.1 (a)', '2026-03-18T21:00:00Z'), ('26.0', '2025-09-20T08:30:00Z'), ('15.6', '2025-08-01T10:00:00Z')]"
check "previous version" "$(q "d['previous_version']")" "26.3.1 (a)"
check "last major install" "$(q "d['last_major_install']")" "{'version': '26.0', 'from_version': '15.6', 'date': '2025-09-20T08:30:00Z'}"
check "policy (managed key wins)" "$(q "d['policy']")" \
  "{'readable': True, 'managed_keys': ['automatically_install_macos_updates'], 'automatic_check': True, 'automatic_download': True, 'automatically_install_macos_updates': True, 'critical_update_install': True, 'config_data_install': None, 'app_store_auto_update': True}"
check "pending macOS updates, major flagged, deduped" "$(q "d['pending_macos_updates']")" \
  "[{'version': '26.7.3', 'major_upgrade': False}, {'version': '27.2.1', 'major_upgrade': True}]"
check "last check" "$(q "d['last_check_at']")" "2026-11-14T15:09:28Z"

echo "== macOS update: 10.x majors are two components =="
plist '[{"displayName":"macOS Catalina","displayVersion":"10.15.7","date":"@date:2021-01-01T00:00:00"},
        {"displayName":"macOS Big Sur","displayVersion":"11.0.1","date":"@date:2021-02-01T00:00:00"},
        {"displayName":"macOS Big Sur 11.1","displayVersion":"11.1","date":"@date:2021-03-01T00:00:00"}]' >"$R/Library/Receipts/InstallHistory.plist"
mu
check "10.15 -> 11 is the major" "$(q "(d['last_major_install']['version'], d['last_major_install']['from_version'])")" "('11.0.1', '10.15.7')"

echo "== macOS update: a TCC-denied preferences file is read through cfprefsd =="
SU="$R/Library/Preferences/com.apple.SoftwareUpdate.plist"
cp "$SU" "$SU.cfprefs"; chmod 000 "$SU"
if [ -r "$SU" ]; then echo "  skip (running as root: chmod 000 does not deny)"; else
  mu
  check "policy still readable" "$(q "(d['policy']['readable'], d['policy']['automatic_download'])")" "(True, True)"
fi
chmod 644 "$SU"; rm -f "$SU.cfprefs"

echo "== macOS update: unreadable sources -> unknown, not guessed =="
rm -rf "${R:?}/Library"; mu
check "installs unreadable" "$(q "(d['installs_readable'], d['installs'], d['previous_version'], d['last_major_install'])")" "(False, [], None, None)"
check "policy unreadable, all null" "$(q "(d['policy']['readable'], d['policy']['automatically_install_macos_updates'], d['policy']['app_store_auto_update'])")" "(False, None, None)"
check "nothing pending, no last check" "$(q "(d['pending_macos_updates'], d['last_check_at'])")" "([], None)"
check "Linux" "$(OS=Linux collect_macos_update)" "{}"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
