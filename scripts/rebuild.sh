#!/usr/bin/env bash
# Safe rebuild wrapper — build, preview changes, then apply.
#
# Usage:
#   rebuild.sh              # interactive: build → diff → confirm → switch
#   rebuild.sh --yes        # auto-confirm (for cron/CI)
#   rebuild.sh --build-only # just build, don't switch
#
# This script avoids blind sudo by showing exactly what will change
# before asking for root confirmation.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
HOSTNAME=$(hostname -s)
AUTO_CONFIRM=false
BUILD_ONLY=false
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

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        AUTO_CONFIRM=true; shift ;;
    --build-only)    BUILD_ONLY=true; shift ;;
    --flake)         FLAKE_REF="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: rebuild.sh [--yes] [--build-only] [--flake REF]"
      echo ""
      echo "  --yes, -y      Auto-confirm (skip interactive approval)"
      echo "  --build-only   Build only, don't activate"
      echo "  --flake REF    Override flake reference (default: ~/dotfiles#\$HOSTNAME)"
      exit 0
      ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

OS=$(uname -s)

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
  rm -f "$audit_log"
  risky=${risky:-0}
  benign=${benign:-0}

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
        info "Drift is in the safe direction ($benign declared item(s) pending) — proceeding."
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

# ── Step 7: Clean up ──
rm -f result

echo -e "${GREEN}${BOLD}Done.${NC} Run 'darwin-rebuild list' to see available generations."
echo ""
