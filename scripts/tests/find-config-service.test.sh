#!/usr/bin/env bash
# Coverage for config-service discovery — in BOTH scripts that carry it.
#
# This function decides which database the whole fleet's audits are written to.
# The properties below are the ones whose violation is SILENT — a split registry
# looks healthy from every side, so nothing surfaces it until someone goes
# looking months later.
#
# Why the suite runs twice: audit-device.sh and collector-runner.sh each carry a
# verbatim copy of the resolver, because both are distributed as single
# self-contained files over HTTP and neither can source a library. This test
# previously covered only audit-device.sh, and collector-runner.sh kept the
# pre-#63 probe-first implementation — localhost first, no pin support — for two
# months without anything noticing.
#
# Run: bash scripts/tests/find-config-service.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

AUDIT="$REPO_ROOT/scripts/audit-device.sh"
RUNNER="$REPO_ROOT/scripts/collector-runner.sh"

# Extract the shared block by its markers, so the test never executes either
# script and both are read the same way.
extract_block() {
  sed -n '/^# >>> BEGIN SHARED CONFIG-SERVICE RESOLVER >>>/,/^# <<< END SHARED CONFIG-SERVICE RESOLVER <<</p' "$1" > "$2"
  grep -q 'find_config_service()' "$2" || {
    echo "FATAL: could not extract the shared resolver from $1"; exit 1; }
}
extract_block "$AUDIT"  "$TEST_ROOT/audit.sh"
extract_block "$RUNNER" "$TEST_ROOT/runner.sh"

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

STUDIO="http://rouvens-mac-studio:3456"
HONCHO="http://vps-honcho:3456"
mkdir -p "$TEST_ROOT/home"

# ── the suite, run against one extracted block ───────────────────────────────
run_suite() {
  local label="$1" BLOCK="$2" out

  run_find() {
    env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
        CONFIG_SERVICE_PIN_SYSTEM="$TEST_ROOT/etc-pin" \
        CONFIG_SERVICE_PIN_USER="$TEST_ROOT/user-pin" \
        "$@" bash -c "set -euo pipefail; source '$BLOCK'; find_config_service" 2>"$TEST_ROOT/stderr"
  }
  rc_of() { run_find "$@" >/dev/null 2>&1; echo $?; }

  : > "$TEST_ROOT/etc-pin"; : > "$TEST_ROOT/user-pin"

  echo
  echo "######## $label ########"

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
    "$(grep -c 'CONFIG_SERVICE_FALLBACKS.*localhost' "$BLOCK")" "0"
  check "localhost is not discovered even when it answers" \
    "$(run_find MOCK_OK='http://localhost:3456')" ""

  echo "== REGRESSION: no dead nodes in the fallback list =="
  # `rouvens-mac-studio-1` has not existed in the tailnet for months; each dead
  # name costs a curl timeout on every bootstrap probe.
  # Anchored to the assignment, not the file: the comment above it names the
  # removed host deliberately, and a bare grep would match that prose forever.
  check "rouvens-mac-studio-1 absent from the fallback list" \
    "$(grep '^CONFIG_SERVICE_FALLBACKS=' "$BLOCK" | grep -c 'rouvens-mac-studio-1')" "0"

  echo "== identity: a 200 is not proof it is the config service =="
  check "impostor on :3456 rejected" \
    "$(run_find MOCK_IMPOSTOR="$STUDIO" MOCK_OK='')" ""
  check "impostor pin rejected too" \
    "$(run_find CONFIG_SERVICE_URL=$STUDIO MOCK_IMPOSTOR="$STUDIO" MOCK_OK='')" ""
}

run_suite "scripts/audit-device.sh"      "$TEST_ROOT/audit.sh"
run_suite "scripts/collector-runner.sh"  "$TEST_ROOT/runner.sh"

# ── the two copies must not drift ────────────────────────────────────────────
echo
echo "######## shared block integrity ########"
echo "== the two copies are byte-identical =="
# The copies exist because neither script can source a library — both are served
# as single self-contained files. Duplication is fine; SILENT duplication is what
# let collector-runner.sh keep the pre-#63 resolver for two months.
if diff -u "$TEST_ROOT/audit.sh" "$TEST_ROOT/runner.sh" > "$TEST_ROOT/drift.diff"; then
  echo "  ok   — audit-device.sh and collector-runner.sh carry the same resolver"
  pass=$((pass+1))
else
  echo "  FAIL — the shared resolver has DRIFTED between the two scripts:"
  sed 's/^/         /' "$TEST_ROOT/drift.diff" | head -40
  fail=$((fail+1))
fi

# ── one resolution per run ───────────────────────────────────────────────────
echo
echo "== the runner hands its resolved URL to the collector =="
# Without this the runner can fetch and sha256-verify the collector against one
# instance while the collector re-resolves and POSTs its audit to another — the
# integrity gate evaluated against a server that never receives the data.
check "runner records the instance it verified against" \
  "$(grep -c 'RESOLVED_CONFIG_URL="\$base"' "$RUNNER")" "1"
check "runner exports CONFIG_SERVICE_URL before exec" \
  "$(grep -c 'export CONFIG_SERVICE_URL="\$RESOLVED_CONFIG_URL"' "$RUNNER")" "1"
check "the export precedes the exec hand-off" \
  "$([ "$(grep -n 'export CONFIG_SERVICE_URL' "$RUNNER" | cut -d: -f1 | head -1)" -lt \
       "$(grep -n '^exec bash "\$CACHE"' "$RUNNER" | cut -d: -f1 | head -1)" ] && echo yes || echo no)" "yes"
check "the collector honours an inherited CONFIG_SERVICE_URL above every pin file" \
  "$(env -i PATH="$PATH" HOME="$TEST_ROOT/home" \
       CONFIG_SERVICE_PIN_SYSTEM=/dev/null CONFIG_SERVICE_PIN_USER=/dev/null \
       CONFIG_SERVICE_URL="$HONCHO" MOCK_OK="$HONCHO $STUDIO" \
       bash -c "set -euo pipefail; source '$TEST_ROOT/audit.sh'; find_config_service" 2>/dev/null)" "$HONCHO"

echo "== the runner tests the resolver's VALUE, not its exit status =="
# The contract is "echo a URL or nothing, and ALWAYS return 0", so a `|| { ... }`
# guard on the call is dead code that reads like a check.
check "no exit-status guard on find_config_service" \
  "$(grep -c 'find_config_service)" ||' "$RUNNER")" "0"
check "empty result is guarded explicitly" \
  "$(grep -c '\[ -n "\$base" \] ||' "$RUNNER")" "1"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
