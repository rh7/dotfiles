#!/usr/bin/env bash
# Coverage for the adopt / retire / App Management logic in scripts/rebuild.sh
#
# Run: ./scripts/tests/rebuild-cask-lifecycle.test.sh
#
# These decide what a rebuild REPLACES and UNINSTALLS, so the property that
# matters most is the failure direction: an inventory or evaluation failure must
# leave the lists empty — never guess at what to remove.
#
# Extracted rather than sourced, like rebuild-upgrade-mode.test.sh: rebuild.sh
# executes top-to-bottom and would run a real rebuild if sourced.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { [[ "$2" == "$3" ]] && good "$1" || bad "$1" "expected [$2] got [$3]"; }

info() { :; }; warn() { :; }; ok() { :; }; err() { :; }
FLAKE_REF="unused#host"
APP_MGMT_PANE="x-test:pane"

# shellcheck source=../lib/declared-packages.sh
source "$ROOT/lib/declared-packages.sh"
# shellcheck disable=SC1090
eval "$(sed -n '/^app_bundle_modifiable() {/,/^}/p; /^cask_app_targets() {/,/^}/p;
               /^cask_lifecycle_plan() {/,/^}/p; /^ensure_app_management() {/,/^}/p' "$SCRIPT")"
for f in app_bundle_modifiable cask_app_targets cask_lifecycle_plan ensure_app_management; do
  if ! declare -F "$f" >/dev/null; then
    echo "FATAL: could not extract $f from $SCRIPT" >&2
    exit 1
  fi
done

PLAN_TMP=$(mktemp -d); APPS=$(mktemp -d)
trap 'rm -rf "$PLAN_TMP" "$APPS"' EXIT
mkdir "$APPS/Zen.app"   # hand-installed copy of a declared cask

# ── stubs ──
pgrep() { return 1; }
open() { :; }
osascript() { :; }
sleep() { :; }
terminal_app_name() { echo "TestTerm"; }
XATTR_MODE=allow   # allow | eperm | eacces
xattr() {
  case "$XATTR_MODE" in
    allow) return 0 ;;
    eperm) echo "xattr: [Errno 1] Operation not permitted: '$3'" >&2; return 1 ;;
    eacces) echo "xattr: [Errno 13] Permission denied: '$3'" >&2; return 1 ;;
  esac
}
BREW_LIST_FAILS=false
brew() {
  case "$1 $2" in
    "list --cask")
      $BREW_LIST_FAILS && return 1
      printf '%s\n' vlc session stremio other ;;
    "info --cask")
      cat <<JSON
{"casks":[
 {"token":"zen","artifacts":[{"app":["Zen.app"],"target":"$APPS/Zen.app"}]},
 {"token":"newapp","artifacts":[{"app":["New.app"],"target":"$APPS/New.app"}]},
 {"token":"tailscale-app","artifacts":[{"pkg":["x.pkg"]}]}
]}
JSON
      ;;
  esac
}
RETIRED_FAILS=false
retired_cask_names() { $RETIRED_FAILS && return 1; printf '%s\n' session stremio never-installed; }
printf '%s\n' zen vlc newapp tailscale-app >"$PLAN_TMP/declared_casks"

echo ""
echo "app_bundle_modifiable"
XATTR_MODE=allow;  app_bundle_modifiable "$APPS/Zen.app" && good "writable bundle → modifiable" || bad "writable bundle → modifiable" "returned 1"
XATTR_MODE=eperm;  app_bundle_modifiable "$APPS/Zen.app" && bad "EPERM → blocked" "returned 0" || good "EPERM → blocked"
XATTR_MODE=eacces; app_bundle_modifiable "$APPS/Zen.app" && good "EACCES (ownership) → left to sudo" || bad "EACCES (ownership) → left to sudo" "returned 1"

echo ""
echo "cask_lifecycle_plan"
XATTR_MODE=allow; cask_lifecycle_plan >/dev/null
check "declared cask with an existing app is ADOPTED" "zen" "$ADOPT_CASKS"
check "app-less and absent casks are NEW installs" "newapp tailscale-app" "$NEW_CASKS"
check "only INSTALLED retired casks are removed" "session stremio" "$RETIRE_CASKS"
check "nothing blocked when the probe passes" "" "$ADOPT_BLOCKED"

XATTR_MODE=eperm; cask_lifecycle_plan >/dev/null
check "App Management block is recorded" "$APPS/Zen.app" "$(xargs <<<"$ADOPT_BLOCKED")"

XATTR_MODE=allow; RETIRED_FAILS=true; cask_lifecycle_plan >/dev/null
check "unevaluable retired list removes NOTHING" "" "$RETIRE_CASKS"
RETIRED_FAILS=false

BREW_LIST_FAILS=true; cask_lifecycle_plan >/dev/null
check "failed inventory adopts nothing" "" "$ADOPT_CASKS"
check "failed inventory removes nothing" "" "$RETIRE_CASKS"
BREW_LIST_FAILS=false

echo ""
echo "ensure_app_management"
ADOPT_BLOCKED=""
( ensure_app_management >/dev/null ) && good "no-op when nothing is blocked" || bad "no-op when nothing is blocked" "exited nonzero"

ADOPT_BLOCKED="$APPS/Zen.app"$'\n'; XATTR_MODE=allow
( ensure_app_management >/dev/null ) && good "continues once the permission is granted" || bad "continues once the permission is granted" "exited nonzero"

ADOPT_BLOCKED="$APPS/Zen.app"$'\n'; XATTR_MODE=eperm
( REBUILD_APP_MGMT_WAIT=0 ensure_app_management >/dev/null 2>&1 ) \
  && bad "still blocked → stops BEFORE authentication" "returned 0" \
  || good "still blocked → stops BEFORE authentication"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
