#!/usr/bin/env bash
# Safe rebuild wrapper — build, preview changes, then apply.
#
# Usage:
#   rebuild.sh              # interactive: build → diff → confirm → switch
#   rebuild.sh --yes        # auto-confirm (still needs you to authenticate)
#   rebuild.sh --build-only # just build, don't switch
#
# This script avoids blind sudo by showing exactly what will change
# before asking for root confirmation.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
HOSTNAME=$(hostname -s)
AUTO_CONFIRM=false
BUILD_ONLY=false
PLAN_ONLY=false
FORCE_MAS=false
FLAKE_REF="${DOTFILES_DIR}#${HOSTNAME}"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Cleanup ──
# ONE EXIT trap for the whole script. bash replaces a trap rather than adding to
# it, so a second `trap ... EXIT` further down would silently disable this one —
# every cleanup must be registered through here.
PLAN_TMP=""             # Homebrew plan scratch dir (step 4b)
MAS_TMP=""              # App Store scratch dir (declared_outdated_mas)
SUDO_KEEPALIVE_PID=""   # sudo timestamp refresher (step 5b)
SUDO_TOUCHED=false      # true once this script refreshes the sudo timestamp
cleanup() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$PLAN_TMP" && -d "$PLAN_TMP" ]]; then
    rm -rf "$PLAN_TMP"
  fi
  if [[ -n "$MAS_TMP" && -d "$MAS_TMP" ]]; then
    rm -rf "$MAS_TMP"
  fi
  # Close the sudo window immediately rather than letting the 5-minute default
  # lapse.
  #
  # This revokes even a timestamp that already existed when the script started.
  # That is deliberate: the keep-alive below runs `sudo -n -v` every 60s, so by
  # the end of a long rebuild ANY timestamp — pre-existing or not — has been
  # repeatedly renewed by this script and would outlive the run. An earlier
  # version skipped `sudo -k` for pre-existing timestamps on the theory that
  # they "belonged to something else"; the result was that it extended a
  # credential it declined to clean up, leaving a fresh global window open for
  # unrelated processes. Renewing it makes it ours to revoke.
  #
  # Cost of being wrong in this direction: an unrelated sudo elsewhere prompts
  # once more than it would have. That is the right way to be wrong.
  if $SUDO_TOUCHED; then
    sudo -k 2>/dev/null || true
  fi
}
# INT/TERM/HUP as well as EXIT: a Ctrl-C partway through a rebuild must still
# revoke the sudo window and remove the scratch dir. (SIGKILL cannot be caught —
# a `kill -9` leaves the timestamp to expire on its own 5-minute timeout.)
#
# The signal handlers only `exit`; they must NOT call cleanup themselves, since
# exiting fires the EXIT trap which does. Calling it in both places ran the
# whole cleanup — sudo -k, rm -rf, kill — twice per interrupt.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        AUTO_CONFIRM=true; shift ;;
    --build-only)    BUILD_ONLY=true; shift ;;
    --plan-only)     PLAN_ONLY=true; shift ;;
    --upgrade-mas)   FORCE_MAS=true; shift ;;
    --flake)         FLAKE_REF="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: rebuild.sh [--yes] [--build-only|--plan-only] [--flake REF]"
      echo ""
      echo "  --yes, -y      Auto-confirm (skip interactive approval). Skips"
      echo "                 App Store upgrades unless --upgrade-mas is given,"
      echo "                 since those must not run unattended."
      echo "  --upgrade-mas  Upgrade declared App Store apps even with --yes."
      echo "                 Only pass this when you are at the machine."
      echo "  --build-only   Build only, don't activate"
      echo "  --plan-only    Show the Homebrew upgrade plan only — no build, no"
      echo "                 activation, no upgrades, no root. Does refresh brew"
      echo "                 metadata (network + Homebrew repo state)."
      echo "  --flake REF    Override flake reference (default: ~/dotfiles#\$HOSTNAME)"
      echo ""
      echo "Logs: every run is mirrored to \$REBUILD_LOG_DIR (default:"
      echo "  ~/.local/state/dotfiles/rebuild/) as <host>-<timestamp>.log."
      echo "  Last 20 per host retained."
      exit 0
      ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# Rejected rather than silently resolved: --plan-only short-circuits before the
