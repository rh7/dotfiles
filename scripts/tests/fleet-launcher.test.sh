#!/usr/bin/env bash
# Coverage for modules/darwin/fleet-launcher.c — the ONE binary an optional
# Full Disk Access grant attaches to (both the audit and the restic job run
# through it). A grant makes it a privilege boundary, so what matters is what
# it refuses to take from whoever starts it: the target (fixed per job name),
# extra argv, and the caller's environment (PATH, HOME, BASH_ENV, exported
# bash functions, CONFIG_SERVICE_URL, DYLD_*). Relayed exit codes keep
# launchd's view of the job honest.
#
# Compiles the launcher with PROFILE_BIN pointed at stub jobs; skips (exit 0)
# when no C compiler is installed. (DYLD_INSERT_LIBRARIES itself is refused by
# dyld for the hardened-runtime signature the module applies; the test binary
# is unsigned, so a harmless DYLD_* variable stands in to prove the scrub.)
#
# Run: bash scripts/tests/fleet-launcher.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../modules/darwin/fleet-launcher.c"
CC="${CC:-$(command -v cc || command -v gcc || command -v clang || true)}"
[ -n "$CC" ] || { echo "SKIP: no C compiler"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/flaunch.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
"$CC" -O2 -Wall -Werror -DPROFILE_BIN="\"$T/bin\"" -o "$T/launcher" "$SRC" || { echo "FATAL: compile failed"; exit 1; }

# Each stub job records its argv and environment, then exits with $T/rc.
for job in rh7-fleet-audit rh7-restic-backup; do
  cat >"$T/bin/$job" <<STUB
#!/bin/sh
printf '%s\n' "\$0" "\$@" >"$T/$job.argv"
env >"$T/$job.env"
exit \$(cat "$T/rc" 2>/dev/null || echo 0)
STUB
  chmod +x "$T/bin/$job"
done

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }
L() { env -i PATH=/evil HOME=/tmp/evilhome USER=mallory BASH_ENV=/tmp/evil.sh 'BASH_FUNC_curl%%=() { :; }' \
  CONFIG_SERVICE_URL=http://evil DYLD_FALLBACK_LIBRARY_PATH=/tmp/evil LANG=en_US.UTF-8 "$T/launcher" "$@"; }

echo "== job table: name -> fixed target + argv =="
L restic; check "restic exit 0" "$?" 0
check "restic runs the system wrapper with 'run' only" "$(tr '\n' ' ' <"$T/rh7-restic-backup.argv")" "$T/bin/rh7-restic-backup run "
L audit; check "audit exit 0" "$?" 0
check "audit runs the system wrapper, no arguments" "$(tr '\n' ' ' <"$T/rh7-fleet-audit.argv")" "$T/bin/rh7-fleet-audit "

echo "== refuses anything else =="
L; check "no job -> usage (2)" "$?" 2
L restic setup; check "extra argv refused (2)" "$?" 2
L /bin/sh; check "a path is not a job (2)" "$?" 2
L "audit;id"; check "no shell parsing (2)" "$?" 2

echo "== environment is rebuilt, not inherited =="
E="$T/rh7-fleet-audit.env"
check "HOME from the password database" "$(sed -n 's/^HOME=//p' "$E")" "$(cd ~ && pwd -P 2>/dev/null || echo ~)"
check "USER from the password database" "$(sed -n 's/^USER=//p' "$E")" "$(id -un)"
check "SHELL from the password database" "$(sed -n 's/^SHELL=//p' "$E")" "$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_shell)')"
check "fixed PATH" "$(sed -n 's/^PATH=//p' "$E")" "/usr/bin:/bin:/usr/sbin:/sbin"
check "locale passed through" "$(sed -n 's/^LANG=//p' "$E")" "en_US.UTF-8"
check "BASH_ENV dropped" "$(grep -c '^BASH_ENV=' "$E")" 0
check "exported bash functions dropped" "$(grep -c '^BASH_FUNC' "$E")" 0
check "CONFIG_SERVICE_URL dropped" "$(grep -c '^CONFIG_SERVICE_URL=' "$E")" 0
check "DYLD_* dropped" "$(grep -c '^DYLD_' "$E")" 0

echo "== exit status and signals reach launchd =="
echo 3 >"$T/rc"; L restic; check "child exit code relayed" "$?" 3; rm -f "$T/rc"
rm -f "$T/bin/rh7-fleet-audit"; L audit 2>/dev/null; check "missing target -> 127" "$?" 127

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
