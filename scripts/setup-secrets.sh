#!/usr/bin/env bash
# Setup sops-nix secrets for the current machine.
# Run this once per device after the first nix rebuild.
# Fully automated — no editor required.
#
# Usage: ./scripts/setup-secrets.sh

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOPS_YAML="$DOTFILES_DIR/.sops.yaml"
SECRETS_FILE="$DOTFILES_DIR/secrets/secrets.yaml"
AGE_KEY_DIR="$HOME/.config/sops/age"
AGE_KEY_FILE="$AGE_KEY_DIR/keys.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── 1. Ensure age is available ──────────────────────────────────────────
if ! command -v age-keygen &>/dev/null; then
  info "Installing age..."
  nix profile install nixpkgs#age
  ok "age installed"
fi

# ── 2. Ensure sops is available ─────────────────────────────────────────
if ! command -v sops &>/dev/null; then
  info "Installing sops..."
  nix profile install nixpkgs#sops
  ok "sops installed"
fi

# ── 3. Generate age key (if not exists) ─────────────────────────────────
if [[ -f "$AGE_KEY_FILE" ]]; then
  ok "Age key already exists"
else
  info "Generating age key..."
  mkdir -p "$AGE_KEY_DIR"
  age-keygen -o "$AGE_KEY_FILE" 2>/dev/null
  chmod 600 "$AGE_KEY_FILE"
  ok "Age key generated"
fi

AGE_PUB=$(age-keygen -y "$AGE_KEY_FILE")
HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')

echo ""
info "Device:     $HOSTNAME"
info "Public key: $AGE_PUB"
echo ""

# ── 4. Add key to .sops.yaml automatically ──────────────────────────────
if grep -q "$AGE_PUB" "$SOPS_YAML" 2>/dev/null; then
  ok "Key already in .sops.yaml"
else
  info "Adding key to .sops.yaml..."

  # Replace the placeholder admin key if it's still the default
  if grep -q "age1xxxxxxxxx" "$SOPS_YAML"; then
    sed -i.bak "s|  - &admin age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|  - \&admin $AGE_PUB|" "$SOPS_YAML"
    rm -f "$SOPS_YAML.bak"
    ok "Replaced placeholder admin key with yours"
  else
    # Add as a new device key (after the admin key line)
    sed -i.bak "/^  # ── Per-machine keys/a\\
  - &${HOSTNAME} ${AGE_PUB}" "$SOPS_YAML"
    rm -f "$SOPS_YAML.bak"

    # Also add to creation_rules age list
    sed -i.bak "/^          - \*admin/a\\
          - *${HOSTNAME}" "$SOPS_YAML"
    rm -f "$SOPS_YAML.bak"
    ok "Added $HOSTNAME key to .sops.yaml"
  fi
fi

# ── 5. Encrypt secrets file (if not already encrypted) ──────────────────
if head -1 "$SECRETS_FILE" 2>/dev/null | grep -q "^sops:$\|ENC\[AES256_GCM\|age1"; then
  ok "Secrets file is already encrypted"
else
  info "Encrypting secrets file..."
  sops -e -i "$SECRETS_FILE"
  ok "Secrets encrypted"
fi

# ── 6. Commit changes ──────────────────────────────────────────────────
cd "$DOTFILES_DIR"
if git diff --quiet .sops.yaml secrets/secrets.yaml 2>/dev/null; then
  ok "No changes to commit"
else
  info "Committing sops changes..."
  git add .sops.yaml secrets/secrets.yaml
  git commit -m "Add age key for $HOSTNAME and encrypt secrets"
  git push
  ok "Changes pushed"
fi

# ── 7. Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== Secrets Setup Complete ==="
echo ""
echo "  Edit secrets:       sops $SECRETS_FILE"
echo "  Add a secret:       sops $SECRETS_FILE  (add key: value, save)"
echo "  Add new device:     run this script on that device"
echo "  Re-encrypt:         sops updatekeys $SECRETS_FILE"
echo ""