# build, so passing both would quietly ignore --build-only.
if $BUILD_ONLY && $PLAN_ONLY; then
  err "--build-only and --plan-only are mutually exclusive"
  exit 1
fi

# ── Log file ──
# Mirror full output to ~/.local/state/dotfiles/rebuild/ so failures from brew
# bundle / activation can be grepped after the fact. Keeps last 20 per host.
LOG_DIR="${REBUILD_LOG_DIR:-$HOME/.local/state/dotfiles/rebuild}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${HOSTNAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
while IFS= read -r _old_log; do rm -f "$_old_log"; done < <(
  ls -1t "$LOG_DIR/${HOSTNAME}-"*.log 2>/dev/null | tail -n +21
)

OS=$(uname -s)

# Idempotent so both the plan and the post-activation MAS step can call it.
# Checked explicitly so a missing helper reports itself rather than dying on an
# opaque "source: no such file" from `set -e`.
DECLARED_LIB_SOURCED=false
ensure_declared_lib() {
  if $DECLARED_LIB_SOURCED; then return 0; fi
  local lib="$DOTFILES_DIR/scripts/lib/declared-packages.sh"
  if [[ ! -r "$lib" ]]; then
    err "Helper not found at $lib"
    exit 1
  fi
  # shellcheck source=lib/declared-packages.sh
  source "$lib"
  DECLARED_LIB_SOURCED=true
}

# ── Declared Mac App Store apps that are outdated ────────────────────────────
# Prints one id per line. Returns nonzero if state could not be determined, so
# callers can distinguish "nothing to upgrade" from "could not tell".
#
# WHY THIS LIVES IN rebuild.sh AND NOT THE WEEKLY AGENT:
# `mas_install` in postActivation only installs apps that are MISSING — it never
# upgrades — so declared App Store apps were installed once and then never
# updated again. The obvious fix was to put `mas upgrade` in the weekly
# LaunchAgent, and that is WRONG: mas 7.0.0 spawns /usr/bin/sudo internally for
# update operations (verified — `/usr/bin/sudo` and "Requires root privileges to
# install apps" are both embedded in the installed Mach-O). Running it
# unattended while rebuild.sh holds a user-global sudo timestamp open would let
# it silently consume that credential, which is exactly why cask upgrades were
# removed from that agent. One app upgrading without a prompt does not prove
# otherwise — the capability is what matters, not a single observation.
#
# Here the situation is different in the way that counts: a human ran this,
# saw the plan, and authenticated deliberately. Same treatment as casks.
# Result is returned via the MAS_OUTDATED global, NOT stdout. That is not
# stylistic: callers used `x=$(declared_outdated_mas)`, which runs the function
# in a SUBSHELL, so its `MAS_TMP=` assignment never reached the parent and the
# shared EXIT trap could not clean the directory after an early return. Setting
# a global keeps the function in the parent shell, where the trap works.
MAS_OUTDATED=""
declared_outdated_mas() {
  MAS_OUTDATED=""
  # Indirected so the "mas missing" branch is reachable in tests; `mas` lives in
  # the same dir as `brew`, so it cannot be hidden via PATH without also
  # breaking brew.
  local mas_bin="${REBUILD_MAS_BIN:-mas}"
  if ! command -v "$mas_bin" &>/dev/null; then
    return 2   # distinct from "none outdated"; caller reports it
  fi
  ensure_declared_lib

  # This function is called twice (plan, then post-activation). If the first
  # call failed it deliberately left its directory for the EXIT trap — so clear
  # it BEFORE allocating another, or the second assignment orphans the first
  # beyond the trap's reach.
  if [[ -n "$MAS_TMP" && -d "$MAS_TMP" ]]; then
    rm -rf "$MAS_TMP"
  fi
  MAS_TMP=$(mktemp -d -t rebuild-mas.XXXXXX) || return 1

  if ! "$mas_bin" outdated 2>/dev/null | awk '{print $1}' >"$MAS_TMP/outdated"; then
    return 1   # dir left for the EXIT trap, which can now see it
  fi
  if ! declared_mas_ids "$FLAKE_REF" >"$MAS_TMP/declared"; then
    return 1
  fi

  # Status captured explicitly: ending on `rm` would have returned the CLEANUP's
  # exit code, so a failed intersection would have looked like success.
  local rc=0
  MAS_OUTDATED=$(intersect_lines "$MAS_TMP/outdated" "$MAS_TMP/declared") || rc=1
  rm -rf "$MAS_TMP"; MAS_TMP=""
  return $rc
}

