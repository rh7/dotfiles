#!/usr/bin/env bash
# Coverage for moving the fleet off the UNVERIFIED daily audit and onto the
# integrity-gated collector-runner.
#
# Run: ./scripts/tests/enroll-runner-migration.test.sh
#
# `audit-device.sh --install` on a host with no ~/dotfiles clone writes
#   t="$(mktemp)" && curl -fsSL https://config.rh7labs.com/audit -o "$t" && bash "$t" --run; rm -f "$t" # fleet-audit
# — whatever the public short link serves, executed daily with no sha256 / scan /
# ref gate. Older Macs carry the equivalent com.rh7.audit LaunchAgent. These
# tests pin:
#   - collector-runner.sh --install removes ONLY that short-link line (every other
#     cron line survives verbatim), never duplicates its own line, and retires the
#     legacy com.rh7.audit agent on macOS — on the declarative (home-manager) path
#     too, without touching the declared plist;
#   - enroll.sh counts only the verified runner as a healthy schedule, so a plain
#     `curl … | bash` (no --force) migrates a short-link / legacy host, installs
#     the runner at a stable on-disk path, and leaves a healthy host alone.
#
# Everything runs for real in sandbox HOMEs. uname / hostname / tailscale /
# crontab / launchctl / curl are stubs on PATH: crontab is a file, launchctl
# keeps a set of loaded labels, and curl serves the runner, a fake collector with
# a matching manifest, and the device record — so the gated fetch → verify → run
# path executes end to end without a network.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER_SRC="$ROOT/scripts/collector-runner.sh"
ENROLL="$ROOT/scripts/enroll.sh"
SHORTLINK='17 8 * * * t="$(mktemp)" && curl -fsSL https://config.rh7labs.com/audit -o "$t" && bash "$t" --run; rm -f "$t" # fleet-audit'
UNRELATED_1='0 3 * * * /usr/local/bin/backup.sh --nightly'
UNRELATED_2='15 9 * * * bash /home/u/dotfiles/scripts/audit-device.sh --run # fleet-audit'
UNRELATED_3='30 2 * * * curl -fsSL https://config.rh7labs.com/audit-lite -o /tmp/x # mine'

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { local name="$1" detail="$2"; shift 2; if "$@"; then good "$name"; else bad "$name" "$detail"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_OS:-Linux}"
EOF
cat > "$BIN/hostname" <<'EOF'
#!/usr/bin/env bash
echo test-host
EOF
cat > "$BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
echo '{"BackendState":"Running"}'
EOF
# crontab: a file. Every write is counted in $CRONTAB_FILE.writes. A
# $CRONTAB_FILE.deny-read / .deny-write marker models macOS TCC refusing crontab
# to a caller without Full Disk Access.
cat > "$BIN/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [ -f "$CRONTAB_FILE.deny-read" ] && { echo "crontab: Operation not permitted" >&2; exit 1; }
      [ -f "$CRONTAB_FILE" ] || { echo "no crontab for $(id -un)" >&2; exit 1; }; cat "$CRONTAB_FILE" ;;
  -)  [ -f "$CRONTAB_FILE.deny-write" ] && { cat >/dev/null; echo "crontab: Operation not permitted" >&2; exit 1; }
      cat > "$CRONTAB_FILE"; echo write >> "$CRONTAB_FILE.writes" ;;
  *)  exit 2 ;;
esac
EOF
# launchctl: loaded labels are files in $LC_STATE; every call is logged.
cat > "$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$LC_STATE/calls.log"
case "$1" in
  bootstrap) touch "$LC_STATE/$(basename "$3" .plist)" ;;
  bootout)   [ -f "$LC_STATE/${2##*/}" ] || exit 3; rm -f "$LC_STATE/${2##*/}" ;;
  unload)    rm -f "$LC_STATE/$(basename "$2" .plist)" ;;
  print)     [ -f "$LC_STATE/${2##*/}" ] || exit 113 ;;
  list)      for f in "$LC_STATE"/com.*; do [ -f "$f" ] && printf -- '-\t0\t%s\n' "${f##*/}"; done ;;
esac
exit 0
EOF
# curl: the runner (short link), config-service health, collector manifest +
# body, and the device record. Anything else fails like an unreachable host.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""; method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -X) method="$2"; shift ;;
    -d|-H|--max-time) shift ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
