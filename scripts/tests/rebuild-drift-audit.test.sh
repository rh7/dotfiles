#!/usr/bin/env bash
# Coverage for rebuild.sh's drift-audit gate.
#
# WHY THIS EXISTS: the audit is advisory — it prints what `switch` would
# overwrite and lets the user decide. Its `*)` case says so out loud:
# "Audit failed — proceeding without drift check". But the parse above that
# case used `var=$(grep ... | sed ...)`, and under `set -e` + `pipefail` a
# no-match grep exits 1, errexit kills the script on the failed assignment,
# and rebuild.sh exited 1 before building anything. The failure was SILENT in
# the worst way: the last thing on screen was the audit's own output, so it
# read as "the audit ran" rather than "your rebuild never started". Every
# Linux host hit this on every run, because audit-config-drift.sh is macOS-only
# and bails with exit 2 — no DRIFT_RESULT line, no build, no diff, no switch.
#
# The properties below are the ones whose violation is silent: a rebuild that
# stops early still looks like a rebuild that ran.
#
# Run: bash scripts/tests/rebuild-drift-audit.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REBUILD="$REPO_ROOT/scripts/rebuild.sh"

# Extract the gate by its markers, so the test never executes rebuild.sh itself
# (which pulls git, builds a flake and calls sudo).
BLOCK="$TEST_ROOT/drift-audit.sh"
sed -n '/^# >>> BEGIN DRIFT AUDIT >>>/,/^# <<< END DRIFT AUDIT <<</p' "$REBUILD" > "$BLOCK"
grep -q 'DRIFT_RESULT' "$BLOCK" || {
  echo "FATAL: could not extract the drift-audit block from $REBUILD"; exit 1; }

# Harness: run the extracted block under the same shell options rebuild.sh uses,
# against a stub audit that emits $STUB_OUT and exits $STUB_RC.
# Echoes the block's own exit status as the last line of output. $BLOCK_PRE
# (optional) is evaluated before the block; the stub records the BREW_CMD it
# was given in $TEST_ROOT/brew_cmd.
run_block() {
  local os="$1" stub_rc="$2" stub_out="$3" auto_confirm="${4:-true}"
  local fake="$TEST_ROOT/fake-dotfiles"
  mkdir -p "$fake/scripts"
  cat > "$fake/scripts/audit-config-drift.sh" <<STUB
#!/usr/bin/env bash
printf '%s' "\$(cat <<'PAYLOAD'
$stub_out
PAYLOAD
)"
[ -n "$stub_out" ] && echo
echo "\${BREW_CMD-unset}" > "$TEST_ROOT/brew_cmd"
exit $stub_rc
STUB
  chmod +x "$fake/scripts/audit-config-drift.sh"

  env -i PATH="$PATH" HOME="$TEST_ROOT" \
    OS="$os" DOTFILES_DIR="$fake" FLAKE_REF="$fake#testhost" \
    AUTO_CONFIRM="$auto_confirm" BLOCK="$BLOCK" BLOCK_PRE="${BLOCK_PRE:-}" \
    bash -c '
      set -euo pipefail
      BOLD=""; NC=""
      info()  { echo "[INFO]  $*"; }
      warn()  { echo "[WARN]  $*"; }
      err()   { echo "[ERROR] $*" >&2; }
      eval "$BLOCK_PRE"
      # shellcheck disable=SC1090
      source "$BLOCK"
      echo "BLOCK_RC:0"
    ' 2>&1 || echo "BLOCK_RC:$?"
}

pass=0; fail=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass+1))
  else echo "  FAIL — $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi
}
check_contains() {
  case "$2" in
    *"$3"*) echo "  ok   — $1"; pass=$((pass+1)) ;;
    *) echo "  FAIL — $1 (output did not contain '$3')"; fail=$((fail+1))
       echo "         got: $2" ;;
  esac
}
rc_of() { echo "$1" | sed -nE 's/^BLOCK_RC:([0-9]+)$/\1/p' | tail -1; }

SUMMARY="DRIFT_RESULT: risky=0 benign=2 informational=1"

echo ""
echo "drift audit — a failed audit must not abort the rebuild"

# THE REGRESSION. Audit errors out (exit 2) and prints no summary line.
# Before the fix this exited 1 and rebuild.sh stopped dead.
out=$(run_block Darwin 2 "macOS only.")
check "audit exit 2 without a summary line does not abort" "$(rc_of "$out")" "0"
check_contains "audit failure is reported, not swallowed" "$out" "Audit failed (exit 2)"

# Same shape, different cause: a broken flake ref errors before the summary.
out=$(run_block Darwin 2 "error: flake does not provide attribute")
check "any audit error keeps the rebuild going" "$(rc_of "$out")" "0"

echo ""
echo "drift audit — a crash is never reported as 'no drift'"

# kassie-mbp-m1: the audit died under macOS's bash 3.2 with exit 1 — the
# "drift found" code — and no summary line; the block then printed
# "Drift is non-destructive (0 declared item(s) pending …)".
CRASH=$'== Homebrew casks ==\n/Users/x/dotfiles/scripts/audit-config-drift.sh: line 301: tailscale: unbound variable'
out=$(run_block Darwin 1 "$CRASH")
check "exit 1 without a summary line still proceeds" "$(rc_of "$out")" "0"
check_contains "exit 1 without a summary is a FAILURE, not drift" "$out" "drift is UNKNOWN, not zero"
check_contains "the audit's error is shown in the warning" "$out" "Its error:"
check_contains "the error line itself is repeated" "$out" "line 301: tailscale: unbound variable"
case "$out" in
  *"Drift is non-destructive"*) echo "  FAIL — a crash must not read as non-destructive drift"; fail=$((fail+1)) ;;
  *) echo "  ok   — a crash does not read as non-destructive drift"; pass=$((pass+1)) ;;
