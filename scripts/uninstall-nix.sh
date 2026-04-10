#!/usr/bin/env bash
# Uninstall Nix (Determinate or official) cleanly.
# After this, reboot and run: curl -fsSL config.rh7labs.com/setup | bash
#
# Usage: curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/uninstall-nix.sh | bash
#
# Flags:
#   --force-nuclear   Skip the standard uninstaller and go straight to manual cleanup

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

FORCE_NUCLEAR=false
for arg in "$@"; do
  case "$arg" in
    --force-nuclear) FORCE_NUCLEAR=true ;;
  esac
done

# Manual nuclear cleanup. Used as a fallback when nix-installer refuses to
# uninstall (Determinate v3.17+ checks for darwin-rebuild in the Nix store
# and fails repeatedly even after artifacts are removed). Proven on m5-air
# 2026-04-07. Reboot required afterward.
nuclear_cleanup() {
  local os
  os="$(uname -s)"
  warn "Performing manual nuclear cleanup. This will:"
  warn "  - Stop and remove nix-daemon launchd services"
  warn "  - Delete /nix and the Nix APFS volume"
  warn "  - Remove /etc/nix, /etc/static, /etc/profiles, /etc/*.before-nix-darwin"
  warn "  - Delete _nixbld1..32 users and the nixbld group"
  warn "  - Require a reboot"
  echo ""
  if [[ -t 0 ]]; then
    echo -en "${BOLD}  Continue with nuclear cleanup? [y/N] ${NC}"
    read -r confirm < /dev/tty
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "Cancelled."; exit 0; }
  else
    warn "Non-interactive run — proceeding without confirmation"
  fi

  info "Stopping nix-daemon launchd services..."
  sudo launchctl bootout system/systems.determinate.nix-daemon 2>/dev/null || true
  sudo launchctl bootout system/org.nixos.nix-daemon 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/*nix* /Library/LaunchDaemons/*determinate* 2>/dev/null || true

  if [[ "$os" == "Darwin" ]]; then
    info "Removing Nix APFS volume..."
    sudo diskutil apfs deleteVolume /nix 2>/dev/null || true
  fi

  info "Removing /etc Nix artifacts..."
  sudo rm -rf /etc/nix /etc/static /etc/profiles 2>/dev/null || true
  sudo rm -f /etc/*.before-nix-darwin 2>/dev/null || true

  info "Removing nixbld users and group..."
  for i in $(seq 1 32); do
    sudo dscl . -delete /Users/_nixbld$i 2>/dev/null || true
  done
  sudo dscl . -delete /Groups/nixbld 2>/dev/null || true

  info "Removing /nix..."
  sudo rm -rf /nix 2>/dev/null || true

  ok "Nuclear cleanup complete. Reboot required: sudo reboot"
}

echo ""
echo -e "${BOLD}━━━ Nix Uninstall ━━━${NC}"
echo ""

# ── Check if Nix is installed ──
if ! command -v nix &>/dev/null && [[ ! -d /nix ]]; then
  ok "Nix is not installed. Nothing to do."
  exit 0
fi

# ── Force-nuclear shortcut ──
if $FORCE_NUCLEAR; then
  warn "--force-nuclear specified — skipping nix-installer uninstall"
  nuclear_cleanup
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  1. Reboot:  sudo reboot"
  echo "  2. Reinstall:  curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/setup.sh | bash"
  echo ""
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
INSTALLER_OK=false
if [[ -x /nix/nix-installer ]]; then
  info "Uninstalling Nix via /nix/nix-installer..."
  if /nix/nix-installer uninstall; then
    INSTALLER_OK=true
  else
    warn "/nix/nix-installer uninstall failed (Determinate v3.17+ stubbornly detects nix-darwin)"
  fi
elif command -v nix-installer &>/dev/null; then
  info "Uninstalling Nix via nix-installer..."
  if nix-installer uninstall; then
    INSTALLER_OK=true
  else
    warn "nix-installer uninstall failed"
  fi
else
  warn "No nix-installer found."
fi

if ! $INSTALLER_OK; then
  echo ""
  warn "Standard uninstaller could not complete. Falling back to nuclear cleanup."
  echo ""
  nuclear_cleanup
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
