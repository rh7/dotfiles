#!/usr/bin/env bash
# Coverage for sync_dotfiles_checkout() in scripts/lib/dotfiles-checkout.sh —
# rebuild.sh's Step 1 checkout guard (rh7/rh-device-management#312).
#
# Run: bash scripts/tests/rebuild-checkout-guard.test.sh
#
# The guard decides whether a rebuild may build/activate at all. Its violation
# is silent: a machine that activated a stale or unmerged checkout looks exactly
# like one that activated main, and the drift audit (which compares against the
# same checkout) agrees with it. So every refusal condition is pinned here
# against a real bare-origin + clone pair, not against stubbed git. Only the
# lib is sourced, so nothing here builds or activates (no nix, no sudo).

set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/dotfiles-checkout.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

# Hermetic git: no user/system config, fixed identity.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEST_ROOT/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

ORIGIN="$TEST_ROOT/origin.git"
UPSTREAM="$TEST_ROOT/upstream"   # stands in for "someone merged a PR"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$UPSTREAM" 2>/dev/null
echo one > "$UPSTREAM/flake.nix"
git -C "$UPSTREAM" add flake.nix && git -C "$UPSTREAM" commit -qm one
git -C "$UPSTREAM" push -q origin main

# fresh — sets $d to a new clone of origin, on main at origin/main. A global,
# not `fresh`: a command substitution's subshell would lose the counter
# and hand every scenario the same directory.
n=0
fresh() { n=$((n+1)); d="$TEST_ROOT/c$n"; git clone -q "$ORIGIN" "$d" 2>/dev/null; }
advance_origin() { # advance_origin — merges a new commit into origin/main
  echo "$RANDOM" >> "$UPSTREAM/flake.nix"
  git -C "$UPSTREAM" commit -qam more && git -C "$UPSTREAM" push -q origin main; }

# run <dir> <allow_unmerged> [flake_ref] — runs the guard as rebuild.sh does
# (set -euo pipefail, `|| exit`-style call, no color), prints its combined
# output then "RC:<status>".
run() {
  (
    set -euo pipefail
    info() { echo "[INFO] $*"; }; ok() { echo "[OK] $*"; }
    warn() { echo "[WARN] $*"; }; err() { echo "[ERROR] $*" >&2; }
    # Read by the sourced guard, which shellcheck cannot see.
    # shellcheck disable=SC2034
    { BOLD=''; NC=''; DOTFILES_DIR="$1"; }
    if [[ -n "${FAIL_GIT_STATUS:-}" ]]; then
      git() { case " $* " in *" status "*) return 128 ;; esac; command git "$@"; }
    fi
    # shellcheck source=../lib/dotfiles-checkout.sh
    . "$LIB"
    declare -F sync_dotfiles_checkout >/dev/null || { echo "FATAL: guard not defined by $LIB"; exit 99; }
    rc=0; sync_dotfiles_checkout "$2" "rebuild.sh --allow-unmerged" "${3:-}" || rc=$?
    echo "RC:$rc"
  ) 2>&1
}
rc_of() { sed -nE 's/^RC:([0-9]+)$/\1/p' <<<"$1" | tail -1; }
head_of() { git -C "$1" rev-parse HEAD; }
origin_main() { git -C "$ORIGIN" rev-parse main; }

expect() { # expect <label> <want-rc> <output> [substring...]
  local label="$1" want="$2" out="$3"; shift 3
  local got; got=$(rc_of "$out")
  if [[ "$got" != "$want" ]]; then bad "$label" "rc: want $want got ${got:-none}; output: $out"; return; fi
  local s
  for s in "$@"; do
    [[ "$out" == *"$s"* ]] || { bad "$label" "missing [$s] in: $out"; return; }
  done
  good "$label"
}

echo ""
echo "checkout guard — proceeds only on clean main at origin/main"

fresh
out=$(run "$d" false)
expect "clean main at origin/main proceeds" 0 "$out" "Dotfiles at origin/main"

fresh; advance_origin
out=$(run "$d" false)
expect "behind + clean on main fast-forwards and proceeds" 0 "$out" "Fast-forwarded"
[[ "$(head_of "$d")" == "$(origin_main)" ]] && good "fast-forward lands exactly on origin/main" \
  || bad "fast-forward lands exactly on origin/main" "HEAD $(head_of "$d") != $(origin_main)"

fresh; touch "$d/untracked-note"
out=$(run "$d" false)
expect "untracked files alone do not refuse" 0 "$out"

echo ""
echo "checkout guard — refusals"