echo "$method $url" >> "$CURL_LOG"
emit() { if [ -n "$out" ]; then cat > "$out"; else cat; fi; }
case "$url" in
  https://config.rh7labs.com/collector-runner) emit < "$RUNNER_SRC" ;;
  */api/health) echo '{"status":"ok","service":"config-service"}' | emit ;;
  */api/collector/audit-device.sh/manifest)
    printf '{"sha256":"%s","read_only_scan":{"clean":true},"ref":"origin/main","branch":"main","dirty":false}\n' \
      "$(cat "$FAKE_AUDIT.sha")" | emit ;;
  */api/collector/audit-device.sh) emit < "$FAKE_AUDIT" ;;
  */api/devices/test-host)
    [ "$method" = PATCH ] && exit 0
    printf '{"hostname":"test-host","role":"server","last_seen":"%s","age_public_key":"age1x"}\n' \
      "$(date -u '+%Y-%m-%d %H:%M:%S')" | emit ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$BIN"/*

# The collector the stub serves: records that the GATED run executed it.
FAKE_AUDIT="$TMP/fake-audit.sh"
printf '#!/usr/bin/env bash\necho "audit-ran $*" >> "$HOME/audit.log"\n' > "$FAKE_AUDIT"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$FAKE_AUDIT" | awk '{print $1}' > "$FAKE_AUDIT.sha"
else sha256sum "$FAKE_AUDIT" | awk '{print $1}' > "$FAKE_AUDIT.sha"; fi

# new_home <name> -> path; sandbox HOME with its own crontab + launchd state
new_home() {
  local h="$TMP/$1"
  mkdir -p "$h/lc" "$h/tmp" "$h/Library/LaunchAgents"
  : > "$h/curl.log"; : > "$h/lc/calls.log"
  printf '%s\n' "$h"
}
# sandbox_env <home> <os> -> env assignments shared by every invocation
sandbox_env() {
  printf '%s\n' "HOME=$1" "STUB_OS=$2" "PATH=$BIN:$PATH" "TMPDIR=$1/tmp" \
    "CRONTAB_FILE=$1/crontab" "LC_STATE=$1/lc" "CURL_LOG=$1/curl.log" \
    "RUNNER_SRC=$RUNNER_SRC" "FAKE_AUDIT=$FAKE_AUDIT" \
    "CONFIG_SERVICE_URL=http://stub-config:3456" \
    "CONFIG_SERVICE_PIN_SYSTEM=$1/no-pin" "XDG_CONFIG_HOME=$1/.config"
}
# runner_install <home> <os>  — the runner from its on-disk path (clone-style)
runner_install() {
  local env_args; mapfile -t env_args < <(sandbox_env "$1" "$2")
  OUT="$(env "${env_args[@]}" bash "$RUNNER_SRC" --install </dev/null 2>&1)"; RC=$?
}
# enroll <home> <os> [args…] — exactly as the owner runs it: piped into bash
enroll() {
  local home="$1" os="$2"; shift 2
  local env_args; mapfile -t env_args < <(sandbox_env "$home" "$os")
  OUT="$(env "${env_args[@]}" bash -s -- "$@" < "$ENROLL" 2>&1)"; RC=$?
}
runner_lines() { grep -c '# fleet-collector-runner' "$1/crontab" 2>/dev/null || true; }
has_line() { grep -qxF -- "$2" "$1/crontab"; }
writes() { [ -f "$1/crontab.writes" ] && wc -l < "$1/crontab.writes" | tr -d ' ' || echo 0; }

echo ""
echo "regex parity"
re_runner="$(grep -m1 '^SHORTLINK_CRON_RE=' "$RUNNER_SRC")"
re_enroll="$(grep -m1 '^SHORTLINK_CRON_RE=' "$ENROLL")"
check "enroll.sh and collector-runner.sh match the SAME short-link line" \
  "runner: $re_runner | enroll: $re_enroll" test -n "$re_runner" -a "$re_runner" = "$re_enroll"

echo ""
echo "collector-runner --install (Linux): short-link cron migrated, others kept"
H="$(new_home linux-migrate)"
printf '%s\n' "$UNRELATED_1" "$SHORTLINK" "$UNRELATED_2" "$UNRELATED_3" > "$H/crontab"
runner_install "$H" Linux
check "install succeeds" "rc=$RC out: $OUT" test "$RC" -eq 0
check "short-link '# fleet-audit' line removed" "crontab: $(cat "$H/crontab")" \
  bash -c "! grep -q 'rh7labs.com/audit -o' '$H/crontab'"
