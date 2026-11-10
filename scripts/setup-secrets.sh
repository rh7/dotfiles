#!/usr/bin/env bash
# Device-side sops setup: make sure this machine has an age key, register its
# public key with the fleet, and check whether it can decrypt
# secrets/secrets.yaml (rh7/rh-device-management#310).
#
# This script does NOT edit .sops.yaml or re-encrypt anything. It can't: a device
# that is not yet a recipient cannot re-encrypt the data key. That half runs on
# an EXISTING recipient (rouvens-mac-studio or m5-air):
#   scripts/sops-add-host.sh <hostname> <age1pubkey>
# and must be merged BEFORE this device's first secrets-decrypting rebuild.
#
# Exit status: 0 if this device can decrypt secrets/secrets.yaml, or if its flake
#                config declares no sops secrets (needsSecrets = false) so
#                decryption is not required.
#              1 otherwise (including "could not evaluate the config") — with
#                the exact recipient-side command to run.
#
# Usage: scripts/setup-secrets.sh [--hostname NAME] [--no-register]
#   --hostname NAME   flake host name (default: hostname -s)
#   --no-register     skip registering the key with the config service

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

HOST=""
REGISTER=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)    [[ $# -ge 2 ]] || { err "--hostname needs a value"; exit 2; }; HOST="$2"; shift 2 ;;
    --no-register) REGISTER=false; shift ;;
    -h|--help)     sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             err "Unknown option: $1"; exit 2 ;;
  esac
done
[[ -n "$HOST" ]] || HOST="$(hostname -s 2>/dev/null || hostname)"

# On macOS sops defaults to ~/Library/Application Support/sops/age/keys.txt and
# fails with a misleading "identity did not match" for the fleet's key (#111).
# Activation is unaffected (modules/secrets.nix sets sops.age.keyFile); this is
# for every sops run by hand — export it in your shell too.
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