fresh; before=$(head_of "$d"); advance_origin
echo dirty >> "$d/flake.nix"
out=$(run "$d" false)
expect "dirty tracked tree refuses" 1 "$out" "uncommitted changes" "--allow-unmerged"
[[ "$(head_of "$d")" == "$before" ]] && good "dirty tree is not fast-forwarded under the user" \
  || bad "dirty tree is not fast-forwarded under the user" "HEAD moved"

fresh; git -C "$d" checkout -qb feature
out=$(run "$d" false)
expect "feature branch refuses (even at origin/main's commit)" 1 "$out" "on branch 'feature'"

fresh; git -C "$d" checkout -qb feature; before=$(head_of "$d"); advance_origin
out=$(run "$d" false)
expect "behind feature branch refuses" 1 "$out" "on branch 'feature'" "BEHIND"
[[ "$(head_of "$d")" == "$before" ]] && good "feature branch is never merged into" \
  || bad "feature branch is never merged into" "HEAD moved"

fresh; echo local >> "$d/flake.nix"; git -C "$d" commit -qam local
out=$(run "$d" false)
expect "main ahead of origin/main refuses" 1 "$out" "AHEAD of origin/main" "by 1 commit"

fresh; echo local >> "$d/flake.nix"; git -C "$d" commit -qam local; advance_origin
out=$(run "$d" false)
expect "main diverged from origin/main refuses" 1 "$out" "DIVERGED"

fresh; git -C "$d" checkout -q --detach
out=$(run "$d" false)
expect "detached HEAD refuses" 1 "$out" "detached HEAD"

fresh; git -C "$d" remote set-url origin "$TEST_ROOT/does-not-exist.git"
out=$(run "$d" false)
expect "fetch failure (offline) refuses and names the escape hatch" 1 "$out" \
  "could not fetch origin/main" "--allow-unmerged"

d="$TEST_ROOT/not-a-repo"; mkdir -p "$d"
out=$(run "$d" false)
expect "non-git checkout refuses" 1 "$out" "not a git checkout"

# A git that cannot report status (corrupt/unreadable index) must not read as
# "clean". Corrupting the real index also breaks `fetch`, so fail only
# `status`, via a git wrapper the sourced guard resolves to.
fresh; advance_origin
out=$(FAIL_GIT_STATUS=1 run "$d" false)
expect "unreadable working-tree status refuses (not read as clean)" 1 "$out" "could not read"

# A post-merge hook (or anything the fast-forward triggers) that touches
# tracked files must be caught: cleanliness is re-read after the merge.
fresh; advance_origin
printf '#!/bin/sh\necho hook >> flake.nix\n' > "$d/.git/hooks/post-merge"
chmod +x "$d/.git/hooks/post-merge"
out=$(run "$d" false)
expect "tracked change made during the fast-forward refuses" 1 "$out" "uncommitted changes"

fresh
out=$(run "$d" false "$d#some-other-host")
expect "--flake selecting another host from the checkout proceeds" 0 "$out"
other="$TEST_ROOT/elsewhere"; mkdir -p "$other"
out=$(run "$d" false "$other#host")
expect "--flake pointing outside the guarded checkout refuses" 1 "$out" "is not the guarded checkout"
out=$(run "$d" false "github:rh7/dotfiles/some-branch#host")
expect "--flake remote ref refuses" 1 "$out" "is not the guarded checkout"
# Relative sources resolve from the checkout (where rebuild.sh runs nix), not
# from the caller's cwd: `..` typed inside $d/sub means $d to the caller but
# the checkout's PARENT to nix.
mkdir -p "$d/sub"
out=$(cd "$d/sub" && run "$d" false "..#host")
expect "--flake relative path is resolved from the checkout, not the cwd" 1 "$out" "is not the guarded checkout"
out=$(cd "$TEST_ROOT" && run "$d" false ".#host")
expect "--flake '.' means the checkout" 0 "$out"

echo ""
echo "checkout guard — --allow-unmerged proceeds, loudly"

fresh; git -C "$d" checkout -qb feature; echo wip >> "$d/flake.nix"
out=$(run "$d" true)
expect "--allow-unmerged on a dirty feature branch proceeds" 0 "$out" \
  "--allow-unmerged" "UNMERGED config" "drift audit"

fresh; git -C "$d" remote set-url origin "$TEST_ROOT/does-not-exist.git"
out=$(run "$d" true)
expect "--allow-unmerged offline proceeds" 0 "$out" "UNMERGED config"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
