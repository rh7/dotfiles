#!/usr/bin/env bash
# Setup sops-nix secrets for the current machine.
# Run this once per device after the first nix rebuild.
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

# ── 4. Check if key is already in .sops.yaml ────────────────────────────
if grep -q "$AGE_PUB" "$SOPS_YAML" 2>/dev/null; then
  ok "Key already in .sops.yaml"
else
  warn "Your key is NOT yet in .sops.yaml"
  echo ""
  echo "  Add this line to .sops.yaml under 'keys:':"
  echo ""
  echo -e "    ${GREEN}- &${HOSTNAME} ${AGE_PUB}${NC}"
  echo ""
  echo "  Then uncomment it in the 'creation_rules' age list."
  echo ""

  read -rp "  Open .sops.yaml in your editor now? [Y/n] " choice
  case "$choice" in
    [nN]*) ;;
    *)
      if command -v zed &>/dev/null; then
        zed "$SOPS_YAML"
      elif [[ -n "${EDITOR:-}" ]]; then
        "$EDITOR" "$SOPS_YAML"
      else
        open "$SOPS_YAML"
      fi
      echo ""
      read -rp "  Press Enter after saving .sops.yaml..." _
      ;;
  esac
fi

# ── 5. Encrypt secrets file (if not already encrypted) ──────────────────
if head -1 "$SECRETS_FILE" 2>/dev/null | grep -q "^sops:$\|ENC\[AES256_GCM\|age1"; then
  ok "Secrets file is already encrypted"
else
  if grep -q "$AGE_PUB" "$SOPS_YAML" 2>/dev/null; then
    info "Encrypting secrets file..."
    sops -e -i "$SECRETS_FILE"
    ok "Secrets encrypted"
  else
    warn "Skipping encryption — add your key to .sops.yaml first, then run:"
    echo "  sops -e -i $SECRETS_FILE"
  fi
fi

# ── 6. Summary ──────────────────────────────────────────────────────────
echo ""
echo "=== Setup Complete ==="
echo ""
echo "  To edit secrets:    sops $SECRETS_FILE"
echo "  To add a secret:    sops $SECRETS_FILE  (add key: value, save)"
echo "  To re-encrypt:      sops updatekeys $SECRETS_FILE"
echo "  To add a new device: run this script on that device,"
echo "                       add its key to .sops.yaml, then:"
echo "                       sops updatekeys $SECRETS_FILE"
echo ""