# ── 1. Tools (no profile install — run from nixpkgs if not on PATH yet) ──────
if command -v age-keygen >/dev/null 2>&1; then AGE_KEYGEN=(age-keygen)
else AGE_KEYGEN=(nix shell nixpkgs#age --command age-keygen); fi
if command -v sops >/dev/null 2>&1; then SOPS=(sops)
else SOPS=(nix run nixpkgs#sops --); fi

# ── 2. Age key ──────────────────────────────────────────────────────────────
if [[ -f "$AGE_KEY_FILE" ]]; then
  ok "Age key exists: $AGE_KEY_FILE"
else
  info "Generating age key..."
  mkdir -p "$AGE_KEY_DIR"
  (umask 077 && "${AGE_KEYGEN[@]}" -o "$AGE_KEY_FILE" 2>/dev/null) || { err "age-keygen failed"; exit 1; }
  chmod 600 "$AGE_KEY_FILE"
  ok "Age key generated: $AGE_KEY_FILE"
fi
AGE_PUB=$("${AGE_KEYGEN[@]}" -y "$AGE_KEY_FILE") || { err "could not derive the public key from $AGE_KEY_FILE"; exit 1; }

echo ""
info "Device:     $HOST"
info "Public key: $AGE_PUB"
echo ""

# ── 3. Register the public key (the recipient side can then look it up) ─────
if $REGISTER; then
  # shellcheck source=lib/config-service.sh
  source "$DOTFILES_DIR/scripts/lib/config-service.sh"
  BASE=""
  if load_config_service_resolver "$DOTFILES_DIR"; then
    BASE=$(find_config_service)
  else
    warn "could not load the config-service resolver — skipping registration"
  fi
  if [[ -n "$BASE" ]]; then
    SSH_PUB=""
    [[ -r "$HOME/.ssh/id_ed25519.pub" ]] && SSH_PUB=$(cat "$HOME/.ssh/id_ed25519.pub")
    PAYLOAD=$(HOST="$HOST" OS="$(uname -s)" ARCH="$(uname -m)" AGE_PUB="$AGE_PUB" SSH_PUB="$SSH_PUB" python3 -c '
import json, os
d = {"hostname": os.environ["HOST"], "os": os.environ["OS"], "arch": os.environ["ARCH"],
     "age_public_key": os.environ["AGE_PUB"]}
if os.environ["SSH_PUB"]:
    d["ssh_public_key"] = os.environ["SSH_PUB"]
print(json.dumps(d))')
    if curl -sf -X POST "$BASE/api/devices/register" -H "Content-Type: application/json" \
         -d "$PAYLOAD" --max-time 10 >/dev/null; then
      ok "Public key registered at $BASE"
    else
      warn "Registration at $BASE failed — pass the key explicitly on the recipient side"
    fi
  else
    warn "Config service not reachable — pass the key explicitly on the recipient side"
  fi
fi

# ── 4. Can this device decrypt? ─────────────────────────────────────────────
[[ -f "$SECRETS_FILE" ]] || { err "$SECRETS_FILE not found"; exit 1; }
if DECRYPT_ERR=$("${SOPS[@]}" -d "$SECRETS_FILE" 2>&1 >/dev/null); then
  ok "This device decrypts secrets/secrets.yaml — secrets setup complete"
  echo ""
  echo "  For sops by hand on macOS:  export SOPS_AGE_KEY_FILE=\"\$HOME/.config/sops/age/keys.txt\""
  exit 0
fi

# Not decryptable. Is that a problem? Only if this host's config declares sops
# secrets: needsSecrets = false hosts (e.g. Kassie-M5-Air13) never import
# modules/secrets.nix, so they activate fine without being recipients. Anything
# other than a definite "false" — eval error, host missing from the flake, no
# nix — counts as "needs secrets": refuse rather than wave a host through.
case "$(uname -s)" in
  Darwin) CFG_ATTR="darwinConfigurations" ;;
  *)      CFG_ATTR="nixosConfigurations" ;;
esac
NEEDS_SECRETS=$(nix eval --json "$DOTFILES_DIR#$CFG_ATTR.\"$HOST\".config" \
  --apply 'c: (c.sops.secrets or {}) != {}' 2>/dev/null) || NEEDS_SECRETS="unknown"
if [[ "$NEEDS_SECRETS" == "false" ]]; then
  ok "$HOST's config declares no sops secrets — decryption not required"
  info "To make it a recipient anyway: scripts/sops-add-host.sh $HOST $AGE_PUB (on an existing recipient)"
  exit 0
fi
[[ "$NEEDS_SECRETS" == "true" ]] \
  || warn "Could not evaluate $CFG_ATTR.$HOST in $DOTFILES_DIR — assuming it needs secrets"

if grep -qF "recipient: $AGE_PUB" "$SECRETS_FILE"; then
  # Already a recipient: re-keying won't help, so don't send anyone to do it.
  err "$HOST is a recipient of secrets/secrets.yaml but decryption failed:"
  printf '%s\n' "$DECRYPT_ERR" | sed 's/^/    /' >&2
  err "Is ~/dotfiles up to date with origin/main, and is $AGE_KEY_FILE the key registered above?"
  exit 1
fi

err "$HOST cannot decrypt secrets/secrets.yaml yet — it is not a sops recipient."
cat >&2 <<EOF

  On an EXISTING recipient (rouvens-mac-studio or m5-air), run:

    git -C ~/dotfiles fetch origin
    git -C ~/dotfiles worktree add /tmp/dotfiles-sops-$HOST -b sops/add-$HOST origin/main
    cd /tmp/dotfiles-sops-$HOST && scripts/sops-add-host.sh $HOST $AGE_PUB

  Merge the PR it opens, then on this device:

    git -C ~/dotfiles pull --ff-only && ~/dotfiles/scripts/setup-secrets.sh

  Do not activate this host's configuration before that: sops-nix decrypts at
  activation, so the first rebuild would fail without its secrets.
EOF
exit 1