# ── Step 4b: Homebrew plan ──
# A function, not an inline block, so `--plan-only` can run it without building
# or activating — which also makes its failure paths testable. It needs no root
# and upgrades nothing, but it is NOT read-only: `brew update` below mutates
# Homebrew's local repo/metadata and hits the network.
#
# `homebrew.onActivation.upgrade = true` upgrades outdated packages during
# activation. That is the bulk of a long rebuild and the part that used to
# happen invisibly behind context-free Touch ID prompts, so surface it BEFORE
# asking for authentication.
#
# CRUCIALLY: `brew bundle` only touches what the Brewfile DECLARES, while
# `brew outdated` lists everything installed. Reporting raw `brew outdated`
# here promised upgrades that activation then did not perform (e.g. manually
# installed `bash`/`session` were listed, then left untouched). Intersect with
# the flake's declared set so this preview states what will actually happen,
# and report the undeclared remainder separately as drift.
#
# `brew update` refreshes metadata and needs no root. Activation would run it
# anyway (autoUpdate = true), so doing it here costs nothing and makes the
# preview accurate rather than stale.
homebrew_plan() {
  if [[ "$OS" != "Darwin" ]] || ! command -v brew &>/dev/null; then
    return 0
  fi
  echo -e "${BOLD}━━━ Homebrew ━━━${NC}"
  echo ""
  info "Refreshing Homebrew metadata..."
  brew update --quiet &>/dev/null || warn "brew update failed (preview may be stale)"

  ensure_declared_lib

  # PLAN_TMP is cleaned by the shared EXIT trap, not an inline rm, so an
  # interrupt between here and the end of this block cannot leak it.
  PLAN_TMP=$(mktemp -d -t rebuild-plan.XXXXXX)

  # Inventory status is checked, never assumed. A failed `brew outdated` that
  # was treated as "nothing outdated" would silently print a clean plan.
  plan_known=true
  if ! brew outdated --formula --quiet >"$PLAN_TMP/outdated_formulae" 2>/dev/null; then
    warn "'brew outdated --formula' failed — formula plan unavailable"
    plan_known=false
  fi
  if ! brew outdated --cask --quiet >"$PLAN_TMP/outdated_casks" 2>/dev/null; then
    warn "'brew outdated --cask' failed — cask plan unavailable"
    plan_known=false
  fi

  # Per-category checks. A failure in ONE category must not read as "nothing
  # declared there" — that would relabel every package of that kind as drift.
  if $plan_known; then
    if ! declared_brew_names brews "$FLAKE_REF" >"$PLAN_TMP/declared_formulae"; then
      warn "Could not evaluate homebrew.brews for $FLAKE_REF"
      plan_known=false
    elif ! declared_brew_names casks "$FLAKE_REF" >"$PLAN_TMP/declared_casks"; then
      warn "Could not evaluate homebrew.casks for $FLAKE_REF"
      plan_known=false
    fi
  fi

  if ! $plan_known; then
    # Say nothing about what activation WILL do — at this point the script has
    # no evidence either way. Claiming the raw outdated list here is what the
    # original bug did, and doing it under a warning would not make it true.
    warn "Homebrew activation plan unavailable — showing raw outdated inventory:"
    if [[ -s "$PLAN_TMP/outdated_formulae" ]]; then
      echo "    outdated formulae: $(tr '\n' ' ' <"$PLAN_TMP/outdated_formulae")"
    fi
    if [[ -s "$PLAN_TMP/outdated_casks" ]]; then
      echo "    outdated casks:    $(tr '\n' ' ' <"$PLAN_TMP/outdated_casks")"
    fi
    echo "    (some of these may or may not be upgraded by activation)"
  else
    will_formulae=$(intersect_lines "$PLAN_TMP/outdated_formulae" "$PLAN_TMP/declared_formulae" | tr '\n' ' ' | sed 's/ $//')
    will_casks=$(intersect_lines "$PLAN_TMP/outdated_casks" "$PLAN_TMP/declared_casks" | tr '\n' ' ' | sed 's/ $//')
    skip_formulae=$(subtract_lines "$PLAN_TMP/outdated_formulae" "$PLAN_TMP/declared_formulae" | tr '\n' ' ' | sed 's/ $//')
    skip_casks=$(subtract_lines "$PLAN_TMP/outdated_casks" "$PLAN_TMP/declared_casks" | tr '\n' ' ' | sed 's/ $//')

    n_will=$(wc -w <<<"$will_formulae $will_casks" | tr -d ' ')
    n_skip=$(wc -w <<<"$skip_formulae $skip_casks" | tr -d ' ')

    if [[ "$n_will" -eq 0 ]]; then
      ok "No declared Homebrew packages need upgrading"
    else
      warn "Activation will UPGRADE $n_will declared package(s):"
      # if/fi, not `[[ ]] && echo` — under `set -e` a false test would abort here.
      if [[ -n "$will_formulae" ]]; then echo "    formulae: $will_formulae"; fi
      if [[ -n "$will_casks" ]]; then echo "    casks:    $will_casks"; fi
      echo "    (Homebrew may also upgrade undeclared dependencies of these.)"
    fi

    # Not a warning: undeclared packages are yours to manage by hand, and
    # cleanup = "none" means activation preserves them. Surfaced so an outdated
    # package that never seems to update has a visible explanation.
    if [[ "$n_skip" -gt 0 ]]; then
      echo ""
      info "$n_skip outdated package(s) are NOT declared — not upgrade targets:"
      if [[ -n "$skip_formulae" ]]; then echo "    formulae: $skip_formulae"; fi
      if [[ -n "$skip_casks" ]]; then echo "    casks:    $skip_casks"; fi
      echo "    (upgrade by hand with 'brew upgrade <name>', or declare them in a profile)"
    fi
  fi

  # Mac App Store, shown in the same breath as Homebrew so the plan covers
  # everything this run will change before you authenticate.
  # `if declared_outdated_mas; then` — NOT `x=$(...)`. Two reasons: under
  # `set -e` a failing command substitution in a bare assignment aborts the
  # script (a missing `mas` silently killed the whole run), and command
  # substitution would put the function in a subshell where its temp-dir
  # bookkeeping cannot reach the EXIT trap.
  local mas_ids rc
  if declared_outdated_mas; then rc=0; else rc=$?; fi
  mas_ids="$MAS_OUTDATED"
  case $rc in
    0)
      if [[ -n "$mas_ids" ]]; then
        # Describe what will ACTUALLY happen. The gate below skips App Store
        # upgrades under --yes without --upgrade-mas, so promising an upgrade
        # here would be the same class of lie as the original Homebrew preview.
        if $AUTO_CONFIRM && ! $FORCE_MAS; then
          info "$(wc -w <<<"$mas_ids" | tr -d ' ') declared App Store app(s) outdated — will be SKIPPED:"
          echo "    mas: $(tr '\n' ' ' <<<"$mas_ids" | sed 's/ $//')"
          echo "    (--yes without --upgrade-mas; run interactively to upgrade)"
        else
          warn "Will also UPGRADE $(wc -w <<<"$mas_ids" | tr -d ' ') declared App Store app(s):"
          echo "    mas: $(tr '\n' ' ' <<<"$mas_ids" | sed 's/ $//')"
        fi
      else
        ok "No declared App Store apps need upgrading"
      fi
      ;;
    2) warn "mas not found — App Store apps not checked" ;;
    *) warn "Could not determine App Store state — apps not checked" ;;
  esac
  echo ""
}

