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
CONFIG_SERVER=""
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
  --config-server ADDR  Config service address (default: auto-discover via LAN/Tailscale)

Steps:
  1. Xcode CLI tools     (macOS — needed for git)
  2. Hostname selection   (pick from known profiles or enter new)
  3. Nix                  (official NixOS community installer)
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

# ── Discover config service (if not set via --config-server) ──
if [[ -z "$CONFIG_SERVER" ]]; then
  for host in Rouvens-Mac-Studio.local rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
    if curl -sf "http://${host}:3456/api/health" --max-time 2 &>/dev/null; then
      CONFIG_SERVER="${host}:3456"
      break
    fi
  done
fi

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
# Setup profile — ask upfront what kind of setup this is
# ══════════════════════════════════════════════════════════════════════════════
SETUP_GITHUB=true
SETUP_TAILSCALE=true
SETUP_1PASSWORD=true

if $INTERACTIVE; then
  echo -e "${BOLD}  What type of setup is this?${NC}"
  echo ""
  echo -e "  ${BOLD}1)${NC}  Developer workstation   (full setup: 1Password, GitHub, Tailscale)"
  echo -e "  ${BOLD}2)${NC}  Personal / family Mac   (skip GitHub auth, lighter config)"
  echo -e "  ${BOLD}3)${NC}  Server / headless        (skip interactive sign-ins)"
  echo ""
  prompt "  Choose [1-3]: "
  read -r setup_profile < /dev/tty
  case "$setup_profile" in
    2)
      SETUP_GITHUB=false
      info "Personal setup — GitHub auth will be skipped"
      ;;
    3)
      SETUP_1PASSWORD=false
      SETUP_GITHUB=false
      info "Server setup — interactive sign-ins will be skipped"
      ;;
    *)
      info "Developer setup — full configuration"
      ;;
  esac
  echo ""
