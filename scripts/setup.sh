#!/usr/bin/env bash
# Interactive device setup — fresh Mac to managed fleet device
#
# The dotfiles repo is PUBLIC, so on a brand-new Mac you can:
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/setup.sh | bash
#
# Or manually:
#   xcode-select --install     # wait for dialog
#   git clone https://github.com/rh7/dotfiles.git ~/dotfiles
#   ~/dotfiles/scripts/setup.sh
#
# Flow: Xcode CLI → hostname → Nix → dotfiles (installs 1PW, Tailscale, gh, etc.)
#       → 1Password sign-in → gh auth → Tailscale → fleet registration
#
# Non-interactive:
#   setup.sh --hostname m5-pro --role workstation --non-interactive

set -euo pipefail

# ── Defaults ──
DOTFILES_REPO="https://github.com/rh7/dotfiles.git"
DOTFILES_DIR="$HOME/dotfiles"
CONFIG_SERVER="100.100.241.110:3456"
INTERACTIVE=true
HOSTNAME_ARG=""
ROLE_ARG=""
TS_AUTH_KEY=""

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
header() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}\n"; }
prompt() { echo -en "${BOLD}$*${NC} "; }

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)        HOSTNAME_ARG="$2"; shift 2 ;;
    --role)            ROLE_ARG="$2"; shift 2 ;;
    --auth-key)        TS_AUTH_KEY="$2"; shift 2 ;;
    --non-interactive) INTERACTIVE=false; shift ;;
    --config-server)   CONFIG_SERVER="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: setup.sh [OPTIONS]

Interactive device setup for the rh-device-management fleet.

Options:
  --hostname NAME       Set hostname (skip interactive selection)
  --role ROLE           Set role (workstation, personal, server, etc.)
  --auth-key KEY        Tailscale auth key (for headless/VPS setup)
  --non-interactive     Skip all prompts (requires --hostname)
  --config-server ADDR  Config service address (default: 100.100.241.110:3456)

Steps:
  1. Xcode CLI tools     (macOS — needed for git)
  2. Hostname selection   (pick from known profiles or enter new)
  3. Nix                  (Determinate Systems installer)
  4. Dotfiles + Nix build (installs ALL apps: 1Password, Tailscale, gh, etc.)
  5. 1Password            (sign in → unlock GitHub creds)
  6. GitHub CLI auth      (gh auth login — creds from 1Password)
  7. Tailscale            (sign in via main account)
  8. Fleet registration   (register with config service)
USAGE
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

OS="$(uname -s)"
ARCH="$(uname -m)"
CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"

echo ""
echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│       Fleet Device Setup                 │${NC}"
echo -e "${BOLD}${CYAN}│       rh-device-management               │${NC}"
echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}"
echo ""
USERNAME="$(whoami)"
echo -e "  Machine:  $CURRENT_HOSTNAME ($OS / $ARCH)"
echo -e "  User:     $USERNAME"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Xcode CLI Tools (macOS — git needs this)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$OS" == "Darwin" ]]; then
  header "Step 1/8: Xcode Command Line Tools"

  if xcode-select -p &>/dev/null; then
    ok "Installed"
  else
    info "Installing Xcode Command Line Tools..."
    xcode-select --install 2>/dev/null || true
    info "Waiting for installation to complete (this takes a few minutes)..."
    # Poll until xcode-select reports tools are installed
    while ! xcode-select -p &>/dev/null; do
      sleep 5
    done
    ok "Installed"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Hostname
# ══════════════════════════════════════════════════════════════════════════════
header "Step 2/8: Device Hostname"

# Known profiles from flake.nix: hostname|role|description|expected_username
# expected_username is checked against $USER to catch mismatches
KNOWN_PROFILES=(
  "m5-air|workstation|MacBook Air M5|rouvenheck"
  "rouven-m5-pro|workstation|MacBook Pro M5|rouven"
  "rouven-air-m2|workstation|MacBook Air M2|rouvenheck"
  "rouven-air-m3|workstation|MacBook Air M3|rouvenheck"
  "rouven-pro-m4|workstation|MacBook Pro M4|rouvenheck"
  "rouvens-mac-mini|smart-home|Mac Mini (office)|rouvenheck"
  "rouvens-mac-studio|ai-inference|Mac Studio|rouvenheck"
  "Kassie-M5-Air13|personal|Kassie's MacBook Air M5|kassie"
)

if [[ -n "$HOSTNAME_ARG" ]]; then
  HOSTNAME="$HOSTNAME_ARG"
  info "Using hostname: $HOSTNAME"