echo ""
echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│       Safe Nix Rebuild                   │${NC}"
echo -e "${BOLD}${CYAN}│       $HOSTNAME ($OS)${NC}"
echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}"
echo ""

# ── Step 1: Pull latest dotfiles ──
if [[ -d "$DOTFILES_DIR/.git" ]]; then
  info "Pulling latest dotfiles..."
  cd "$DOTFILES_DIR"
  if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
    git pull --ff-only 2>/dev/null && ok "Dotfiles updated" || warn "Pull failed (non-fatal)"
  else
    warn "Dotfiles have local changes — skipping pull"
  fi
fi

# ── Step 2: Audit drift ──
# Ensure Nix is in PATH (audit needs `nix eval`, build needs it too).
if ! command -v nix &>/dev/null; then
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  else
    err "Nix not found. Install it first: curl -fsSL config.rh7labs.com/setup | bash"
    exit 1
  fi
fi

# ── --plan-only: preview the Homebrew plan and stop ──
# Placed after the nix-in-PATH setup (the plan evaluates the flake) but before
# the drift audit and build, so it stays fast. Nothing below this point runs:
# no build, no activation, no sudo. (The plan itself does refresh Homebrew
# metadata — see homebrew_plan.)
if $PLAN_ONLY; then
  homebrew_plan
  ok "Plan complete (--plan-only). Nothing was built, upgraded, or activated."
  exit 0
