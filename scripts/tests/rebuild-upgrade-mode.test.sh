#!/usr/bin/env bash
# Coverage for select_by_mode() / load_critical_names() in scripts/rebuild.sh
#
# Run: ./scripts/tests/rebuild-upgrade-mode.test.sh
#
# These pick which declared outdated packages a run upgrades. The property that
# matters most is the failure direction: if the critical list cannot be
# evaluated, critical mode must select NOTHING — never fall back to "all".
#
# Extracted rather than sourced, like rebuild-activation.test.sh: rebuild.sh
# executes top-to-bottom and would run a real rebuild if sourced.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

warn() { echo "[WARN] $*" >&2; }
ensure_declared_lib() { :; }
FLAKE_REF="unused#host"

# shellcheck disable=SC1090
eval "$(sed -n '/^load_critical_names() {/,/^}/p; /^select_by_mode() {/,/^}/p' "$SCRIPT")"
for f in load_critical_names select_by_mode; do
  if ! declare -F "$f" >/dev/null; then
    echo "FATAL: could not extract $f from $SCRIPT" >&2
    exit 1
  fi
done

reset() { CRITICAL_NAMES=""; CRITICAL_KNOWN=false; CRITICAL_LOADED=false; }
INPUT=$'arc\ncursor\nfirefox\n963034692\n'

check() { # check <label> <expected> <actual>
  [[ "$2" == "$3" ]] && good "$1" || bad "$1" "expected [$2] got [$3]"
}

echo ""
echo "select_by_mode"

critical_upgrade_names() { printf '%s\n' firefox arc not-declared; }

reset; UPGRADE_MODE=all
check "all selects everything" "arc cursor firefox 963034692" "$(select_by_mode <<<"$INPUT" | xargs)"

reset; UPGRADE_MODE=none
check "none selects nothing" "" "$(select_by_mode <<<"$INPUT" | xargs)"

reset; UPGRADE_MODE=critical; load_critical_names
check "critical selects only the intersection" "arc firefox" "$(select_by_mode <<<"$INPUT" | xargs)"

critical_upgrade_names() { return 1; }
reset; UPGRADE_MODE=critical; load_critical_names 2>/dev/null
check "unevaluable critical list selects NOTHING (not all)" "" "$(select_by_mode <<<"$INPUT" | xargs)"
$CRITICAL_KNOWN && bad "failure leaves CRITICAL_KNOWN=false" "was true" \
  || good "failure leaves CRITICAL_KNOWN=false"

critical_upgrade_names() { :; }
reset; UPGRADE_MODE=critical; load_critical_names
check "empty critical list selects nothing" "" "$(select_by_mode <<<"$INPUT" | xargs)"
$CRITICAL_KNOWN && good "empty list is still KNOWN (not a failure)" \
  || bad "empty list is still KNOWN (not a failure)" "was false"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