elif $INTERACTIVE; then
  echo -e "  Current hostname: ${BOLD}$CURRENT_HOSTNAME${NC}"
  echo ""
  echo "  Known profiles (from flake.nix):"
  echo ""
  for i in "${!KNOWN_PROFILES[@]}"; do
    IFS='|' read -r name role desc expected_user <<< "${KNOWN_PROFILES[$i]}"
    user_hint=""
    if [[ -n "$expected_user" && "$expected_user" != "$USERNAME" ]]; then
      user_hint=" ${YELLOW}(user: $expected_user)${NC}"
    fi
    printf "    ${BOLD}%d)${NC} %-25s ${CYAN}%-15s${NC} %s%b\n" "$((i+1))" "$name" "[$role]" "$desc" "$user_hint"
  done
  echo ""
  echo -e "    ${BOLD}n)${NC} New hostname (enter manually)"
  echo -e "    ${BOLD}k)${NC} Keep current: $CURRENT_HOSTNAME"
  echo ""
  prompt "  Select [1-${#KNOWN_PROFILES[@]}/n/k]:"
  read -r choice < /dev/tty

  case "$choice" in
    [1-9])
      idx=$((choice - 1))
      if [[ $idx -lt ${#KNOWN_PROFILES[@]} ]]; then
        IFS='|' read -r HOSTNAME ROLE_DEFAULT _ <<< "${KNOWN_PROFILES[$idx]}"
        [[ -z "$ROLE_ARG" ]] && ROLE_ARG="$ROLE_DEFAULT"
      else
        err "Invalid selection"; exit 1
      fi
      ;;
    k|K) HOSTNAME="$CURRENT_HOSTNAME" ;;
    n|N) prompt "  Enter hostname:"; read -r HOSTNAME < /dev/tty ;;
    *)   HOSTNAME="$choice" ;;
  esac
else
  HOSTNAME="$CURRENT_HOSTNAME"
fi

[[ -z "$HOSTNAME" ]] && { err "Hostname cannot be empty"; exit 1; }

# Match against known profiles
MATCHED_PROFILE=""
EXPECTED_USER=""
for entry in "${KNOWN_PROFILES[@]}"; do
  IFS='|' read -r name role _ expected_user <<< "$entry"
  if [[ "$name" == "$HOSTNAME" ]]; then
    MATCHED_PROFILE="$name"
    EXPECTED_USER="$expected_user"
    [[ -z "$ROLE_ARG" ]] && ROLE_ARG="$role"
    break
  fi
done

if [[ -n "$MATCHED_PROFILE" ]]; then
  ok "Matches flake profile ($ROLE_ARG)"
  # Check username matches what the flake expects
  if [[ -n "$EXPECTED_USER" && "$EXPECTED_USER" != "$USERNAME" ]]; then
    echo ""
    warn "macOS username mismatch!"
    warn "  Your account:     $USERNAME"
    warn "  Flake expects:    $EXPECTED_USER"
    warn ""
    warn "  The flake.nix profile '$MATCHED_PROFILE' is configured for user '$EXPECTED_USER'."
    warn "  Either:"
    warn "    - Create your macOS account as '$EXPECTED_USER' during Mac setup"
    warn "    - Or update flake.nix: username = \"$USERNAME\";"
    echo ""
    if $INTERACTIVE; then
      prompt "  Continue anyway? [y/n]:"
      read -r cont < /dev/tty
      [[ "$cont" != "y" && "$cont" != "Y" ]] && { info "Re-run after fixing username."; exit 0; }
    fi
  fi
else
  warn "No flake profile for '$HOSTNAME' — will skip Nix config"
fi

# ── Role (if not set from profile) ──
if [[ -z "$ROLE_ARG" ]]; then
  if $INTERACTIVE; then
    echo ""
    ROLES=("workstation" "personal" "server" "ai-inference" "ai-lab" "smart-home")
    for i in "${!ROLES[@]}"; do
      printf "    ${BOLD}%d)${NC} %s\n" "$((i+1))" "${ROLES[$i]}"
    done
    prompt "  Select role [1-${#ROLES[@]}]:"
    read -r rc < /dev/tty
    idx=$((rc - 1))
    ROLE_ARG="${ROLES[$idx]:-workstation}"
  else
    ROLE_ARG="workstation"
  fi
fi
ROLE="$ROLE_ARG"

ok "Device: $HOSTNAME | Role: $ROLE"

# ── Set system hostname ──
if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]]; then
  info "Setting hostname: $CURRENT_HOSTNAME → $HOSTNAME"
  case "$OS" in
    Darwin)
      sudo scutil --set ComputerName "$HOSTNAME"
      sudo scutil --set HostName "$HOSTNAME"
      sudo scutil --set LocalHostName "$HOSTNAME"
      ok "Hostname set (full effect after restart)"
      ;;
    Linux)
      sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null \
        || { echo "$HOSTNAME" | sudo tee /etc/hostname >/dev/null; }
      ok "Hostname set"
      ;;
  esac
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Nix
# ══════════════════════════════════════════════════════════════════════════════
header "Step 3/8: Nix Package Manager"