check "unrelated cron line kept verbatim" "crontab: $(cat "$H/crontab")" has_line "$H" "$UNRELATED_1"
check "clone-based '# fleet-audit' line (no short-link fetch) kept" "crontab: $(cat "$H/crontab")" has_line "$H" "$UNRELATED_2"
check "short-link fetch WITHOUT the marker kept" "crontab: $(cat "$H/crontab")" has_line "$H" "$UNRELATED_3"
check "exactly one runner line" "crontab: $(cat "$H/crontab")" test "$(runner_lines "$H")" -eq 1
check "runner line points at the on-disk runner" "crontab: $(cat "$H/crontab")" \
  grep -qF "bash $RUNNER_SRC # fleet-collector-runner" "$H/crontab"
before="$(grep -v fleet-collector-runner "$H/crontab")"
runner_install "$H" Linux
check "re-install: still exactly one runner line" "crontab: $(cat "$H/crontab")" test "$(runner_lines "$H")" -eq 1
check "re-install: other lines unchanged" "crontab: $(cat "$H/crontab")" \
  test "$(grep -v fleet-collector-runner "$H/crontab")" = "$before"

H="$(new_home linux-fresh)"
runner_install "$H" Linux
check "fresh user (no crontab): runner line is the whole crontab" "crontab: $(cat "$H/crontab" 2>/dev/null)" \
  test "$(cat "$H/crontab")" = "$(grep fleet-collector-runner "$H/crontab")"

echo ""
echo "collector-runner --install (macOS): legacy schedules retired"
H="$(new_home mac-legacy)"
echo legacy > "$H/Library/LaunchAgents/com.rh7.audit.plist"; touch "$H/lc/com.rh7.audit"
printf '%s\n' "$UNRELATED_1" "$SHORTLINK" > "$H/crontab"
runner_install "$H" Darwin
check "install succeeds" "rc=$RC out: $OUT" test "$RC" -eq 0
check "runner LaunchAgent bootstrapped" "calls: $(cat "$H/lc/calls.log")" test -f "$H/lc/com.rh7.collector-runner"
check "legacy com.rh7.audit booted out" "calls: $(cat "$H/lc/calls.log")" test ! -f "$H/lc/com.rh7.audit"
check "legacy com.rh7.audit plist removed" "ls: $(ls "$H/Library/LaunchAgents")" test ! -f "$H/Library/LaunchAgents/com.rh7.audit.plist"
check "short-link cron removed on macOS too" "crontab: $(cat "$H/crontab")" \
  bash -c "! grep -q 'rh7labs.com/audit -o' '$H/crontab'"
check "unrelated macOS cron line kept" "crontab: $(cat "$H/crontab")" has_line "$H" "$UNRELATED_1"

H="$(new_home mac-clean)"
printf '%s\n' "$UNRELATED_1" > "$H/crontab"
runner_install "$H" Darwin
check "no legacy schedule: crontab is never rewritten" "writes: $(writes "$H")" test "$(writes "$H")" -eq 0

H="$(new_home mac-tcc-write)"
printf '%s\n' "$SHORTLINK" > "$H/crontab"; touch "$H/crontab.deny-write"
runner_install "$H" Darwin
check "TCC blocks the crontab rewrite: --install fails loud" "rc=$RC out: $OUT" test "$RC" -ne 0
check "…and says the short-link line is still scheduled + Full Disk Access" "out: $OUT" \
  bash -c 'grep -q "STILL scheduled" <<<"$1" && grep -q "Full Disk Access" <<<"$1"' _ "$OUT"

H="$(new_home mac-tcc-read)"
touch "$H/crontab.deny-read"
runner_install "$H" Darwin
check "TCC blocks crontab -l: --install fails loud (cannot rule the line out)" "rc=$RC out: $OUT" test "$RC" -ne 0
check "…and names Full Disk Access" "out: $OUT" grep -q "Full Disk Access" <<<"$OUT"

