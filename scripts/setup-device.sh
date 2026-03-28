#!/usr/bin/env bash
# Full device setup — run this on any machine after cloning dotfiles.
# Handles: nix rebuild, secrets setup, config service registration.
#
# Usage:
#   ./scripts/setup-device.sh              # auto-detect hostname
#   ./scripts/setup-device.sh mac-studio   # explicit hostname

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTNAME="${1:-$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')}"
OS="$(uname -s)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "=== Device Setup: $HOSTNAME ($OS) ==="
echo ""

# ── 1. Pull latest dotfiles ─────────────────────────────────────────────
info "Pulling latest dotfiles..."
git -C "$DOTFILES_DIR" pull --ff-only 2>/dev/null || warn "Pull failed (offline or conflicts)"
ok "Dotfiles up to date"

# ── 2. Update flake inputs ──────────────────────────────────────────────
read -rp "Update flake inputs? (slow, pulls latest nixpkgs) [y/N] " choice
case "$choice" in
  [yY]*)
    info "Updating flake..."
    nix flake update "$DOTFILES_DIR"
    ok "Flake updated"
    ;;
  *) info "Skipping flake update" ;;
esac

# ── 3. Rebuild system ───────────────────────────────────────────────────
info "Rebuilding for $HOSTNAME..."
case "$OS" in
  Darwin)
    sudo darwin-rebuild switch --flake "$DOTFILES_DIR#$HOSTNAME"
    ;;
  Linux)
    if command -v nixos-rebuild &>/dev/null; then
      sudo nixos-rebuild switch --flake "$DOTFILES_DIR#$HOSTNAME"
    else
      home-manager switch --flake "$DOTFILES_DIR#$(whoami)@$HOSTNAME"
    fi
    ;;
esac
ok "System rebuilt"

# ── 4. Setup secrets ────────────────────────────────────────────────────
echo ""
read -rp "Setup age key and secrets? [Y/n] " choice
case "$choice" in
  [nN]*) info "Skipping secrets" ;;
  *) bash "$DOTFILES_DIR/scripts/setup-secrets.sh" ;;
esac

# ── 5. Register with config service (if reachable) ──────────────────────
CONFIG_SERVER="${CONFIG_SERVER:-config.tailnet.ts.net}"
if curl -sf "http://localhost:3456/api/health" --max-time 2 &>/dev/null; then
  CONFIG_URL="http://localhost:3456"
elif curl -sf "https://${CONFIG_SERVER}/api/health" --max-time 5 &>/dev/null; then
  CONFIG_URL="https://${CONFIG_SERVER}"
else
  CONFIG_URL=""
fi

if [[ -n "$CONFIG_URL" ]]; then
  info "Registering with config service..."
  AGE_PUB=$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2>/dev/null || echo "")
  curl -sf -X POST "${CONFIG_URL}/api/devices/register" \
    -H "Content-Type: application/json" \
    -d "{
      \"hostname\": \"$HOSTNAME\",
      \"os\": \"$OS\",
      \"arch\": \"$(uname -m)\",
      \"role\": \"workstation\",
      \"tailscale_ip\": \"$(tailscale ip -4 2>/dev/null || echo '')\",
      \"age_public_key\": \"$AGE_PUB\",
      \"nix_version\": \"$(nix --version 2>/dev/null || echo '')\"
    }" --max-time 5 >/dev/null && ok "Registered with config service" \
    || warn "Registration failed (non-fatal)"
else
  info "Config service not reachable — skipping registration"
fi

# ── Done ─────────────────────────────────────────────────────────────────
echo ""
echo "=== $HOSTNAME setup complete ==="
echo ""
echo "  Rebuild anytime:    nrs"
echo "  Edit secrets:       sops ~/dotfiles/secrets/secrets.yaml"
echo "  Open dotfiles:      dots"
echo ""
