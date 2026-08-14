#!/usr/bin/env bash
# Coverage for config-service discovery in scripts/audit-device.sh.
#
# This function decides which database the whole fleet's audits are written to.
# The properties below are the ones whose violation is SILENT — a split registry
# looks healthy from every side, so nothing surfaces it until someone goes
# looking months later.
#
# Run: bash scripts/tests/find-config-service.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/scripts/audit-device.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Extract just the discovery block, so the test never executes the audit script.
sed -n '/^# ── Find config service/,/^if \[\[ "\$MODE" == "--install" \]\]/p' "$SRC" \
  | sed '$d' > "$TEST_ROOT/discovery.sh"

grep -q 'find_config_service()' "$TEST_ROOT/discovery.sh" || {
  echo "FATAL: could not extract find_config_service from $SRC"; exit 1; }

# curl stand-in. MOCK_OK is a space-separated list of URLs that answer with a
# real config-service health body; MOCK_IMPOSTOR answers 200 with something else.
FAKE_BIN="$TEST_ROOT/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
for ok in ${MOCK_OK:-}; do
  [ "$url" = "${ok%/}/api/health" ] && { printf '{"status":"ok","service":"config-service","version":"0.1.0"}'; exit 0; }
done
for imp in ${MOCK_IMPOSTOR:-}; do
  [ "$url" = "${imp%/}/api/health" ] && { printf '{"status":"ok","service":"something-else"}'; exit 0; }
done
exit 7
FAKE_CURL
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH"

pass=0; fail=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi
}

# Run find_config_service in a clean subshell with the given env.
run_find() {
  env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
      CONFIG_SERVICE_PIN_SYSTEM="$TEST_ROOT/etc-pin" \
      CONFIG_SERVICE_PIN_USER="$TEST_ROOT/user-pin" \
      "$@" bash -c "set -euo pipefail; source '$TEST_ROOT/discovery.sh'; find_config_service" 2>"$TEST_ROOT/stderr"
}
rc_of() { run_find "$@" >/dev/null 2>&1; echo $?; }

STUDIO="http://rouvens-mac-studio:3456"
HONCHO="http://vps-honcho:3456"
: > "$TEST_ROOT/etc-pin"; : > "$TEST_ROOT/user-pin"; mkdir -p "$TEST_ROOT/home"

echo "== the contract: always exit 0, even with nothing reachable =="
# Both call sites do CONFIG_URL=$(find_config_service) under `set -e`, so a
# non-zero return aborts the whole audit instead of degrading gracefully.
check "exit 0 when nothing answers"        "$(rc_of MOCK_OK='')"                  "0"
check "empty output when nothing answers"  "$(run_find MOCK_OK='')"               ""
check "exit 0 when a pin is unreachable"   "$(rc_of CONFIG_SERVICE_URL=$HONCHO MOCK_OK='')" "0"

echo "== an explicit pin wins over anything probing would find =="
check "CONFIG_SERVICE_URL honoured" \
  "$(run_find CONFIG_SERVICE_URL=$HONCHO MOCK_OK="$HONCHO $STUDIO")" "$HONCHO"
check "pin wins even though the Studio also answers" \
  "$(run_find CONFIG_SERVICE_URL=$HONCHO MOCK_OK="$STUDIO $HONCHO")" "$HONCHO"
check "trailing slash normalised" \
  "$(run_find CONFIG_SERVICE_URL=$HONCHO/ MOCK_OK="$HONCHO")" "$HONCHO"

echo "== FAIL CLOSED: an unreachable pin must NOT fall back to probing =="
# This is the property that prevents a split registry during an outage: if the
# pinned service is down, probing is most likely to find a DIFFERENT instance
# and quietly start writing the fleet's audits into it.
out=$(run_find CONFIG_SERVICE_URL=$HONCHO MOCK_OK="$STUDIO")
check "returns nothing rather than the Studio" "$out" ""
check "warns about the dead pin" \
  "$(grep -c 'did not answer' "$TEST_ROOT/stderr")" "1"

echo "== pin files, and their precedence =="
echo "$HONCHO" > "$TEST_ROOT/etc-pin"
check "system pin file honoured" "$(run_find MOCK_OK="$HONCHO")" "$HONCHO"
echo "$STUDIO" > "$TEST_ROOT/user-pin"
check "system pin beats user pin" "$(run_find MOCK_OK="$HONCHO $STUDIO")" "$HONCHO"
: > "$TEST_ROOT/etc-pin"
check "user pin used when system pin absent" "$(run_find MOCK_OK="$HONCHO $STUDIO")" "$STUDIO"
printf '# a comment\n\n   %s   \n' "$HONCHO" > "$TEST_ROOT/user-pin"
check "comments and whitespace stripped" "$(run_find MOCK_OK="$HONCHO")" "$HONCHO"
: > "$TEST_ROOT/user-pin"

echo "== bootstrap probing still works for an unpinned host =="
check "discovers a fallback host"  "$(run_find MOCK_OK="$STUDIO")" "$STUDIO"
run_find MOCK_OK="$STUDIO" >/dev/null
check "warns that the host is unpinned" "$(grep -c 'no config-service pin' "$TEST_ROOT/stderr")" "1"

echo "== REGRESSION: a host must never discover itself =="
# `localhost` headed the old probe list, so any host running its own instance
# silently registered into that local database instead of the fleet's.
check "localhost absent from the fallback list" \
  "$(grep -c 'CONFIG_SERVICE_FALLBACKS.*localhost' "$TEST_ROOT/discovery.sh")" "0"
check "localhost is not discovered even when it answers" \
  "$(run_find MOCK_OK='http://localhost:3456')" ""

echo "== identity: a 200 is not proof it is the config service =="
check "impostor on :3456 rejected" \
  "$(run_find MOCK_IMPOSTOR="$STUDIO" MOCK_OK='')" ""
check "impostor pin rejected too" \
  "$(run_find CONFIG_SERVICE_URL=$STUDIO MOCK_IMPOSTOR="$STUDIO" MOCK_OK='')" ""

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
