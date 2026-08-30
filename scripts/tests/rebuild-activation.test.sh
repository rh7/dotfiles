#!/usr/bin/env bash
# Coverage for run_darwin_rebuild() in scripts/rebuild.sh
#
# Run: ./scripts/tests/rebuild-activation.test.sh
#
# This function decides WHETHER THE SCRIPT ADMITS A FAILURE. Its original form
# ended in `rm -f "$log"`, so it always returned 0: a switch that died during
# activation still reached the "Done." banner and exit 0. A rebuild that lies
# about succeeding is worse than one that prompts too often — nothing surfaces
# a half-switched system until something downstream breaks.
#
# It also GUESSED at causes. An unmatched failure was reported as "likely sops
# secrets on first build (#27)" even when the switch had printed the real cause
# verbatim one line earlier. These tests pin both properties: the status is
# propagated, and an unknown cause is quoted rather than invented.
#
# The function is extracted from rebuild.sh rather than sourced — rebuild.sh
# executes top-to-bottom and would run a real rebuild if sourced.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

# Stubs for the helpers the function calls.
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }
LOG_FILE="/tmp/rebuild-activation-test.log"

# shellcheck disable=SC1090
eval "$(sed -n '/^run_darwin_rebuild() {/,/^}/p' "$SCRIPT")"

if ! declare -F run_darwin_rebuild >/dev/null; then
  echo "FATAL: could not extract run_darwin_rebuild from $SCRIPT" >&2
  exit 1
fi

# fake_switch <exit-code> <output...> — stands in for `sudo darwin-rebuild switch`
fake_switch() { local rc="$1"; shift; printf '%s\n' "$@"; return "$rc"; }

run_case() { # run_case <exit-code> <output...>  -> sets OUT and RC
  OUT="$(run_darwin_rebuild fake_switch "$@" 2>&1)"; RC=$?
}

echo ""
echo "run_darwin_rebuild — exit status propagation"

run_case 0 "setting up /etc..." "Homebrew bundle..."
[[ $RC -eq 0 ]] && good "success returns 0" || bad "success returns 0" "got $RC"
grep -q "System updated" <<<"$OUT" && good "success reports 'System updated'" \
  || bad "success reports 'System updated'" "got: $OUT"

run_case 1 "Homebrew bundle..." "Error: You have not agreed to the Xcode license."
[[ $RC -eq 1 ]] && good "failure propagates exit 1" || bad "failure propagates exit 1" "got $RC"

run_case 3 "boom"
[[ $RC -eq 3 ]] && good "failure propagates the actual code (3)" \
  || bad "failure propagates the actual code (3)" "got $RC"

echo ""
echo "run_darwin_rebuild — cause reporting"

run_case 1 "Homebrew bundle..." "Error: You have not agreed to the Xcode license."
grep -q "xcodebuild -license accept" <<<"$OUT" \
  && good "Xcode gate names the fix" || bad "Xcode gate names the fix" "got: $OUT"
grep -q "NO cask was processed" <<<"$OUT" \
  && good "Xcode gate says no cask ran" || bad "Xcode gate says no cask ran" "got: $OUT"

run_case 1 "error: builder for '/nix/store/x.drv' failed"
grep -q "Nix build error" <<<"$OUT" \
  && good "nix builder failure is named" || bad "nix builder failure is named" "got: $OUT"

run_case 1 "Error: Failed to install Foo from App Store"
grep -q "App Store" <<<"$OUT" \
  && good "mas failure is named" || bad "mas failure is named" "got: $OUT"

# The regression that motivated this file: an unknown cause must not be
# reported as a confident sops diagnosis.
run_case 1 "some novel explosion" "error: the disk caught fire"
grep -qi "sops\|#27" <<<"$OUT" \
  && bad "unknown cause does not guess sops/#27" "got: $OUT" \
  || good "unknown cause does not guess sops/#27"
grep -q "Unrecognised failure" <<<"$OUT" \
  && good "unknown cause is labelled unrecognised" \
  || bad "unknown cause is labelled unrecognised" "got: $OUT"
grep -q "disk caught fire" <<<"$OUT" \
  && good "unknown cause quotes the real error line" \
  || bad "unknown cause quotes the real error line" "got: $OUT"

# Xcode gates Homebrew, so a brew failure alongside it is a symptom, not a
# second independent problem to report.
run_case 1 "Error: You have not agreed to the Xcode license." "Installing foo has failed!"
grep -q "not all Homebrew packages installed" <<<"$OUT" \
  && bad "Xcode suppresses the redundant brew line" "got: $OUT" \
  || good "Xcode suppresses the redundant brew line"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