if command -v nix &>/dev/null; then
  ok "Nix installed ($(nix --version 2>/dev/null || echo 'unknown'))"
else
  case "$OS" in
    Darwin)
      info "Installing Nix via Determinate macOS package..."
      curl -fsSL https://install.determinate.systems/determinate-pkg/stable/Universal -o /tmp/Determinate.pkg
      sudo installer -pkg /tmp/Determinate.pkg -target /
      rm -f /tmp/Determinate.pkg
      ;;
    *)
      info "Installing Nix (Determinate Systems installer)..."
      curl --proto '=https' --tlsv1.2 -sSf -L \
        https://install.determinate.systems/nix | sh -s -- install --no-confirm
      ;;
  esac
  # Source nix into current shell
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
  ok "Nix installed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Dotfiles clone + Nix build (installs everything)
# ══════════════════════════════════════════════════════════════════════════════
header "Step 4/8: Dotfiles & Nix Configuration"

info "This step installs ALL your apps via Nix + Homebrew:"
info "1Password, Tailscale, gh, Cursor, browsers, everything."
echo ""

# Clone dotfiles (public repo — no auth needed)
if [[ -d "$DOTFILES_DIR" ]]; then
  info "Dotfiles exist. Pulling latest..."
  git -C "$DOTFILES_DIR" pull --ff-only || warn "Pull failed, using existing"
else
  info "Cloning dotfiles (public repo, no auth needed)..."
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi
ok "Dotfiles at $DOTFILES_DIR"

# Age key (needed before nix build for sops secrets)
AGE_KEY_DIR="$HOME/.config/sops/age"
AGE_KEY_FILE="$AGE_KEY_DIR/keys.txt"
if [[ -f "$AGE_KEY_FILE" ]]; then
  ok "Age key exists"
else
  info "Generating device age key for sops-nix secrets..."
  nix profile install nixpkgs#age 2>/dev/null || true
  mkdir -p "$AGE_KEY_DIR"
  age-keygen -o "$AGE_KEY_FILE" 2>/dev/null
  chmod 600 "$AGE_KEY_FILE"
  ok "Age key generated"
fi
AGE_PUB=$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || echo "unknown")

# Build and apply Nix configuration
NIX_BUILD_OK=false
if [[ -n "$MATCHED_PROFILE" ]]; then
  cd "$DOTFILES_DIR"

  info "Building Nix config for $HOSTNAME (first run takes 5-15 min)..."
  echo ""

  case "$OS" in
    Darwin)
      if nix build ".#darwinConfigurations.${HOSTNAME}.system" --no-link 2>&1; then
        info "Running darwin-rebuild switch..."
        if command -v darwin-rebuild &>/dev/null; then
          sudo darwin-rebuild switch --flake ".#${HOSTNAME}"
        else
          nix build ".#darwinConfigurations.${HOSTNAME}.system"
          sudo ./result/sw/bin/darwin-rebuild switch --flake ".#${HOSTNAME}"
        fi
        NIX_BUILD_OK=true
        ok "Configuration applied — all apps installed"
      else
        warn "Build failed. Check flake.nix or run manually later:"
        echo "  cd ~/dotfiles && darwin-rebuild switch --flake .#${HOSTNAME}"
      fi
      ;;
    Linux)
      if nix build ".#nixosConfigurations.${HOSTNAME}.config.system.build.toplevel" --no-link 2>/dev/null; then
        sudo nixos-rebuild switch --flake ".#${HOSTNAME}"
        NIX_BUILD_OK=true
        ok "Configuration applied"
      else
        warn "No config found for '$HOSTNAME'"
      fi
      ;;
  esac
else
  warn "No flake profile for '$HOSTNAME' — skipping Nix build"
  echo ""
  echo "  To add later, edit ~/dotfiles/flake.nix:"
  echo ""
  echo "    \"$HOSTNAME\" = mkMac {"
  echo "      hostname = \"$HOSTNAME\";"
  echo "      extraModules = [ ./configurations/macos/macbook.nix ];"
  echo "    };"
  echo ""
  echo "  Then: darwin-rebuild switch --flake ~/dotfiles#${HOSTNAME}"
fi

if ! $NIX_BUILD_OK; then
  echo ""
  warn "Nix build did not complete — skipping 1Password, GitHub, and Tailscale setup."
  warn "Fix the build issue, then re-run this script."
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: 1Password sign-in
# ══════════════════════════════════════════════════════════════════════════════
header "Step 5/8: 1Password"

if [[ -d "/Applications/1Password.app" ]] || [[ -d "$HOME/Applications/1Password.app" ]]; then
  ok "1Password installed (via Nix/Homebrew)"
  if $INTERACTIVE; then
    echo ""
    echo "  Open 1Password and sign in to unlock your credentials."
    echo "  You'll need GitHub credentials for the next step."
    echo ""
    prompt "  Press Enter when 1Password is ready..."
    read -r < /dev/tty
  fi