fi

# Catch manual changes (dock pins, brew installs, MAS apps, defaults)
# that 'switch' would silently overwrite. Advisory — user decides.
if [[ -x "$DOTFILES_DIR/scripts/audit-config-drift.sh" ]]; then
  info "Auditing local state for manual drift..."
  echo ""
  AUDIT_HOST="${FLAKE_REF##*#}"
  audit_log=$(mktemp -t audit-log.XXXXXX)
  audit_rc=0
  "$DOTFILES_DIR/scripts/audit-config-drift.sh" "$AUDIT_HOST" 2>&1 \
    | tee "$audit_log" || audit_rc=${PIPESTATUS[0]}

  # Parse risky/benign counts from audit's machine-readable summary line.
  risky=$(grep -E "^DRIFT_RESULT:" "$audit_log" | sed -nE 's/.*risky=([0-9]+).*/\1/p')
  benign=$(grep -E "^DRIFT_RESULT:" "$audit_log" | sed -nE 's/.*benign=([0-9]+).*/\1/p')
  informational=$(grep -E "^DRIFT_RESULT:" "$audit_log" | sed -nE 's/.*informational=([0-9]+).*/\1/p')
  rm -f "$audit_log"
  risky=${risky:-0}
  benign=${benign:-0}
  informational=${informational:-0}

  case "$audit_rc" in
    0) : ;;  # no drift
    1) # some drift exists; only prompt when it's risky
      if [[ "$risky" -gt 0 ]]; then
        echo ""
        warn "$risky manual change(s) above would be overwritten by 'switch'."
        warn "Fold them into the flake first if you want to keep them."
        if ! $AUTO_CONFIRM; then
          echo -en "${BOLD}  Continue with rebuild anyway? [y/N] ${NC}"
          read -r drift_confirm < /dev/tty
          if [[ "$drift_confirm" != "y" && "$drift_confirm" != "Y" ]]; then
            info "Cancelled. Edit the flake to capture the drift, then re-run."
            exit 0
          fi
        fi
      else
        info "Drift is non-destructive ($benign declared item(s) pending, $informational informational item(s) preserved) — proceeding."
      fi
      ;;
    *) warn "Audit failed (exit $audit_rc) — proceeding without drift check" ;;
  esac
  echo ""
fi

# ── Step 3: Build (no sudo needed) ──
info "Building configuration (no root required)..."
echo ""

cd "$DOTFILES_DIR"
case "$OS" in
  Darwin)
    # darwin-rebuild may not be in PATH after fresh Nix install — use nix build fallback
    if command -v darwin-rebuild &>/dev/null; then
      if ! darwin-rebuild build --flake "$FLAKE_REF" 2>&1; then
        err "Build failed. Fix the issue and try again."
        exit 1
      fi
    else
      info "darwin-rebuild not in PATH — using nix build..."
      if ! nix build "${DOTFILES_DIR}#darwinConfigurations.${HOSTNAME}.system" --no-link 2>&1; then
        err "Build failed. Fix the issue and try again."
        exit 1
      fi
      # Use the built result's darwin-rebuild for activation
      DARWIN_REBUILD="./result/sw/bin/darwin-rebuild"
    fi
    ;;
  Linux)
    if ! nixos-rebuild build --flake "$FLAKE_REF" 2>&1; then
      err "Build failed. Fix the issue and try again."
      exit 1
    fi
    ;;
