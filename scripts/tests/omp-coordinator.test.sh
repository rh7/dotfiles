#!/usr/bin/env bash
# Contract coverage for the lean OMP coordinator launcher.
#
# Run: ./scripts/tests/omp-coordinator.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/omp-coordinator"
OVERLAY="$REPO_ROOT/modules/home/profiles/omp-coordinator.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/repo management" "$TMP/active repo"
cat > "$TMP/bin/omp" <<'FAKE_OMP'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$OMP_CAPTURE"
printf '%s' "$PI_CONFIG_FILES" > "$OMP_CONFIG_CAPTURE"
FAKE_OMP
chmod +x "$TMP/bin/omp"

capture_args() {
  local capture="$1"
  shift
  OMP_CAPTURE="$capture" OMP_CONFIG_CAPTURE="$capture.config" \
    PATH="$TMP/bin:$PATH" "$LAUNCHER" "$@"
  mapfile -d '' -t ARGS < "$capture"
  CONFIG_FILES="$(cat "$capture.config")"
}

expect_args() {
  local label="$1"
  shift
  local -a expected=("$@")
  if [[ "${ARGS[*]}" == "${expected[*]}" && ${#ARGS[@]} -eq ${#expected[@]} ]]; then
    good "$label"
  else
    bad "$label" "expected: ${expected[*]} | got: ${ARGS[*]}"
  fi
}

echo ""
echo "omp-coordinator — isolated defaults"

HOME="$TMP/home" XDG_CONFIG_HOME='' OMP_COORDINATOR_ROOT='' OMP_COORDINATOR_CONFIG='' \
  PI_CONFIG_FILES='' capture_args "$TMP/default.args" --no-session
expect_args "defaults to repo-management and the coordinator role" \
  --cwd "$TMP/home/repo-management" \
  --model coordinator \
  --no-session
if [[ "$CONFIG_FILES" == "$TMP/home/.config/omp/coordinator-lean.yml" ]]; then
  good "loads the managed overlay without relocating OMP state"
else
  bad "loads the managed overlay without relocating OMP state" "got: $CONFIG_FILES"
fi

echo ""
echo "omp-coordinator — active repository passthrough"

OMP_COORDINATOR_ROOT="$TMP/repo management" \
OMP_COORDINATOR_CONFIG="$TMP/lean config.yml" \
PI_CONFIG_FILES="$TMP/existing.yml" \
  capture_args "$TMP/active.args" \
    --add-dir "$TMP/active repo" --thinking high "coordinate this"
expect_args "preserves the coordinator role and one deliberate sibling root" \
  --cwd "$TMP/repo management" \
  --model coordinator \
  --add-dir "$TMP/active repo" \
  --thinking high \
  "coordinate this"
if [[ "$CONFIG_FILES" == "$TMP/existing.yml:$TMP/lean config.yml" ]]; then
  good "appends the lean overlay at highest precedence"
else
  bad "appends the lean overlay at highest precedence" "got: $CONFIG_FILES"
fi

expected_overlay=$'workspace:\n  additionalDirectories: []'
actual_overlay="$(cat "$OVERLAY")"
if [[ "$actual_overlay" == "$expected_overlay" ]]; then
  good "overlay changes only the global workspace-root list"
else
  bad "overlay changes only the global workspace-root list" "got: $actual_overlay"
fi

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