else
  warn "1Password not installed. Install it manually or check flake.nix."
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: GitHub CLI auth
# ══════════════════════════════════════════════════════════════════════════════
header "Step 6/8: GitHub Authentication"

# Ensure gh is available (should be from nix build, but install if needed)
if ! command -v gh &>/dev/null; then
  nix profile install nixpkgs#gh 2>/dev/null || true
fi

if gh auth status &>/dev/null 2>&1; then
  ok "Already authenticated"
else
  echo "  Authenticate with GitHub (credentials from 1Password)."
  echo ""
  if $INTERACTIVE; then
    gh auth login < /dev/tty
  else
    warn "Not authenticated. Run 'gh auth login' manually."
  fi
fi

# Git credential helper
GITCONFIG="$HOME/.gitconfig"
CURRENT_HELPER=$(git config --global --get 'credential.https://github.com.helper' 2>/dev/null || true)
EXPECTED_HELPER='!gh auth git-credential'
if [[ "$CURRENT_HELPER" != "$EXPECTED_HELPER" ]]; then
  info "Configuring git credential helper..."
  if [[ -f "$GITCONFIG" ]]; then
    sed -i.bak '/\[credential "https:\/\/github.com"\]/,/^$/d' "$GITCONFIG"
    rm -f "$GITCONFIG.bak"
  fi
  cat >> "${GITCONFIG:-$HOME/.gitconfig}" <<'GITEOF'
[credential "https://github.com"]
	helper = !gh auth git-credential
GITEOF
  ok "Git credential helper set"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Tailscale
# ══════════════════════════════════════════════════════════════════════════════
header "Step 7/8: Tailscale"

if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
  ok "Connected (IP: $TAILSCALE_IP)"
else
  if [[ -d "/Applications/Tailscale.app" ]]; then
    ok "Tailscale.app installed (via Nix/Homebrew)"
  else
    warn "Tailscale not installed. Should have been installed by Nix build."
    warn "Install from App Store or: nix profile install nixpkgs#tailscale"
  fi

  if $INTERACTIVE; then
    echo ""
    echo "  Open Tailscale and sign in with your main account."
    echo "  This joins the device to your private network."
    echo ""
    prompt "  Press Enter when Tailscale is connected..."
    read -r < /dev/tty
  fi

  if [[ -n "$TS_AUTH_KEY" ]]; then
    sudo tailscale up --authkey "$TS_AUTH_KEY" --hostname "$HOSTNAME"
  fi

  if tailscale status &>/dev/null 2>&1; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    ok "Connected (IP: $TAILSCALE_IP)"
  else
    warn "Not connected yet — fleet registration will be skipped"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 8: Fleet Registration
# ══════════════════════════════════════════════════════════════════════════════
header "Step 8/8: Fleet Registration"

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

if [[ -z "$TAILSCALE_IP" ]]; then
  warn "Not on tailnet — skipping registration"
elif curl -sf "http://${CONFIG_SERVER}/api/health" --max-time 5 &>/dev/null; then
  info "Registering with config service..."
  curl -sf -X POST "http://${CONFIG_SERVER}/api/devices/register" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$HOSTNAME\",\"os\":\"$OS\",\"arch\":\"$ARCH\",\"role\":\"$ROLE\",\"tailscale_ip\":\"$TAILSCALE_IP\",\"age_public_key\":\"$AGE_PUB\",\"nix_version\":\"$(nix --version 2>/dev/null || echo unknown)\"}" \
    --max-time 10 \
    && ok "Registered" \
    || warn "Registration failed (non-fatal)"
else
  warn "Config service not reachable at $CONFIG_SERVER"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}━━━ Setup Complete ━━━${NC}"
echo ""
echo -e "  Device:       ${BOLD}$HOSTNAME${NC}"
echo -e "  Role:         $ROLE"
echo -e "  OS:           $OS / $ARCH"
echo -e "  Tailscale:    ${TAILSCALE_IP:-not connected}"
echo -e "  Dotfiles:     $DOTFILES_DIR"
echo -e "  Age key:      ${AGE_PUB:-not generated}"
echo ""
if [[ -z "$MATCHED_PROFILE" ]]; then
  echo -e "  ${YELLOW}Next: add '$HOSTNAME' to ~/dotfiles/flake.nix${NC}"
  echo -e "  ${YELLOW}Then: darwin-rebuild switch --flake ~/dotfiles#${HOSTNAME}${NC}"
  echo ""
fi
if [[ -n "${TAILSCALE_IP:-}" ]]; then
  echo -e "  Dashboard: ${BLUE}http://${CONFIG_SERVER}/dashboard${NC}"
  echo ""
fi