esac

ok "Build succeeded"
echo ""

# ── Step 4: Show diff (no sudo needed) ──
CURRENT="/run/current-system"
NEW="./result"

if [[ -e "$CURRENT" ]] && [[ -e "$NEW" ]]; then
  echo -e "${BOLD}━━━ Changes ━━━${NC}"
  echo ""

  if command -v nvd &>/dev/null; then
    nvd diff "$CURRENT" "$NEW"
  else
    # Fallback to built-in nix command
    nix store diff-closures "$CURRENT" "$NEW" 2>/dev/null || \
      warn "Could not diff closures (install nvd for better output)"
  fi

  echo ""
else
  if [[ ! -e "$CURRENT" ]]; then
    warn "No current system profile found (first install?)"
  fi
fi

if $BUILD_ONLY; then
  ok "Build complete (--build-only). Result in ./result"
  exit 0
fi


homebrew_plan

# ── Step 5: Confirm ──
if ! $AUTO_CONFIRM; then
  echo -e "${BOLD}━━━ Activation ━━━${NC}"
  echo ""
  echo "  The changes above will be applied to your system."
  echo "  This requires sudo for: system defaults, launchd services, /etc/ links."
  echo ""
  echo -en "${BOLD}  Apply these changes? [y/N] ${NC}"
  read -r confirm < /dev/tty
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Cancelled. Build result is in ./result for inspection."
    exit 0
  fi
  echo ""
fi

# ── Step 5b: Authenticate ONCE for the whole run ──
# Without this, the prompts arrive one-per-root-requiring-cask from inside
# `brew bundle` (nix-darwin drops root back to the user to run brew), each
# giving no clue what it is for. Authenticating here — after the plan above —
# means the single prompt you get is one you can actually attribute.
#
# Requires `Defaults:<user> timestamp_type=global` to cover brew's children;
# see modules/darwin/sudo-rebuild.nix. Without that module this still works,
# it just may not suppress every downstream prompt.
# Set BEFORE the first sudo call, not after. Setting it afterwards left a race:
# a signal arriving between a successful `sudo -v` and the assignment would run
# cleanup with SUDO_TOUCHED still false, leaving a just-renewed timestamp live.
# Claiming it early is the safe direction — if we die before sudo ever succeeds,
# the worst case is a `sudo -k` that revokes nothing (or costs one extra prompt).
SUDO_TOUCHED=true

if sudo -n true 2>/dev/null; then
  info "sudo already authenticated — no prompt needed"
else
  info "Authenticating once for the entire rebuild (Touch ID)..."
  if ! sudo -v; then
    err "Authentication failed or cancelled — nothing was applied."
    err "Build result is in ./result for inspection."
    exit 1
  fi
fi

# Refresh the timestamp every 60s so a long run (large casks, multi-GB MAS
# downloads) never lapses mid-flight and re-prompts. Dies with this script via
# the EXIT trap, and self-exits if the parent disappears or sudo is revoked.
(
  while kill -0 "$$" 2>/dev/null; do
    sudo -n -v 2>/dev/null || exit 0
    sleep 60
  done
) &
SUDO_KEEPALIVE_PID=$!
ok "Authenticated — you should not be prompted again for this run"
echo ""

# ── Step 6: Activate (requires sudo) ──
# Classify darwin-rebuild exit into success / known-harmless / real failure.
# Captures the output so we can inspect it, then prints a truthful summary.
run_darwin_rebuild() {
  local cmd=("$@")
  local log rc
  log="$(mktemp -t rebuild-log.XXXXXX)"
  set +e
  "${cmd[@]}" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "System updated"
  else
    # Heuristics: real failures we don't want to hide.
    # Note: "Installing X has failed!" is a brew-bundle output line, NOT MAS —
    # it fires for cask install failures (e.g. version-mismatch on adopt).
    local has_brew_fail=false has_mas_fail=false has_nix_fail=false
    grep -qiE 'brew bundle failed|brewfile dependency failed|installing .* has failed' "$log" && has_brew_fail=true
    grep -qiE 'failed to install .* from app store' "$log" && has_mas_fail=true
    grep -qiE 'error: builder for|error: build of' "$log" && has_nix_fail=true

    warn "darwin-rebuild exited with code $rc"
    if $has_mas_fail; then
      err "mas / App Store install failed — check output above for the app name"
      err "Workaround: install the app manually from the App Store, then re-run"
    fi
    if $has_brew_fail; then
      err "brew bundle had failures — not all Homebrew packages installed"
    fi
    if $has_nix_fail; then
      err "Nix build error — check output above"
    fi
    if ! $has_brew_fail && ! $has_mas_fail && ! $has_nix_fail; then
      warn "No known failure pattern detected — likely sops secrets on first build (see #27)"
      warn "Check the output above to be sure"
    fi
  fi
  rm -f "$log"
}

