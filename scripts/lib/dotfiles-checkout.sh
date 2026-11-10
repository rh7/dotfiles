# shellcheck shell=bash
#
# Shared helper: is the dotfiles checkout the MERGED config (origin/main)?
#
# sync_dotfiles_checkout ALLOW_UNMERGED ESCAPE_HINT [FLAKE_REF]
#   Fetches origin, fast-forwards `main` when that is provably safe, then
#   returns 0 only if the checkout at $DOTFILES_DIR is on branch `main`, has no
#   uncommitted changes to tracked files, and HEAD == origin/main. If FLAKE_REF
#   is given, its source must also be that checkout (a `--flake` pointing
#   elsewhere would activate a tree this guard never looked at).
#   Anything else prints what is wrong and how to fix it — ending with
#   ESCAPE_HINT, the caller's way to bypass — and returns 1. ALLOW_UNMERGED=true
#   instead prints a loud warning and returns 0.
#
# Also reads the caller's DOTFILES_DIR, info/ok/warn/err helpers and BOLD/NC.
#
# Sourced by scripts/rebuild.sh and scripts/device (standalone home-manager).
#
# WHY (rh7/rh-device-management#312): rebuild.sh used to `git pull` only on a
# clean tree ("Dotfiles have local changes — skipping pull") and would happily
# pull a FEATURE branch if one was checked out, then build and activate
# whatever was on disk. The Studio sat on a stale feature branch, 8 commits
# behind main with a dirty tree — and because the drift audit compares the
# machine against that same checkout, every signal reported it compliant.
# Same guard as rh-device-management's service.sh deploy (#164): every
# successful run must genuinely mean "this machine runs origin/main".
#
# Fast-forward is attempted only when it is provably safe (on main, clean,
# strictly behind). AHEAD needs its own check: `merge --ff-only` says "Already
# up to date" (exit 0) when origin/main is an ancestor of HEAD, so unpushed or
# unmerged commits would sail through a merge-only guard.
#
# Every git call's failure is a refusal, never an empty answer: callers run
# this as `sync_dotfiles_checkout || exit 1`, which disables errexit inside
# it, so a failed `git status` would otherwise read as "clean".
#
# Untracked files are ignored: flakes only see tracked files, and `result`
# symlinks etc. are routine.

sync_dotfiles_checkout() {
  local dir="$DOTFILES_DIR" allow="$1" escape_hint="$2" flake_ref="${3:-}"
  local branch="" head="" remote="" dirty="" n src
  local problems=() fixes=()

  info "Syncing dotfiles with origin/main..."
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    problems+=("$dir is not a git checkout — cannot prove it matches origin/main")
    fixes+=("clone it: git clone https://github.com/rh7/dotfiles.git \"$dir\"")
  elif ! git -C "$dir" fetch --quiet origin 2>&1 \
       || ! remote=$(git -C "$dir" rev-parse --verify --quiet 'origin/main^{commit}'); then
    problems+=("could not fetch origin/main (offline, or auth failure) — cannot prove the checkout is the merged config")
    fixes+=("retry when online (offline: see the bypass below)")
  elif ! head=$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}') \
       || ! dirty=$(git -C "$dir" status --porcelain --untracked-files=no); then
    problems+=("could not read HEAD / working-tree status — cannot prove the checkout is clean")
    fixes+=("inspect: git -C \"$dir\" status")
  else
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""

    if [[ "$branch" == main && -z "$dirty" && "$head" != "$remote" ]] \
       && git -C "$dir" merge-base --is-ancestor "$head" "$remote"; then
      if git -C "$dir" merge --ff-only --quiet "$remote" \
         && head=$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}'); then
        ok "Fast-forwarded main → ${remote:0:8}"
      else
        warn "Fast-forward to origin/main failed"
      fi
    fi

    if [[ -z "$branch" ]]; then
      problems+=("detached HEAD at ${head:0:8}, not branch main")
      fixes+=("git -C \"$dir\" checkout main")
    elif [[ "$branch" != main ]]; then
      problems+=("on branch '$branch', not main — unmerged config")
      fixes+=("merge it via PR, then: git -C \"$dir\" checkout main")
    fi
    if [[ -n "$dirty" ]]; then
      problems+=("uncommitted changes to tracked files:")
      while IFS= read -r n; do problems+=("    $n"); done <<<"$dirty"
      fixes+=("commit them on a branch and open a PR, or set them aside: git -C \"$dir\" stash")
    fi
    if [[ "$head" != "$remote" ]]; then
      if git -C "$dir" merge-base --is-ancestor "$remote" "$head"; then
        n=$(git -C "$dir" rev-list --count "$remote..$head") || n="?"
        problems+=("HEAD ${head:0:8} is AHEAD of origin/main ${remote:0:8} by $n commit(s) — not merged")
      elif git -C "$dir" merge-base --is-ancestor "$head" "$remote"; then
        n=$(git -C "$dir" rev-list --count "$head..$remote") || n="?"
        problems+=("HEAD ${head:0:8} is $n commit(s) BEHIND origin/main ${remote:0:8} and could not be fast-forwarded")
      else
        problems+=("HEAD ${head:0:8} has DIVERGED from origin/main ${remote:0:8}")
      fi
      fixes+=("push any commits you need to a branch + PR, then: git -C \"$dir\" checkout main && git -C \"$dir\" reset --hard origin/main")
    fi
  fi

  # The guarded checkout must be the one that gets built. `--flake` may still
  # select another host's attribute from it (`~/dotfiles#other-host`).
  if [[ -n "$flake_ref" ]]; then
    src="${flake_ref%%#*}"
    src="${src#path:}"
    if [[ -z "$src" || ! -d "$src" ]] \
       || [[ "$(cd -P "$src" 2>/dev/null && pwd)" != "$(cd -P "$dir" 2>/dev/null && pwd)" ]]; then
      problems+=("--flake '$flake_ref' is not the guarded checkout $dir")
      fixes+=("build from the checkout: --flake \"$dir#<host>\" (or drop --flake)")
    fi
  fi

  if [[ ${#problems[@]} -eq 0 ]]; then
    ok "Dotfiles at origin/main ${remote:0:8} (clean)"
    return 0
  fi

  local p
  if [[ "$allow" == true ]]; then
    warn "${BOLD}--allow-unmerged: building the checkout AS IT IS ON DISK.${NC}"
    for p in "${problems[@]}"; do warn "  $p"; done
    warn "This machine will run UNMERGED config, and the drift audit will"
    warn "compare against that same checkout — it cannot flag the difference."
    warn "Re-run without --allow-unmerged from clean main once merged."
    echo ""
    return 0
  fi

  err "Refusing to build: the dotfiles checkout is not the merged config (origin/main)."
  for p in "${problems[@]}"; do err "  $p"; done
  err "Fix:"
  for p in "${fixes[@]}"; do err "  $p"; done
  err "To deliberately build/activate it anyway (testing a branch, offline):"
  err "  $escape_hint"
  return 1
}