H="$(new_home linux-unreadable)"
printf '%s\n' "$UNRELATED_1" "$SHORTLINK" > "$H/crontab"; touch "$H/crontab.deny-read"
runner_install "$H" Linux
check "Linux: unreadable crontab is never rewritten (would clobber it)" "rc=$RC writes=$(writes "$H") out: $OUT" \
  test "$RC" -ne 0 -a "$(writes "$H")" -eq 0

H="$(new_home mac-declared)"
HM="$H/.local/state/home-manager/gcroots/current-home/LaunchAgents"; mkdir -p "$HM"
echo declared-by-home-manager > "$HM/com.rh7.collector-runner.plist"
cp "$HM/com.rh7.collector-runner.plist" "$H/Library/LaunchAgents/"
echo legacy > "$H/Library/LaunchAgents/com.rh7.audit.plist"; touch "$H/lc/com.rh7.audit"
runner_install "$H" Darwin
check "declared agent: plist not overwritten" "plist: $(cat "$H/Library/LaunchAgents/com.rh7.collector-runner.plist")" \
  test "$(cat "$H/Library/LaunchAgents/com.rh7.collector-runner.plist")" = declared-by-home-manager
check "declared agent: legacy com.rh7.audit still retired" "ls: $(ls "$H/Library/LaunchAgents")" \
  test ! -f "$H/Library/LaunchAgents/com.rh7.audit.plist" -a ! -f "$H/lc/com.rh7.audit"

echo ""
echo "enroll (Linux, no clone): short-link host migrates on a PLAIN run"
H="$(new_home enroll-linux)"
printf '%s\n' "$UNRELATED_1" "$SHORTLINK" > "$H/crontab"
enroll "$H" Linux
check "exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "reports the short-link cron as needing migration" "out: $OUT" grep -q "unverified short-link cron" <<<"$OUT"
check "short-link line removed" "crontab: $(cat "$H/crontab")" bash -c "! grep -q 'rh7labs.com/audit -o' '$H/crontab'"
check "unrelated line kept" "crontab: $(cat "$H/crontab")" has_line "$H" "$UNRELATED_1"
check "exactly one runner line" "crontab: $(cat "$H/crontab")" test "$(runner_lines "$H")" -eq 1
self="$H/.cache/fleet-collector/collector-runner.sh"
check "schedule points at the self-installed persistent runner" "crontab: $(cat "$H/crontab")" \
  grep -qF "bash $self # fleet-collector-runner" "$H/crontab"
check "persistent runner is the served runner" "missing/different: $self" cmp -s "$self" "$RUNNER_SRC"
check "first audit ran through the gated runner" "audit.log: $(cat "$H/audit.log" 2>/dev/null)" grep -qx "audit-ran --run" "$H/audit.log"
check "the raw audit short link is never fetched" "curl: $(cat "$H/curl.log")" bash -c "! grep -q 'rh7labs.com/audit\$' '$H/curl.log'"
check "post-flight ran (stdin not eaten under curl|bash)" "out: $OUT" grep -q "Done." <<<"$OUT"
check "enroll temp runner cleaned up" "tmp: $(ls "$H/tmp")" bash -c '! compgen -G "$1/rh7-enroll-runner.*" >/dev/null' _ "$H/tmp"

echo ""
echo "enroll (Linux): healthy runner host is left alone"
w0="$(writes "$H")"; : > "$H/audit.log"
enroll "$H" Linux
check "exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "reports the verified runner as installed" "out: $OUT" grep -q "verified collector-runner installed" <<<"$OUT"
check "says already healthy" "out: $OUT" grep -q "Already enrolled and healthy" <<<"$OUT"
check "crontab not rewritten" "writes before $w0, after $(writes "$H")" test "$(writes "$H")" -eq "$w0"
check "refresh audit still runs gated" "audit.log: $(cat "$H/audit.log")" grep -qx "audit-ran --run" "$H/audit.log"

enroll "$H" Linux --force
check "--force: exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "--force: still exactly one runner line" "crontab: $(cat "$H/crontab")" test "$(runner_lines "$H")" -eq 1

echo ""
echo "enroll --status: reports, changes nothing"
H="$(new_home enroll-status)"
printf '%s\n' "$SHORTLINK" > "$H/crontab"
enroll "$H" Linux --status
check "short-link line untouched" "crontab: $(cat "$H/crontab")" has_line "$H" "$SHORTLINK"
check "no runner fetched" "curl: $(cat "$H/curl.log")" bash -c "! grep -q collector-runner '$H/curl.log'"
check "says it needs migrating" "out: $OUT" grep -q "needs migrating" <<<"$OUT"

