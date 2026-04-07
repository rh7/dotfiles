#!/usr/bin/env bash
# Uninstall Nix (Determinate or official) cleanly.
# After this, reboot and run: curl -fsSL config.rh7labs.com/setup | bash
#
# Usage: curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/uninstall-nix.sh | bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo ""
echo -e "${BOLD}━━━ Nix Uninstall ━━━${NC}"
echo ""

# ── Check if Nix is installed ──
if ! command -v nix &>/dev/null && [[ ! -d /nix ]]; then
  ok "Nix is not installed. Nothing to do."
  exit 0
fi

# ── Detect variant ──
VARIANT="official"
if nix --version 2>/dev/null | grep -qi determinate; then
  VARIANT="determinate"
  warn "Detected: Determinate Nix (proprietary fork)"
else
  info "Detected: $(nix --version 2>/dev/null || echo 'Nix (version unknown)')"
fi

# ── Step 1: Remove nix-darwin if present ──
if [[ -e /run/current-system ]] || [[ -e /nix/var/nix/profiles/system ]] || \
   [[ -e /Library/LaunchDaemons/org.nixos.activate-system.plist ]] || [[ -d /etc/static ]]; then
  info "Removing nix-darwin system profile and plists..."
  sudo nix-env -e darwin-system --profile /nix/var/nix/profiles/system 2>/dev/null || true
  sudo rm -f /run/current-system
  sudo rm -rf /nix/var/nix/profiles/system*
  sudo rm -f /Library/LaunchDaemons/org.nixos.activate-system.plist
  sudo rm -f /Library/LaunchDaemons/org.nixos.sops-install-secrets.plist
  sudo rm -rf /etc/static
  sudo rm -rf /etc/profiles
  sudo rm -f /etc/bashrc.before-nix-darwin /etc/zprofile.before-nix-darwin
  sudo rm -f /etc/zshenv.before-nix-darwin /etc/zshrc.before-nix-darwin
  ok "nix-darwin removed"
else
  ok "No nix-darwin installation found"
fi

# ── Step 2: Uninstall Nix ──
if [[ -x /nix/nix-installer ]]; then
  info "Uninstalling Nix via nix-installer..."
  /nix/nix-installer uninstall
elif command -v nix-installer &>/dev/null; then
  info "Uninstalling Nix via nix-installer..."
  nix-installer uninstall
else
  warn "No nix-installer found. You may need to uninstall manually."
  warn "See: https://nix.dev/manual/nix/stable/installation/uninstall"
  exit 1
fi

# ── Step 3: Clean up remnants ──
info "Cleaning up remnants..."
sudo rm -f /Library/LaunchDaemons/systems.determinate.nix-installer.nix-hook.plist 2>/dev/null || true
sudo rm -f /nix/nix-installer 2>/dev/null || true
ok "Remnants cleaned"

# ── Step 4: Verify ──
echo ""
echo -e "${BOLD}━━━ Verification ━━━${NC}"
echo ""

CLEAN=true
if command -v nix &>/dev/null; then
  warn "nix still in PATH: $(which nix)"
  CLEAN=false
fi
if ls /Library/LaunchDaemons/*determinate* 2>/dev/null; then
  warn "Determinate plists still present"
  CLEAN=false
fi
if [[ -x /nix/nix-installer ]]; then
  warn "nix-installer binary still present"
  CLEAN=false
fi

if $CLEAN; then
  ok "Nix fully uninstalled"
else
  warn "Some remnants remain — they'll be gone after reboot"
fi

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Reboot:  sudo reboot"
echo "  2. Reinstall:  curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/setup.sh | bash"
echo ""