esac
out=$(run_block Darwin 0 "Auditing x ...")
check_contains "exit 0 without a summary line is a failure too" "$out" "no DRIFT_RESULT line"

echo ""
echo "drift audit — the advisory paths still work"

out=$(run_block Darwin 0 "DRIFT_RESULT: risky=0 benign=0 informational=0")
check "no drift proceeds" "$(rc_of "$out")" "0"
case "$out" in
  *"Audit failed"*) echo "  FAIL — a complete clean audit must not warn"; fail=$((fail+1)) ;;
  *) echo "  ok   — a complete clean audit does not warn"; pass=$((pass+1)) ;;
esac

out=$(run_block Darwin 1 "$SUMMARY")
check "benign drift proceeds" "$(rc_of "$out")" "0"
check_contains "benign counts are parsed, not defaulted" "$out" \
  "2 declared item(s) pending, 1 informational"

out=$(run_block Darwin 1 "DRIFT_RESULT: risky=3 benign=0 informational=0" true)
check "risky drift under --yes proceeds without a tty read" "$(rc_of "$out")" "0"
check_contains "risky drift is still warned about" "$out" \
  "3 manual change(s) above would be overwritten"

echo ""
echo "drift audit — macOS-only work is skipped off macOS"

# audit-config-drift.sh reads dock/casks/MAS/defaults. Running it on Linux only
# ever produced "macOS only." plus a warning the user can do nothing about.
out=$(run_block Linux 2 "macOS only.")
check "Linux skips the audit entirely" "$(rc_of "$out")" "0"
case "$out" in
  *"Auditing local state"*)
    echo "  FAIL — Linux must not run the macOS-only audit"; fail=$((fail+1)) ;;
  *)
    echo "  ok   — Linux does not run the macOS-only audit"; pass=$((pass+1)) ;;
esac

echo ""
echo "drift audit — Homebrew owned by system.primaryUser"

# kassie-mbp-m1: the audit is a child process, so rebuild.sh's brew() wrapper
# never reached it and its `brew info` ran as the invoker — 25 declared apps
# read as unmanaged. The block hands the owner's invocation over as BREW_CMD,
# inside the run's one authentication.
XUSER='BREW_AS_PRIMARY=true; PRIMARY_USER=kassie; BREW_BIN=/opt/homebrew/bin/brew
  SUDO_AUTHENTICATED=false
  authenticate_once() { echo "AUTH_ONCE"; SUDO_AUTHENTICATED=true; }'
NO_CRED='sudo() { echo "SUDO $*"; return 1; }'
CRED='sudo() { echo "SUDO $*"; return 0; }'
out=$(BLOCK_PRE="$XUSER; $NO_CRED; BUILD_ONLY=false" run_block Darwin 0 "DRIFT_RESULT: risky=0 benign=0 informational=0")
check "cross-user: audit runs Homebrew as the primary user" "$(cat "$TEST_ROOT/brew_cmd")" \
  "sudo -n -u kassie -H /opt/homebrew/bin/brew"
check_contains "cross-user: the run's one authentication comes first" "$out" "AUTH_ONCE"
check "cross-user: proceeds" "$(rc_of "$out")" "0"

# --build-only authenticates for nothing. Without a cached credential a
# `sudo -n` BREW_CMD would fail every brew call — every declared cask would
# read as missing — so the audit runs Homebrew as the invoker instead.
out=$(BLOCK_PRE="$XUSER; $NO_CRED; BUILD_ONLY=true" run_block Darwin 0 "DRIFT_RESULT: risky=0 benign=0 informational=0")
check "cross-user --build-only, no credential: brew as the invoker" "$(cat "$TEST_ROOT/brew_cmd")" ""
check_contains "cross-user --build-only, no credential: says so" "$out" "runs Homebrew as you"
case "$out" in
  *AUTH_ONCE*) echo "  FAIL — --build-only must not authenticate for the audit"; fail=$((fail+1)) ;;
  *) echo "  ok   — --build-only does not authenticate for the audit"; pass=$((pass+1)) ;;
esac
out=$(BLOCK_PRE="$XUSER; $CRED; BUILD_ONLY=true" run_block Darwin 0 "DRIFT_RESULT: risky=0 benign=0 informational=0")
check "cross-user --build-only, cached credential: as the primary user" "$(cat "$TEST_ROOT/brew_cmd")" \
  "sudo -n -u kassie -H /opt/homebrew/bin/brew"

out=$(BLOCK_PRE='export BREW_CMD="stale from env"' run_block Darwin 0 "DRIFT_RESULT: risky=0 benign=0 informational=0")
check "same user: plain brew (an inherited BREW_CMD is cleared)" "$(cat "$TEST_ROOT/brew_cmd")" ""

echo ""
if [ "$fail" -gt 0 ]; then
  printf '\033[31m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"
  exit 1
fi
printf '\033[32m%d passed\033[0m\n\n' "$pass"