echo ""
echo "enroll (Linux, runner AND short-link line): not healthy until the line is gone"
H="$(new_home enroll-both)"
printf '%s\n' "$SHORTLINK" "5 8 * * * bash /x/collector-runner.sh # fleet-collector-runner" > "$H/crontab"
enroll "$H" Linux
check "exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "does not call it healthy" "out: $OUT" bash -c "! grep -q 'Already enrolled and healthy' <<<\"\$1\"" _ "$OUT"
check "short-link line removed" "crontab: $(cat "$H/crontab")" bash -c "! grep -q 'rh7labs.com/audit -o' '$H/crontab'"
check "exactly one runner line" "crontab: $(cat "$H/crontab")" test "$(runner_lines "$H")" -eq 1

echo ""
echo "enroll (Linux, with a clone): schedules the clone's runner"
H="$(new_home enroll-clone)"
mkdir -p "$H/dotfiles/scripts"; cp "$RUNNER_SRC" "$H/dotfiles/scripts/collector-runner.sh"
enroll "$H" Linux
check "exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "cron runs the clone's runner" "crontab: $(cat "$H/crontab")" \
  grep -qF "bash $H/dotfiles/scripts/collector-runner.sh # fleet-collector-runner" "$H/crontab"
check "runner not downloaded" "curl: $(cat "$H/curl.log")" bash -c "! grep -q 'collector-runner\$' '$H/curl.log'"

echo ""
echo "enroll (macOS, no clone): legacy com.rh7.audit host migrates on a PLAIN run"
H="$(new_home enroll-mac)"
echo legacy > "$H/Library/LaunchAgents/com.rh7.audit.plist"; touch "$H/lc/com.rh7.audit"
enroll "$H" Darwin
check "exits 0" "rc=$RC out: $OUT" test "$RC" -eq 0
check "reports the legacy agent as needing migration" "out: $OUT" grep -q "legacy unverified com.rh7.audit" <<<"$OUT"
check "runner LaunchAgent loaded" "calls: $(cat "$H/lc/calls.log")" test -f "$H/lc/com.rh7.collector-runner"
check "LaunchAgent runs the persistent runner" "plist: $(cat "$H/Library/LaunchAgents/com.rh7.collector-runner.plist" 2>/dev/null)" \
  grep -qF "bash \"$H/.cache/fleet-collector/collector-runner.sh\"" "$H/Library/LaunchAgents/com.rh7.collector-runner.plist"
check "legacy agent unloaded + removed" "ls: $(ls "$H/Library/LaunchAgents")" \
  test ! -f "$H/lc/com.rh7.audit" -a ! -f "$H/Library/LaunchAgents/com.rh7.audit.plist"
check "reports Done" "out: $OUT" grep -q "Done." <<<"$OUT"

echo ""
echo "enroll (macOS): short-link cron that TCC will not let us remove fails loud"
H="$(new_home enroll-mac-tcc)"
printf '%s\n' "$SHORTLINK" > "$H/crontab"; touch "$H/crontab.deny-write"
enroll "$H" Darwin
check "exits non-zero (never a false 'enrolled')" "rc=$RC out: $OUT" test "$RC" -ne 0
check "names what is still present + the Full Disk Access fix" "out: $OUT" \
  bash -c 'grep -q "Still present: unverified short-link cron" <<<"$1" && grep -q "Full Disk Access" <<<"$1"' _ "$OUT"
check "the verified runner is installed regardless" "lc: $(ls "$H/lc")" test -f "$H/lc/com.rh7.collector-runner"

echo ""
echo "enroll (macOS): legacy agent present beside the runner is NOT healthy"
H="$(new_home enroll-mac-both)"
touch "$H/lc/com.rh7.collector-runner" "$H/lc/com.rh7.audit"
echo legacy > "$H/Library/LaunchAgents/com.rh7.audit.plist"
enroll "$H" Darwin --status
check "--status does not call it healthy" "out: $OUT" grep -q "needs migrating" <<<"$OUT"
check "--status leaves the legacy agent" "ls: $(ls "$H/Library/LaunchAgents")" test -f "$H/Library/LaunchAgents/com.rh7.audit.plist"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