fi

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
  if [[ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" == "$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')" ]]; then
    # Use the flake's casing (nix-darwin needs exact match)
    if [[ "$name" != "$HOSTNAME" ]]; then
      info "Adjusting hostname case: $HOSTNAME → $name"
      HOSTNAME="$name"
    fi
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

  # Check for Determinate Nix and warn
  if nix --version 2>/dev/null | grep -qi determinate; then
    warn "Running Determinate Nix (proprietary fork)."
    warn "Consider migrating to official Nix: /nix/nix-installer uninstall, then re-run setup."
  fi
else
  # Clean up any partial install from a previous failed attempt
  if [[ "$OS" == "Darwin" ]]; then
    NIX_DEV=$(diskutil list | grep "Nix Store" | awk '{print $NF}' || true)
    if [[ -n "$NIX_DEV" ]]; then
      info "Found leftover Nix Store volume from previous attempt — cleaning up..."
      sudo /usr/sbin/diskutil unmount force "$NIX_DEV" 2>/dev/null || true
      sudo /usr/sbin/diskutil apfs deleteVolume "$NIX_DEV" 2>/dev/null || true
      ok "Cleaned up stale volume"
    fi
  fi

  # Official NixOS community installer.
  # NOTE: on macOS, this must run from a GUI session (Terminal.app / Screen Sharing).
  # Headless-only Macs block /etc/fstab writes needed for the Nix APFS volume.
  # See: https://github.com/NixOS/nix/issues/13723
  info "Installing Nix (official NixOS community installer)..."
  info "This is the upstream open-source Nix — no proprietary additions."
  echo ""
  if ! sh <(curl -L https://nixos.org/nix/install) --daemon; then
    err "Nix installer failed."
    err "If you see 'vifs: error creating /etc/fstab', re-run from a GUI session"
    err "(Terminal.app via Screen Sharing, not SSH)."
    exit 1
  fi

  # Source nix into current shell
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  ok "Nix installed (official)"
fi

# Post-install nix.conf tweaks
NIX_CONF_CHANGED=false

# Ensure macOS SSL certificates are configured (official installer doesn't do this)
if [[ "$OS" == "Darwin" ]] && ! grep -q "ssl-cert-file" /etc/nix/nix.conf 2>/dev/null; then
  info "Configuring SSL certificates for Nix..."
  sudo sh -c 'echo "ssl-cert-file = /etc/ssl/cert.pem" >> /etc/nix/nix.conf'
  NIX_CONF_CHANGED=true
  ok "SSL certificates configured"
fi

# Enable flakes (official installer doesn't enable them by default)
if ! grep -q 'experimental-features.*flakes' /etc/nix/nix.conf 2>/dev/null; then
  info "Enabling flakes and nix-command..."
  sudo sh -c 'echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf'
  NIX_CONF_CHANGED=true
fi

if $NIX_CONF_CHANGED; then
  sudo launchctl kickstart -k system/org.nixos.nix-daemon 2>/dev/null || true
fi

# Remove FlakeHub from trusted substituters if present (Determinate adds this)
if grep -q "flakehub" /etc/nix/nix.conf 2>/dev/null; then
  warn "FlakeHub found in nix.conf — removing untrusted substituter"
  sudo sed -i '' '/flakehub/d' /etc/nix/nix.conf
  sudo launchctl kickstart -k system/org.nixos.nix-daemon 2>/dev/null || true
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
  git -C "$DOTFILES_DIR" stash --include-untracked -q 2>/dev/null || true
  git -C "$DOTFILES_DIR" pull --ff-only || warn "Pull failed, using existing"
  git -C "$DOTFILES_DIR" stash pop -q 2>/dev/null || true
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

# SSH key (for fleet SSH access between devices)
SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
if [[ -f "$SSH_KEY_FILE" ]]; then
  ok "SSH key exists"
else
  info "Generating SSH key..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "${USERNAME}@${HOSTNAME}" -f "$SSH_KEY_FILE" -N "" -q
  ok "SSH key generated"
fi
SSH_PUB=$(cat "${SSH_KEY_FILE}.pub" 2>/dev/null || echo "unknown")
info "SSH public key: $SSH_PUB"

# Early registration — report SSH key so other machines can SSH in during setup
if [[ -n "$CONFIG_SERVER" ]] && curl -sf "http://${CONFIG_SERVER}/api/health" --max-time 3 &>/dev/null; then
  curl -sf -X POST "http://${CONFIG_SERVER}/api/devices/register" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$HOSTNAME\",\"os\":\"$OS\",\"arch\":\"$ARCH\",\"role\":\"$ROLE\",\"ssh_public_key\":\"$SSH_PUB\",\"age_public_key\":\"$AGE_PUB\"}" \
    --max-time 5 &>/dev/null \
    && ok "SSH key registered with fleet (you can SSH in from other devices now)" \
    || true
fi

# Build and apply Nix configuration
NIX_BUILD_OK=false
if [[ -n "$MATCHED_PROFILE" ]]; then
  cd "$DOTFILES_DIR"

  info "Building Nix config for $HOSTNAME (first run takes 5-15 min)..."
  echo ""

  case "$OS" in
    Darwin)
      # Homebrew is required by nix-darwin's homebrew module
      # Source brew into PATH if installed but not in current shell
      if ! command -v brew &>/dev/null && [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        ok "Homebrew already installed (added to PATH)"
      fi
      if ! command -v brew &>/dev/null; then
        info "Installing Homebrew (required by nix-darwin)..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
        eval "$(/opt/homebrew/bin/brew shellenv)"
        ok "Homebrew installed"
      fi

      if nix build ".#darwinConfigurations.${HOSTNAME}.system" --no-link 2>&1; then
        info "Running darwin-rebuild switch..."
        if command -v darwin-rebuild &>/dev/null; then
          darwin-rebuild switch --flake ".#${HOSTNAME}" && NIX_BUILD_OK=true \
            || { warn "darwin-rebuild had errors (likely brew bundle — non-fatal)"; NIX_BUILD_OK=true; }
        else
          nix build ".#darwinConfigurations.${HOSTNAME}.system"
          ./result/sw/bin/darwin-rebuild switch --flake ".#${HOSTNAME}" && NIX_BUILD_OK=true \
            || { warn "darwin-rebuild had errors (likely brew bundle — non-fatal)"; NIX_BUILD_OK=true; }
        fi
        if $NIX_BUILD_OK; then
          ok "Configuration applied (re-run 'darwin-rebuild switch' later to retry failed casks)"
        fi
      else
        warn "Nix build failed. Check flake.nix or run manually later:"
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

if ! $SETUP_1PASSWORD; then
  info "Skipped (not needed for this setup profile)"
elif [[ -d "/Applications/1Password.app" ]] || [[ -d "$HOME/Applications/1Password.app" ]]; then
  ok "1Password installed (via Nix/Homebrew)"
  if $INTERACTIVE; then
    echo ""
    echo "  Open 1Password and sign in to unlock your credentials."
    if $SETUP_GITHUB; then
      echo "  You'll need GitHub credentials for the next step."
    fi
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

if ! $SETUP_GITHUB; then
  info "Skipped (not needed for this setup profile)"
else
  # Ensure gh is available (should be from nix build, but install if needed)
  if ! command -v gh &>/dev/null; then
    nix profile install nixpkgs#gh 2>/dev/null || true
  fi

  if gh auth status &>/dev/null 2>&1; then
    ok "Already authenticated"
  else
    if $INTERACTIVE; then
      gh auth login < /dev/tty
    else
      warn "Not authenticated. Run 'gh auth login' manually."
    fi
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

# ── Commit flake.lock if dirty (first build updates it) ──
if [[ -d "$DOTFILES_DIR/.git" ]] && gh auth status &>/dev/null 2>&1; then
  cd "$DOTFILES_DIR"
  if git diff --quiet flake.lock 2>/dev/null; then
    ok "flake.lock is clean"
  else
    info "Committing updated flake.lock..."
    git add flake.lock
    git commit -m "chore: update flake.lock after first build on $HOSTNAME" && \
      git push && ok "flake.lock committed and pushed" || \
      warn "flake.lock commit/push failed (non-fatal)"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Tailscale
# ══════════════════════════════════════════════════════════════════════════════
header "Step 7/8: Tailscale"

# Try to open Tailscale.app if installed but not running (macOS)
if [[ "$OS" == "Darwin" ]] && [[ -d "/Applications/Tailscale.app" ]]; then
  open -gja "Tailscale" 2>/dev/null || true
  sleep 2  # give it a moment to start the daemon
fi

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
elif [[ -z "$CONFIG_SERVER" ]]; then
  warn "Config service not discovered — skipping registration"
elif curl -sf "http://${CONFIG_SERVER}/api/health" --max-time 5 &>/dev/null; then
  info "Registering with config service..."
  curl -sf -X POST "http://${CONFIG_SERVER}/api/devices/register" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$HOSTNAME\",\"os\":\"$OS\",\"arch\":\"$ARCH\",\"role\":\"$ROLE\",\"tailscale_ip\":\"$TAILSCALE_IP\",\"age_public_key\":\"$AGE_PUB\",\"ssh_public_key\":\"$SSH_PUB\",\"nix_version\":\"$(nix --version 2>/dev/null || echo unknown)\"}" \
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
echo -e "  SSH key:      ${SSH_PUB:-not generated}"
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