info "Activating configuration..."
case "$OS" in
  Darwin)
    if command -v darwin-rebuild &>/dev/null; then
      run_darwin_rebuild sudo darwin-rebuild switch --flake "$FLAKE_REF"
    elif [[ -n "${DARWIN_REBUILD:-}" ]]; then
      run_darwin_rebuild sudo "$DARWIN_REBUILD" switch --flake "$FLAKE_REF"
    else
      nix build "${DOTFILES_DIR}#darwinConfigurations.${HOSTNAME}.system"
      run_darwin_rebuild sudo ./result/sw/bin/darwin-rebuild switch --flake "${DOTFILES_DIR}#${HOSTNAME}"
    fi
    ;;
  Linux)
    sudo nixos-rebuild switch --flake "$FLAKE_REF" \
      && ok "System updated" \
      || warn "nixos-rebuild exited non-zero — check output above"
    ;;
esac
echo ""

# ── Step 6b: Upgrade declared Mac App Store apps ──
# AFTER activation, deliberately: postActivation's `mas_install` installs any
# app that is MISSING, so running this second means a freshly-declared app is
# installed by activation and then, if the App Store already has a newer
# version, upgraded here in the same run.
#
# Recomputed rather than reusing the plan's list, because activation may have
# just installed apps that change the answer.
#
# See declared_outdated_mas() for why this is here and not in the weekly agent:
# mas invokes /usr/bin/sudo internally, which is acceptable with a human present
# who authenticated for this run, and not acceptable unattended.
# The whole justification for doing this here rather than in the weekly agent is
# that a human is present and authenticated deliberately. `--yes` breaks that
# premise — it exists to skip the prompt — so it must not silently authorise
# privileged App Store upgrades. Skipped by default there, with `--upgrade-mas`
# as an explicit "I am at the machine" override. Without this the safety
# argument would be a comment rather than a property of the script.
if $AUTO_CONFIRM && ! $FORCE_MAS; then
  if [[ "$OS" == "Darwin" ]]; then
    info "Skipping App Store upgrades (--yes without --upgrade-mas)."
    info "  mas can invoke sudo; run interactively, or pass --upgrade-mas."
    echo ""
  fi
elif [[ "$OS" == "Darwin" ]]; then
  mas_rc=0
  declared_outdated_mas || mas_rc=$?
  mas_to_upgrade="$MAS_OUTDATED"
  case $mas_rc in
    0)
      if [[ -n "$mas_to_upgrade" ]]; then
        echo -e "${BOLD}━━━ App Store ━━━${NC}"
        echo ""
        mas_failed=()
        while IFS= read -r app_id; do
          [[ -z "$app_id" ]] && continue
          info "Upgrading App Store app $app_id..."
          if "${REBUILD_MAS_BIN:-mas}" upgrade "$app_id"; then
            ok "$app_id upgraded"
          else
            warn "$app_id failed — update it manually in the App Store"
            mas_failed+=("$app_id")
          fi
        done <<<"$mas_to_upgrade"
        if [[ ${#mas_failed[@]} -gt 0 ]]; then
          warn "App Store apps not upgraded: ${mas_failed[*]}"
        fi
        echo ""
      fi
      ;;
    2) warn "mas not found — declared App Store apps were not upgraded" ;;
    *) warn "Could not determine App Store state — apps were not upgraded" ;;
  esac
fi

# ── Step 7: Clean up ──
rm -f result

echo -e "${GREEN}${BOLD}Done.${NC} Run 'darwin-rebuild list' to see available generations."
echo "Log: $LOG_FILE"
echo ""
