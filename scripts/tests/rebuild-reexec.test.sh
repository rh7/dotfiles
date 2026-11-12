#!/usr/bin/env bash
# Coverage for rebuild.sh restarting itself after the checkout sync.
#
# WHY THIS EXISTS: on kassie-mbp-m1 the sync fast-forwarded the checkout from
# 8d5d94f to e1c8cea, which carried the /etc preflight fix — but the running
# bash kept executing the version it had already parsed, so the fix never ran
# and activation failed again with "Unexpected files in /etc".
#
# Pinned, against a real git checkout + origin (no stubbed git):
#   - the sync changed rebuild.sh → the NEW version runs, exactly once, with
#     the original arguments, logging into the first run's log;
#   - rebuild.sh unchanged (up to date, or only other files changed) → no re-exec;
#   - --allow-unmerged on a branch → the checkout is untouched, no re-exec;
#   - a second change inside the re-executed run stops instead of looping;
#   - the body is one function called on the last line.
#
# The checkout's rebuild.sh is the real one plus a marker that exits right
# after the re-exec point, so nothing past the sync (nix, brew, sudo) runs.
#
# Run: bash scripts/tests/rebuild-reexec.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rebuild.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

anchor='^cd "\$DOTFILES_DIR"$'
grep -qE "$anchor" "$SCRIPT" || { echo "FATAL: re-exec anchor not found in $SCRIPT" >&2; exit 1; }

# with_marker <tag> — rebuild.sh that stops (exit 0) just after the re-exec point.
with_marker() {
  awk -v tag="$1" '
    { print }
    !done && $0 == "cd \"$DOTFILES_DIR\"" { print "echo \"MARKER " tag " args=${ORIG_ARGS[*]-} reexeced=${REEXECED:-0}\"; exit 0"; done=1 }
  ' "$SCRIPT"
}

g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# setup <case> — origin + checkout at v1 on main; origin/main one commit ahead.
# <what> decides what that commit changes: script | other | delete | none.
setup() {
  local d="$W/$1" what="$2"
  mkdir -p "$d"
  g init -q --bare "$d/origin.git"
  g clone -q "$d/origin.git" "$d/dot" 2>/dev/null
  mkdir -p "$d/dot/scripts/lib"
  cp "$ROOT/lib/dotfiles-checkout.sh" "$d/dot/scripts/lib/"
  with_marker v1 >"$d/dot/scripts/rebuild.sh"
  echo one >"$d/dot/README"
  g -C "$d/dot" add -A && g -C "$d/dot" commit -qm v1 && g -C "$d/dot" push -q origin HEAD:main
  case "$what" in
    script) with_marker v2 >"$d/dot/scripts/rebuild.sh" ;;
    other)  echo two >"$d/dot/README" ;;
    delete) g -C "$d/dot" rm -q scripts/rebuild.sh ;;
    none)   return 0 ;;
  esac
  g -C "$d/dot" commit -qam v2 && g -C "$d/dot" push -q origin HEAD:main
  g -C "$d/dot" reset -q --hard HEAD~1
}

# run <case> [env…] -- [args…] — writes $W/<case>/out and /rc.
run() {
  local d="$W/$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  ( cd "$d" && env HOME="$d" GIT_CONFIG_GLOBAL=/dev/null DOTFILES_DIR="$d/dot" REBUILD_LOG_DIR="$d/logs" \
      ${envs[@]+"${envs[@]}"} "$BASH" "$d/dot/scripts/rebuild.sh" "$@" 2>&1 | cat >"$d/out"
    echo "${PIPESTATUS[0]}" >"$d/rc" )
}
count() { grep -c -- "$2" "$W/$1/out" || true; }

echo "sync changes rebuild.sh"
setup a script
run a -- --build-only --upgrade=none
check "exit 0" "$(cat "$W/a/rc")" 0
check "restarts exactly once" "$(count a 'restarting the updated version')" 1
check "the new version runs, once" "$(count a 'MARKER v2')" 1
check "the old version does not continue" "$(count a 'MARKER v1')" 0
grep -q 'MARKER v2 args=--build-only --upgrade=none reexeced=1' "$W/a/out" \
  && good "original arguments, guard set" || bad "original arguments, guard set" "$(cat "$W/a/out")"
check "fast-forwarded" "$(g -C "$W/a/dot" rev-parse HEAD)" "$(g -C "$W/a/dot" rev-parse origin/main)"
logs=("$W/a/logs"/*.log)
check "one log for the whole run" "${#logs[@]}" 1
grep -q 'MARKER v2' "${logs[0]}" && grep -q 'Fast-forwarded' "${logs[0]}" \
  && good "the log has both halves" || bad "the log has both halves" "$(cat "${logs[0]}")"

echo ""
echo "rebuild.sh unchanged"
setup b none
run b -- --build-only
check "up to date: no restart" "$(count b 'restarting')" 0
check "up to date: runs on" "$(count b 'MARKER v1')" 1
setup c other
run c -- --build-only
check "only other files changed: no restart" "$(count c 'restarting')" 0
check "only other files changed: runs on" "$(count c 'MARKER v1')" 1
check "only other files changed: still fast-forwarded" \
  "$(g -C "$W/c/dot" rev-parse HEAD)" "$(g -C "$W/c/dot" rev-parse origin/main)"

echo ""
echo "--allow-unmerged"
setup d script
g -C "$W/d/dot" checkout -q -b feature
run d -- --build-only --allow-unmerged
check "on a branch: no restart" "$(count d 'restarting')" 0
check "on a branch: the branch's version runs" "$(count d 'MARKER v1')" 1
check "on a branch: still on the branch" "$(g -C "$W/d/dot" symbolic-ref --short HEAD)" feature

echo ""
echo "no loop"
setup e script
run e RH7_REBUILD_REEXECED=1 -- --build-only
check "changed again after a re-exec: exit 1" "$(cat "$W/e/rc")" 1
check "changed again after a re-exec: no second restart" "$(count e 'restarting')" 0
check "changed again after a re-exec: nothing runs on" "$(count e 'MARKER')" 0
grep -q 'changed again' "$W/e/out" && good "says why" || bad "says why" "$(cat "$W/e/out")"

echo ""
echo "sync removes rebuild.sh"
setup f delete
run f -- --build-only
check "gone after the sync: exit 1" "$(cat "$W/f/rc")" 1
check "gone after the sync: the stale version does not continue" "$(count f 'MARKER')" 0
grep -q 'gone or unreadable after the checkout sync' "$W/f/out" && good "gone after the sync: says why" \
  || bad "gone after the sync: says why" "$(cat "$W/f/out")"

echo ""
echo "structure"
check "last line calls main" "$(tail -n 1 "$SCRIPT")" 'main "$@"; exit'
check "main is opened once, before any code" "$(grep -n '^main() {$' "$SCRIPT" | cut -d: -f1 | wc -l | tr -d ' ')" 1

echo ""
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
