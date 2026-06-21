#!/usr/bin/env bash
# Fleet device audit — non-destructive inventory collection and registration.
# Replaces the old heartbeat.sh with a single daily audit + registration.
#
# Usage:
#   ./scripts/audit-device.sh              # interactive menu
#   ./scripts/audit-device.sh --run        # audit + upload (non-interactive, for cron)
#   ./scripts/audit-device.sh --local      # audit only, print JSON (no upload)
#   ./scripts/audit-device.sh --save       # audit and save to ~/dotfiles-backups/audit/
#   ./scripts/audit-device.sh --install    # install daily schedule (LaunchAgent on macOS, cron on Linux)
#   ./scripts/audit-device.sh --uninstall  # remove daily schedule
#
# On machines without the dotfiles repo (e.g. fresh Mac):
#   curl -fsSL config.rh7labs.com/audit | bash

set -euo pipefail

HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')"
OS="$(uname -s)"
ARCH="$(uname -m)"
MODE="${1:-interactive}"
SCRIPT_URL="https://config.rh7labs.com/audit"
CRON_TAG="# fleet-audit"
OLD_CRON_TAG="# fleet-heartbeat"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC}  $*" >&2; }

# ── Interactive menu ────────────────────────────────────────────────────
if [[ "$MODE" == "interactive" ]]; then
  # When piped via curl, read from /dev/tty for interactive input
  exec 3</dev/tty 2>/dev/null || exec 3<&0

  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${CYAN}│       Fleet Device Audit                 │${NC}"
  echo -e "${BOLD}${CYAN}│       $HOSTNAME ($OS/$ARCH)${NC}"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "  ${BOLD}1)${NC}  Run audit now (upload to fleet)"
  echo -e "  ${BOLD}2)${NC}  Run audit now (local only, no upload)"
  echo -e "  ${BOLD}3)${NC}  Run audit + install daily cron"
  echo -e "  ${BOLD}4)${NC}  Install daily cron only (no audit now)"
  echo -e "  ${BOLD}5)${NC}  Remove daily cron"
  echo -e "  ${BOLD}6)${NC}  Save audit to file"
  echo -e "  ${BOLD}7)${NC}  Show post-setup checklist"
  echo -e "  ${BOLD}q)${NC}  Quit"
  echo ""
  echo -en "${BOLD}Choose [1-7, q]: ${NC}"
  read -r choice <&3

  case "$choice" in
    1) MODE="--run" ;;
    2) MODE="--local" ;;
    3) MODE="--run-and-install" ;;
    4) MODE="--install" ;;
    5) MODE="--uninstall" ;;
    6) MODE="--save" ;;
    7) MODE="--checklist" ;;
    q|Q) echo "Bye."; exit 0 ;;
    *) err "Invalid choice"; exit 1 ;;
  esac

  exec 3<&-
fi

# ── Install daily schedule ─────────────────────────────────────────────
# macOS 15+ blocks `crontab < tmpfile` under TCC unless the caller has Full
# Disk Access, so on Darwin we install a LaunchAgent instead. Linux still
# uses crontab.
LAUNCHAGENT_LABEL="com.rh7.audit"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"

build_audit_cmd() {
  if [[ -f "$HOME/dotfiles/scripts/audit-device.sh" ]]; then
    echo "bash $HOME/dotfiles/scripts/audit-device.sh --run"
  else
    echo "curl -fsSL $SCRIPT_URL | bash -s -- --run"
  fi
}

install_launchagent() {
  local audit_cmd
  audit_cmd="$(build_audit_cmd)"
  local hour=8
  local minute=$(( RANDOM % 30 ))

  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LAUNCHAGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-lc</string>
        <string>${audit_cmd}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/${LAUNCHAGENT_LABEL}.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${LAUNCHAGENT_LABEL}.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

  launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCHAGENT_PLIST"
  ok "Installed daily audit LaunchAgent ($(printf '%d:%02d' "$hour" "$minute") AM)"
  info "→ $LAUNCHAGENT_PLIST"
  info "→ $audit_cmd"
}

install_crontab() {
  local audit_cmd cron_min cron_line
  audit_cmd="$(build_audit_cmd)"
  cron_min=$(( RANDOM % 30 ))
  cron_line="${cron_min} 8 * * * ${audit_cmd} ${CRON_TAG}"
  (crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$OLD_CRON_TAG"; echo "$cron_line") | crontab -
  ok "Installed daily audit cron (8:$(printf '%02d' "$cron_min") AM)"
  info "→ $audit_cmd"
}

install_cron() {
  if [[ "$OS" == "Darwin" ]]; then
    install_launchagent
  else
    install_crontab
  fi
}

uninstall_schedule() {
  if [[ "$OS" == "Darwin" ]]; then
    if [[ -f "$LAUNCHAGENT_PLIST" ]]; then
      launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
      rm -f "$LAUNCHAGENT_PLIST"
      ok "Removed audit LaunchAgent"
    else
      info "No audit LaunchAgent installed"
    fi
  else
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$OLD_CRON_TAG" | crontab -
    ok "Removed audit cron job"
  fi
}

if [[ "$MODE" == "--install" ]]; then
  install_cron
  exit 0
fi

if [[ "$MODE" == "--uninstall" ]]; then
  uninstall_schedule
  exit 0
fi

if [[ "$MODE" == "--checklist" ]]; then
  CONFIG_URL=$(find_config_service)
  if [[ -n "$CONFIG_URL" ]]; then
    show_checklist "$CONFIG_URL"
  else
    err "Config service not reachable"
  fi
  exit 0
fi

# ── Find config service ─────────────────────────────────────────────────
find_config_service() {
  for host in localhost Rouvens-Mac-Studio.local rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
    if curl -sf "http://${host}:3456/api/health" --max-time 2 &>/dev/null; then
      echo "http://${host}:3456"; return
    fi
  done
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════
# Collectors — each outputs a JSON fragment
# ══════════════════════════════════════════════════════════════════════════

collect_system() {
  local hw_model="" hw_chip="" hw_memory="" hw_serial=""
  if [[ "$OS" == "Darwin" ]]; then
    hw_model=$(sysctl -n hw.model 2>/dev/null || echo "")
    hw_chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    # Apple Silicon: get chip name from system_profiler
    if [[ -z "$hw_chip" ]] || [[ "$hw_chip" == *"Apple"* ]]; then
      hw_chip=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip:" | sed 's/.*Chip: //' || echo "$hw_chip")
    fi
    hw_memory=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || echo "")
    hw_serial=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Serial Number" | sed 's/.*: //' || echo "")
  elif [[ "$OS" == "Linux" ]]; then
    hw_model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
    hw_chip=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "")
    hw_memory=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1048576}' || echo "")
    hw_serial=$(cat /sys/devices/virtual/dmi/id/product_serial 2>/dev/null || echo "")
  fi

  cat <<JSON
{
  "hostname": "$HOSTNAME",
  "os": "$OS",
  "arch": "$ARCH",
  "macos_version": "$(sw_vers -productVersion 2>/dev/null || echo '')",
  "kernel": "$(uname -r)",
  "uptime": "$(uptime | sed 's/.*up //' | sed 's/,.*//')",
  "shell": "$SHELL",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hardware": {
    "model": "$hw_model",
    "chip": "$hw_chip",
    "memory_gb": $([[ -n "$hw_memory" ]] && echo "$hw_memory" || echo "0"),
    "serial": "$hw_serial"
  }
}
JSON
}

collect_homebrew() {
  if ! command -v brew &>/dev/null; then echo '{"installed": false}'; return; fi

  local formulas casks taps
  formulas=$(brew list --formula -1 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")
  casks=$(brew list --cask -1 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")
  taps=$(brew tap 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")

  cat <<JSON
{
  "installed": true,
  "formulas": $formulas,
  "casks": $casks,
  "taps": $taps,
  "formula_count": $(brew list --formula -1 2>/dev/null | wc -l | tr -d ' '),
  "cask_count": $(brew list --cask -1 2>/dev/null | wc -l | tr -d ' ')
}
JSON
}

collect_mas() {
  if ! command -v mas &>/dev/null; then echo '{"installed": false}'; return; fi

  local apps
  apps=$(mas list 2>/dev/null | python3 -c "
import sys, json
apps = []
for line in sys.stdin:
    parts = line.strip().split(' ', 1)
    if len(parts) == 2:
        app_id = parts[0]
        name = parts[1].rsplit('(', 1)[0].strip()
        apps.append({'id': app_id, 'name': name})
print(json.dumps(apps))
" 2>/dev/null || echo '[]')

  echo "{\"installed\": true, \"apps\": $apps}"
}

collect_applications() {
  python3 -c "
import os, json
apps = []
for d in ['/Applications', os.path.expanduser('~/Applications')]:
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith('.app'):
                apps.append(f.replace('.app', ''))
print(json.dumps(apps))
" 2>/dev/null || echo '[]'
}

collect_macos_defaults() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi

  python3 -c "
import subprocess, json

def read_default(domain, key):
    try:
        r = subprocess.run(['defaults', 'read', domain, key], capture_output=True, text=True, timeout=2)
        v = r.stdout.strip()
        if v.isdigit(): return int(v)
        if v in ('true', '1'): return True
        if v in ('false', '0'): return False
        return v
    except: return None

defaults = {
    'dock': {
        'autohide': read_default('com.apple.dock', 'autohide'),
        'tilesize': read_default('com.apple.dock', 'tilesize'),
        'show-recents': read_default('com.apple.dock', 'show-recents'),
        'orientation': read_default('com.apple.dock', 'orientation'),
        'mru-spaces': read_default('com.apple.dock', 'mru-spaces'),
    },
    'finder': {
        'AppleShowAllExtensions': read_default('com.apple.finder', 'AppleShowAllExtensions'),
        'AppleShowAllFiles': read_default('com.apple.finder', 'AppleShowAllFiles'),
        'ShowPathbar': read_default('com.apple.finder', 'ShowPathbar'),
        'ShowStatusBar': read_default('com.apple.finder', 'ShowStatusBar'),
        'FXPreferredViewStyle': read_default('com.apple.finder', 'FXPreferredViewStyle'),
    },
    'keyboard': {
        'InitialKeyRepeat': read_default('NSGlobalDomain', 'InitialKeyRepeat'),
        'KeyRepeat': read_default('NSGlobalDomain', 'KeyRepeat'),
        'NSAutomaticCapitalizationEnabled': read_default('NSGlobalDomain', 'NSAutomaticCapitalizationEnabled'),
        'NSAutomaticSpellingCorrectionEnabled': read_default('NSGlobalDomain', 'NSAutomaticSpellingCorrectionEnabled'),
    },
    'trackpad': {
        'Clicking': read_default('com.apple.AppleMultitouchTrackpad', 'Clicking'),
        'TrackpadThreeFingerDrag': read_default('com.apple.AppleMultitouchTrackpad', 'TrackpadThreeFingerDrag'),
    },
    'security': {
        'GuestEnabled': read_default('com.apple.loginwindow', 'GuestEnabled'),
    },
}
print(json.dumps(defaults))
"
}

collect_dock_apps() {
  if [[ "$OS" != "Darwin" ]]; then echo '[]'; return; fi

  python3 -c "
import subprocess, json, plistlib
try:
    r = subprocess.run(['defaults', 'export', 'com.apple.dock', '-'], capture_output=True, timeout=5)
    plist = plistlib.loads(r.stdout)
    apps = []
    for item in plist.get('persistent-apps', []):
        tile = item.get('tile-data', {})
        label = tile.get('file-label', '')
        path = tile.get('file-data', {}).get('_CFURLString', '')
        if label: apps.append({'label': label, 'path': path})
    print(json.dumps(apps))
except: print('[]')
"
}

collect_cli_tools() {
  python3 -c "
import shutil, json, os
# Skip macOS shim paths that trigger Xcode CLI tools install dialog
shim_dirs = {'/usr/bin/git', '/usr/bin/clang', '/usr/bin/make', '/usr/bin/cc'}
def real_which(name):
    path = shutil.which(name)
    if not path:
        return None
    # /usr/bin/git etc. are shims on macOS — only report if Xcode CLI tools are installed
    if path in shim_dirs or (path.startswith('/usr/bin/') and name in ('git','svn','make','cc','clang','gcc')):
        if not os.path.exists('/Library/Developer/CommandLineTools/usr/bin/' + name):
            return None  # shim only, no real install
    return path
tools = [
    'git', 'node', 'python3', 'rustup', 'go', 'ruby',
    'docker', 'kubectl', 'terraform', 'aws', 'gcloud',
    'brew', 'nix', 'direnv', 'gh', 'jq', 'yq', 'rg', 'fd', 'bat', 'eza',
    'fzf', 'zoxide', 'htop', 'btm', 'tldr', 'tree', 'nmap', 'curl', 'wget',
    'ollama', 'claude', 'code', 'cursor', 'zed',
    'tailscale', 'age', 'sops',
    'supabase', 'railway', 'vercel',
]
found = {}
for t in tools:
    path = real_which(t)
    if path:
        found[t] = path
print(json.dumps(found))
"
}

collect_node_globals() {
  if ! command -v npm &>/dev/null; then echo '[]'; return; fi
  npm list -g --depth=0 --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    deps = d.get('dependencies', {})
    print(json.dumps([{'name': k, 'version': v.get('version', '')} for k, v in deps.items()]))
except: print('[]')
" 2>/dev/null || echo '[]'
}

collect_services() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi

  local brew_services launchd
  brew_services=$(brew services list 2>/dev/null | tail -n +2 | awk '{print $1, $2}' | python3 -c "
import sys, json
svcs = []
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        svcs.append({'name': parts[0], 'status': parts[1]})
print(json.dumps(svcs))
" 2>/dev/null || echo '[]')

  launchd=$(launchctl list 2>/dev/null | grep -v 'com.apple' | grep -v '^-.*0.*$' | tail -n +2 | python3 -c "
import sys, json
svcs = []
for line in sys.stdin:
    parts = line.strip().split('\t')
    if len(parts) >= 3:
        svcs.append({'pid': parts[0], 'label': parts[2]})
print(json.dumps(svcs))
" 2>/dev/null || echo '[]')

  echo "{\"brew_services\": $brew_services, \"launchd\": $launchd}"
}

collect_git_config() {
  python3 -c "
import subprocess, json, os
# Skip if git is just the macOS shim (triggers Xcode install dialog)
if not os.path.exists('/Library/Developer/CommandLineTools/usr/bin/git'):
    git_path = '/usr/bin/git'
    # Check if a real git exists elsewhere in PATH
    import shutil
    found = shutil.which('git')
    if not found or found == '/usr/bin/git':
        print('{}')
        exit(0)
try:
    r = subprocess.run(['git', 'config', '--global', '--list'], capture_output=True, text=True, timeout=5)
    config = {}
    for line in r.stdout.strip().split('\n'):
        if '=' in line:
            k, v = line.split('=', 1)
            config[k] = v
    print(json.dumps(config))
except: print('{}')
"
}

collect_ssh_keys() {
  python3 -c "
import os, json
ssh_dir = os.path.expanduser('~/.ssh')
keys = []
if os.path.isdir(ssh_dir):
    for f in sorted(os.listdir(ssh_dir)):
        if f.endswith('.pub'):
            keys.append(f.replace('.pub', ''))
print(json.dumps(keys))
"
}

collect_docker() {
  if ! command -v docker &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

# Containers (all)
containers = []
out = run(\"docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.State}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 6:
        c = {'id': parts[0], 'name': parts[1], 'image': parts[2], 'status': parts[3], 'ports': parts[4], 'state': parts[5]}
        # Get restart policy
        rp = run(f\"docker inspect {parts[0]} --format '{{{{.HostConfig.RestartPolicy.Name}}}}'\")
        if rp: c['restart_policy'] = rp
        containers.append(c)

# Images
images = []
out = run(\"docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 4:
        images.append({'repository': parts[0], 'tag': parts[1], 'id': parts[2], 'size': parts[3]})

# Volumes
volumes = []
out = run(\"docker volume ls --format '{{.Name}}\t{{.Driver}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 2:
        volumes.append({'name': parts[0], 'driver': parts[1]})

# Networks (non-default)
networks = []
out = run(\"docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 3 and parts[0] not in ('bridge', 'host', 'none'):
        networks.append({'name': parts[0], 'driver': parts[1], 'scope': parts[2]})

# Compose projects
compose_projects = []
out = run('docker compose ls --format table 2>/dev/null')
for line in out.split('\n')[1:]:
    if not line.strip(): continue
    parts = line.split()
    if len(parts) >= 2:
        compose_projects.append({'name': parts[0], 'status': parts[1]})

print(json.dumps({
    'installed': True,
    'containers': containers,
    'container_count': len(containers),
    'images': images,
    'image_count': len(images),
    'volumes': volumes,
    'networks': networks,
    'compose_projects': compose_projects,
}))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_nix_state() {
  if ! command -v nix &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# Nix version
result['version'] = run('nix --version').replace('nix (Nix) ', '')

# Current system generation (NixOS or nix-darwin)
gen = run('darwin-rebuild --list-generations 2>/dev/null | tail -1') or run('nixos-rebuild list-generations 2>/dev/null | tail -1')
if gen: result['current_generation'] = gen.strip()

# Home-manager generation
hm_gen = run('home-manager generations 2>/dev/null | head -1')
if hm_gen: result['home_manager_generation'] = hm_gen.strip()

# Nix channels or flake inputs
channels = run('nix-channel --list 2>/dev/null')
if channels:
    result['channels'] = [{'name': l.split()[0], 'url': l.split()[1]} for l in channels.split('\n') if len(l.split()) >= 2]

# Flake lock info (if flake.nix exists in dotfiles)
for flake_dir in [os.path.expanduser('~/dotfiles'), os.path.expanduser('~/.config/nix-darwin')]:
    lock = os.path.join(flake_dir, 'flake.lock')
    if os.path.isfile(lock):
        try:
            with open(lock) as f:
                lock_data = json.load(f)
            nodes = lock_data.get('nodes', {})
            inputs = {}
            for name, node in nodes.items():
                if name == 'root': continue
                locked = node.get('locked', {})
                if locked:
                    inputs[name] = {
                        'type': locked.get('type', ''),
                        'rev': locked.get('rev', '')[:12],
                        'last_modified': locked.get('lastModified', ''),
                    }
            if inputs:
                result['flake_inputs'] = inputs
                result['flake_dir'] = flake_dir
        except: pass
        break

# Nix store size
store_size = run('du -sh /nix/store 2>/dev/null | cut -f1')
if store_size: result['store_size'] = store_size.strip()

# Nix profile packages
profile_pkgs = run('nix profile list 2>/dev/null')
if profile_pkgs:
    pkgs = []
    for line in profile_pkgs.split('\n'):
        if line.strip():
            parts = line.split()
            if len(parts) >= 2:
                pkgs.append(parts[-1].split('#')[-1] if '#' in parts[-1] else parts[-1])
    if pkgs: result['profile_packages'] = pkgs

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_ai_infrastructure() {
  python3 -c "
import subprocess, json, re

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Ollama models
ollama_out = run('ollama list 2>/dev/null')
if ollama_out:
    models = []
    for line in ollama_out.split('\n')[1:]:
        if not line.strip(): continue
        parts = line.split()
        if len(parts) >= 3:
            models.append({'name': parts[0], 'id': parts[1], 'size': parts[2]})
    result['ollama'] = {'running': True, 'models': models, 'model_count': len(models)}

    # Running models
    ps_out = run('ollama ps 2>/dev/null')
    if ps_out:
        running = []
        for line in ps_out.split('\n')[1:]:
            if not line.strip(): continue
            parts = line.split()
            if parts: running.append(parts[0])
        result['ollama']['running_models'] = running

# LM Studio models
import os
lm_dir = os.path.expanduser('~/.cache/lm-studio/models')
if os.path.isdir(lm_dir):
    models = []
    for root, dirs, files in os.walk(lm_dir):
        for f in files:
            if f.endswith('.gguf'):
                path = os.path.join(root, f)
                size_gb = round(os.path.getsize(path) / (1024**3), 1)
                models.append({'name': f, 'size_gb': size_gb})
    result['lm_studio'] = {'models': models, 'model_count': len(models)}

# llama-server / llama.cpp instances
llama_procs = run(\"ps aux | grep -E 'llama[_-]server|llama\\.cpp' | grep -v grep\")
if llama_procs:
    instances = []
    for line in llama_procs.split('\n'):
        if not line.strip(): continue
        parts = line.split()
        pid = parts[1]
        cmd = ' '.join(parts[10:])
        # Extract port if present
        port_match = re.search(r'--port\s+(\d+)', cmd) or re.search(r'-p\s+(\d+)', cmd)
        port = port_match.group(1) if port_match else None
        # Extract model if present
        model_match = re.search(r'(?:-m|--model)\s+(\S+)', cmd)
        model = os.path.basename(model_match.group(1)) if model_match else None
        instances.append({'pid': pid, 'port': port, 'model': model})
    result['llama_server'] = {'instances': instances}

# GPU info (macOS Metal / NVIDIA)
import platform
if platform.system() == 'Darwin':
    gpu = run('system_profiler SPDisplaysDataType 2>/dev/null | grep -E \"Chipset|VRAM|Metal\"')
    if gpu:
        result['gpu'] = {'info': [l.strip() for l in gpu.split('\n') if l.strip()]}
    # Unified memory available
    mem = run('sysctl -n hw.memsize 2>/dev/null')
    if mem:
        result['gpu_memory_gb'] = round(int(mem) / (1024**3))
else:
    nvidia = run('nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null')
    if nvidia:
        gpus = []
        for line in nvidia.split('\n'):
            if not line.strip(): continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 4:
                gpus.append({'name': parts[0], 'memory_total_mb': int(parts[1]), 'memory_used_mb': int(parts[2]), 'utilization_pct': int(parts[3])})
        result['gpu'] = {'nvidia': gpus}
    # Jetson-specific
    jetson = run('cat /proc/device-tree/model 2>/dev/null')
    if 'jetson' in jetson.lower():
        result['gpu']['jetson_model'] = jetson

if not result:
    print('{}')
else:
    print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_security_posture() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

if platform.system() == 'Darwin':
    # FileVault (disk encryption)
    fv = run('fdesetup status 2>/dev/null')
    result['filevault'] = 'On' in fv if fv else None

    # Firewall
    fw = run('/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null')
    result['firewall'] = 'enabled' in fw.lower() if fw else None

    # SIP (System Integrity Protection)
    sip = run('csrutil status 2>/dev/null')
    result['sip_enabled'] = 'enabled' in sip.lower() if sip else None

    # Gatekeeper
    gk = run('spctl --status 2>/dev/null')
    result['gatekeeper'] = 'enabled' in (gk or '').lower()

    # Auto-login disabled
    autologin = run('defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null')
    result['auto_login_disabled'] = autologin == ''

    # Remote login (SSH)
    ssh_status = run('systemsetup -getremotelogin 2>/dev/null')
    result['remote_login'] = 'On' in ssh_status if ssh_status else None

else:
    # Linux: UFW or iptables
    ufw = run('ufw status 2>/dev/null')
    if ufw:
        result['ufw'] = 'active' in ufw.lower()
    else:
        iptables_rules = run('iptables -L -n 2>/dev/null | wc -l')
        result['iptables_rules'] = int(iptables_rules) if iptables_rules.isdigit() else 0

    # Disk encryption (LUKS)
    luks = run('lsblk -o NAME,FSTYPE 2>/dev/null | grep crypto_LUKS')
    result['disk_encryption'] = bool(luks)

    # SELinux / AppArmor
    selinux = run('getenforce 2>/dev/null')
    if selinux: result['selinux'] = selinux
    apparmor = run('aa-status --enabled 2>/dev/null')
    if 'Yes' in (apparmor or ''): result['apparmor'] = True

    # SSH config
    sshd = run('systemctl is-active sshd 2>/dev/null')
    result['sshd_active'] = sshd == 'active'

# Age key presence
age_key = os.path.expanduser('~/.config/sops/age/keys.txt')
result['age_key_present'] = os.path.isfile(age_key)
if os.path.isfile(age_key):
    pub = run(f'grep -o \"age1[a-z0-9]*\" {age_key} | head -1')
    if pub: result['age_public_key'] = pub

# SOPS config
for sops_path in ['.sops.yaml', os.path.expanduser('~/dotfiles/.sops.yaml')]:
    if os.path.isfile(sops_path):
        result['sops_config_present'] = True
        break
else:
    result['sops_config_present'] = False

# SSH authorized_keys count
auth_keys = os.path.expanduser('~/.ssh/authorized_keys')
if os.path.isfile(auth_keys):
    with open(auth_keys) as f:
        result['authorized_keys_count'] = len([l for l in f if l.strip() and not l.startswith('#')])

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_tailscale() {
  if ! command -v tailscale &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# Version
result['version'] = run('tailscale version 2>/dev/null').split('\n')[0]

# IP
result['ip'] = run('tailscale ip -4 2>/dev/null')

# Self status
status_json = run('tailscale status --self --json 2>/dev/null')
if status_json:
    try:
        st = json.loads(status_json)
        self_node = st.get('Self', {})
        result['hostname'] = self_node.get('HostName', '')
        result['dns_name'] = self_node.get('DNSName', '').rstrip('.')
        result['os'] = self_node.get('OS', '')
        result['online'] = self_node.get('Online', False)
        result['tags'] = self_node.get('Tags', [])
        result['key_expiry'] = self_node.get('KeyExpiry', '')
        result['created'] = self_node.get('Created', '')
        result['is_exit_node'] = self_node.get('ExitNode', False)
        result['advertised_routes'] = self_node.get('AllowedIPs', [])

        # Tailnet info
        result['magic_dns_suffix'] = st.get('MagicDNSSuffix', '')
        result['current_tailnet'] = st.get('CurrentTailnet', {}).get('Name', '')
    except: pass

# Exit node in use
exit_node = run('tailscale exit-node status 2>/dev/null')
if exit_node and 'not using' not in exit_node.lower():
    result['using_exit_node'] = exit_node

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_crontabs() {
  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# User crontab
crontab = run('crontab -l 2>/dev/null')
if crontab:
    entries = [l.strip() for l in crontab.split('\n') if l.strip() and not l.startswith('#')]
    result['user_crontab'] = entries
    result['user_crontab_count'] = len(entries)
else:
    result['user_crontab'] = []
    result['user_crontab_count'] = 0

# System crontab entries (non-comment)
sys_crontab = run('cat /etc/crontab 2>/dev/null')
if sys_crontab:
    entries = [l.strip() for l in sys_crontab.split('\n') if l.strip() and not l.startswith('#')]
    result['system_crontab'] = entries

# Cron.d entries
cron_d = '/etc/cron.d'
if os.path.isdir(cron_d):
    result['cron_d_files'] = [f for f in os.listdir(cron_d) if not f.startswith('.')]

# Systemd timers (Linux)
timers = run('systemctl list-timers --no-pager --no-legend 2>/dev/null')
if timers:
    result['systemd_timers'] = []
    for line in timers.split('\n'):
        parts = line.split()
        if len(parts) >= 2:
            result['systemd_timers'].append(parts[-1])  # unit name is last

# launchd user agents with schedule (macOS)
import platform
if platform.system() == 'Darwin':
    agent_dir = os.path.expanduser('~/Library/LaunchAgents')
    if os.path.isdir(agent_dir):
        agents = []
        for f in os.listdir(agent_dir):
            if f.endswith('.plist'):
                content = run(f'defaults read {os.path.join(agent_dir, f)} 2>/dev/null')
                if 'StartInterval' in content or 'StartCalendarInterval' in content:
                    agents.append(f.replace('.plist', ''))
        if agents: result['launchd_scheduled_agents'] = agents

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_resource_usage() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Load average
load = run('sysctl -n vm.loadavg 2>/dev/null') or run('cat /proc/loadavg 2>/dev/null')
if load:
    parts = load.replace('{', '').replace('}', '').split()
    if len(parts) >= 3:
        result['load_average'] = {'1m': float(parts[0]), '5m': float(parts[1]), '15m': float(parts[2])}

# Memory
if platform.system() == 'Darwin':
    mem_total = int(run('sysctl -n hw.memsize') or '0')
    # vm_stat for memory pressure
    vm_stat = run('vm_stat')
    page_size = 16384  # Apple Silicon
    if vm_stat:
        import re
        free = re.search(r'Pages free:\s+(\d+)', vm_stat)
        active = re.search(r'Pages active:\s+(\d+)', vm_stat)
        inactive = re.search(r'Pages inactive:\s+(\d+)', vm_stat)
        wired = re.search(r'Pages wired down:\s+(\d+)', vm_stat)
        compressed = re.search(r'Pages occupied by compressor:\s+(\d+)', vm_stat)
        result['memory'] = {
            'total_gb': round(mem_total / (1024**3), 1),
            'free_pages': int(free.group(1)) if free else 0,
            'active_pages': int(active.group(1)) if active else 0,
            'wired_pages': int(wired.group(1)) if wired else 0,
            'compressed_pages': int(compressed.group(1)) if compressed else 0,
        }
else:
    meminfo = run('cat /proc/meminfo')
    if meminfo:
        mem = {}
        for line in meminfo.split('\n'):
            parts = line.split(':')
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip().split()[0]
                if key in ('MemTotal', 'MemFree', 'MemAvailable', 'SwapTotal', 'SwapFree'):
                    mem[key] = round(int(val) / (1024*1024), 1)  # GB
        result['memory'] = mem

# Swap
swap = run('sysctl -n vm.swapusage 2>/dev/null')
if swap:
    import re
    total = re.search(r'total\s*=\s*([\d.]+)M', swap)
    used = re.search(r'used\s*=\s*([\d.]+)M', swap)
    if total and used:
        result['swap'] = {'total_mb': float(total.group(1)), 'used_mb': float(used.group(1))}

# Disk usage by key directories
dirs_to_check = {
    '/nix/store': '/nix/store',
    'home': os.path.expanduser('~'),
    'docker': '/var/lib/docker',
}
# Add common cache dirs
cache_dir = os.path.expanduser('~/.cache')
if os.path.isdir(cache_dir):
    dirs_to_check['cache'] = cache_dir

disk_usage = {}
for label, path in dirs_to_check.items():
    if os.path.isdir(path):
        size = run(f'du -sh {path} 2>/dev/null | cut -f1')
        if size: disk_usage[label] = size.strip()
result['disk_by_directory'] = disk_usage

# Root disk
df = run('df -h / | tail -1')
if df:
    parts = df.split()
    if len(parts) >= 5:
        result['root_disk'] = {'total': parts[1], 'used': parts[2], 'available': parts[3], 'percent_used': parts[4]}

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_shell_env() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# Shell
result['shell'] = os.environ.get('SHELL', '')

# PATH entries (deduplicated, in order)
path_entries = []
seen = set()
for p in os.environ.get('PATH', '').split(':'):
    if p and p not in seen:
        path_entries.append(p)
        seen.add(p)
result['path_entries'] = path_entries

# Zsh plugins (oh-my-zsh or zinit/zplug)
zshrc = os.path.expanduser('~/.zshrc')
if os.path.isfile(zshrc):
    with open(zshrc) as f:
        content = f.read()
    import re
    # oh-my-zsh plugins
    match = re.search(r'plugins=\(([^)]+)\)', content)
    if match:
        result['zsh_plugins'] = match.group(1).split()
    # zinit/zplug
    zinit = re.findall(r'zinit\s+(?:light|load)\s+(\S+)', content)
    if zinit: result['zinit_plugins'] = zinit
    zplug = re.findall(r'zplug\s+[\"\\'](\S+)[\"\\']', content)
    if zplug: result['zplug_plugins'] = zplug

# Starship config exists
if os.path.isfile(os.path.expanduser('~/.config/starship.toml')):
    result['starship'] = True

# Custom aliases count
aliases = run('alias 2>/dev/null')
if aliases:
    result['alias_count'] = len(aliases.split('\n'))

# Tmux config
if os.path.isfile(os.path.expanduser('~/.tmux.conf')):
    result['tmux_config'] = True

# Direnv
if os.path.isfile(os.path.expanduser('~/.direnvrc')) or os.path.isfile(os.path.expanduser('~/.config/direnv/direnvrc')):
    result['direnv_config'] = True

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_editor_extensions() {
  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# VS Code extensions
vscode = run('code --list-extensions 2>/dev/null')
if vscode:
    result['vscode'] = sorted(vscode.split('\n'))
    result['vscode_count'] = len(result['vscode'])

# Cursor extensions
cursor = run('cursor --list-extensions 2>/dev/null')
if cursor:
    result['cursor'] = sorted(cursor.split('\n'))
    result['cursor_count'] = len(result['cursor'])

# Zed extensions
zed_ext_dir = os.path.expanduser('~/.config/zed/extensions')
if os.path.isdir(zed_ext_dir):
    exts = [d for d in os.listdir(zed_ext_dir) if os.path.isdir(os.path.join(zed_ext_dir, d)) and not d.startswith('.')]
    if exts:
        result['zed'] = sorted(exts)
        result['zed_count'] = len(exts)

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_toolchains() {
  python3 -c "
import subprocess, json, os, shutil

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Python: pip global packages
if shutil.which('pip3'):
    pip_out = run('pip3 list --format=json 2>/dev/null')
    if pip_out:
        try:
            pkgs = json.loads(pip_out)
            result['python_packages'] = [{'name': p['name'], 'version': p['version']} for p in pkgs]
            result['python_package_count'] = len(pkgs)
        except: pass
    result['python_version'] = run('python3 --version 2>/dev/null').replace('Python ', '')

# Rust: cargo-installed binaries
cargo_bin = os.path.expanduser('~/.cargo/bin')
if os.path.isdir(cargo_bin):
    bins = [f for f in os.listdir(cargo_bin) if os.path.isfile(os.path.join(cargo_bin, f)) and not f.startswith('.')]
    result['cargo_binaries'] = sorted(bins)
    result['cargo_binary_count'] = len(bins)
    result['rust_version'] = run('rustc --version 2>/dev/null').replace('rustc ', '')

# Go: installed binaries
go_bin = os.path.expanduser('~/go/bin')
if os.path.isdir(go_bin):
    bins = [f for f in os.listdir(go_bin) if os.path.isfile(os.path.join(go_bin, f))]
    result['go_binaries'] = sorted(bins)
    result['go_binary_count'] = len(bins)
    result['go_version'] = run('go version 2>/dev/null').split()[-2] if shutil.which('go') else ''

# Ruby: gem list
if shutil.which('gem'):
    gems = run('gem list --no-versions 2>/dev/null')
    if gems:
        result['ruby_gems'] = sorted(gems.split('\n'))
        result['ruby_gem_count'] = len(result['ruby_gems'])

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_certificates() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

if platform.system() == 'Darwin':
    # Custom certs in system keychain
    certs = run('security find-certificate -a /Library/Keychains/System.keychain 2>/dev/null | grep -c \"labl\"')
    if certs and certs.isdigit(): result['system_keychain_certs'] = int(certs)

    # User-added trust overrides
    custom = run('security dump-trust-settings 2>/dev/null | grep -c \"Cert\"')
    if custom and custom.isdigit(): result['custom_trust_settings'] = int(custom)
else:
    # Linux CA bundle
    ca_dir = '/etc/ssl/certs'
    if os.path.isdir(ca_dir):
        result['ca_cert_count'] = len([f for f in os.listdir(ca_dir) if f.endswith('.pem') or f.endswith('.crt')])

    # Custom certs in /usr/local/share/ca-certificates
    custom_dir = '/usr/local/share/ca-certificates'
    if os.path.isdir(custom_dir):
        custom = [f for f in os.listdir(custom_dir) if f.endswith('.crt')]
        if custom:
            result['custom_certs'] = custom
            result['custom_cert_count'] = len(custom)

# Check for mkcert
import shutil
if shutil.which('mkcert'):
    result['mkcert_installed'] = True
    caroot = run('mkcert -CAROOT 2>/dev/null')
    if caroot and os.path.isdir(caroot):
        result['mkcert_ca_exists'] = True

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_orbstack() {
  if ! command -v orb &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# VM list with details
orb_json = run('orb list --format json 2>/dev/null')
if orb_json:
    try:
        vms = json.loads(orb_json)
        result['machines'] = []
        for vm in vms:
            machine = {
                'name': vm.get('name', ''),
                'state': vm.get('state', ''),
                'os': vm.get('os', ''),
                'arch': vm.get('arch', ''),
                'image': vm.get('image', ''),
            }
            # CPU and memory if available
            if 'cpu' in vm: machine['cpu'] = vm['cpu']
            if 'memory' in vm: machine['memory'] = vm['memory']
            if 'disk' in vm: machine['disk'] = vm['disk']
            result['machines'].append(machine)
        result['machine_count'] = len(result['machines'])
    except:
        orb_text = run('orb list 2>/dev/null')
        if orb_text: result['raw'] = orb_text

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_fonts() {
  if [[ "$OS" != "Darwin" ]]; then echo '[]'; return; fi
  python3 -c "
import os, json
font_dirs = [
    os.path.expanduser('~/Library/Fonts'),
    '/Library/Fonts',
    '/Library/Fonts/Nix Fonts',
]
fonts = set()
for d in font_dirs:
    if os.path.isdir(d):
        for f in os.listdir(d):
            if any(f.endswith(e) for e in ['.ttf', '.otf', '.ttc', '.dfont']):
                fonts.add(f.rsplit('.', 1)[0])
print(json.dumps(sorted(fonts)))
"
}

collect_login_items() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi
  python3 -c "
import subprocess, json, plistlib, os

result = {}

# Login items via osascript
try:
    r = subprocess.run(['osascript', '-e', 'tell application \"System Events\" to get the name of every login item'],
                       capture_output=True, text=True, timeout=10)
    items = [i.strip() for i in r.stdout.strip().split(',') if i.strip()]
    result['login_items'] = items
except: result['login_items'] = []

# Launch agents (user)
user_agents = os.path.expanduser('~/Library/LaunchAgents')
if os.path.isdir(user_agents):
    result['user_launch_agents'] = sorted([f.replace('.plist', '') for f in os.listdir(user_agents) if f.endswith('.plist')])

# Launch daemons (system, third-party)
for label, path in [('system_launch_agents', '/Library/LaunchAgents'), ('system_launch_daemons', '/Library/LaunchDaemons')]:
    if os.path.isdir(path):
        result[label] = sorted([f.replace('.plist', '') for f in os.listdir(path) if f.endswith('.plist')])

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_macos_settings() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi
  python3 -c "
import subprocess, json

def read_default(domain, key):
    try:
        r = subprocess.run(['defaults', 'read', domain, key], capture_output=True, text=True, timeout=2)
        v = r.stdout.strip()
        if v.isdigit(): return int(v)
        if v in ('true', '1'): return True
        if v in ('false', '0'): return False
        return v
    except: return None

settings = {
    'appearance': {
        'dark_mode': read_default('NSGlobalDomain', 'AppleInterfaceStyle'),
        'accent_color': read_default('NSGlobalDomain', 'AppleAccentColor'),
        'highlight_color': read_default('NSGlobalDomain', 'AppleHighlightColor'),
        'sidebar_icon_size': read_default('NSGlobalDomain', 'NSTableViewDefaultSizeMode'),
        'reduce_motion': read_default('com.apple.universalaccess', 'reduceMotion'),
        'reduce_transparency': read_default('com.apple.universalaccess', 'reduceTransparency'),
    },
    'mouse_trackpad': {
        'scroll_direction_natural': read_default('NSGlobalDomain', 'com.apple.swipescrolldirection'),
        'mouse_scaling': read_default('NSGlobalDomain', 'com.apple.mouse.scaling'),
        'trackpad_speed': read_default('NSGlobalDomain', 'com.apple.trackpad.scaling'),
        'tap_to_click': read_default('com.apple.AppleMultitouchTrackpad', 'Clicking'),
        'three_finger_drag': read_default('com.apple.AppleMultitouchTrackpad', 'TrackpadThreeFingerDrag'),
        'secondary_click': read_default('com.apple.AppleMultitouchTrackpad', 'TrackpadRightClick'),
    },
    'energy': {
        'display_sleep_minutes': read_default('com.apple.screensaver', 'idleTime'),
        'screen_saver_delay': read_default('com.apple.screensaver', 'askForPasswordDelay'),
    },
    'desktop_screensaver': {
        'screensaver_name': read_default('com.apple.screensaver', 'moduleDict'),
    },
    'menu_bar': {
        'auto_hide': read_default('NSGlobalDomain', '_HIHideMenuBar'),
        'clock_format': read_default('com.apple.menuextra.clock', 'DateFormat'),
        'battery_percentage': read_default('com.apple.menuextra.battery', 'ShowPercent'),
    },
    'hot_corners': {
        'top_left': read_default('com.apple.dock', 'wvous-tl-corner'),
        'top_right': read_default('com.apple.dock', 'wvous-tr-corner'),
        'bottom_left': read_default('com.apple.dock', 'wvous-bl-corner'),
        'bottom_right': read_default('com.apple.dock', 'wvous-br-corner'),
    },
    'spotlight': {
        'orderedItems': read_default('com.apple.Spotlight', 'orderedItems'),
    },
    'text_input': {
        'languages': read_default('NSGlobalDomain', 'AppleLanguages'),
        'locale': read_default('NSGlobalDomain', 'AppleLocale'),
        'measurement_units': read_default('NSGlobalDomain', 'AppleMeasurementUnits'),
        'temperature_unit': read_default('NSGlobalDomain', 'AppleTemperatureUnit'),
        'auto_correct': read_default('NSGlobalDomain', 'NSAutomaticSpellingCorrectionEnabled'),
        'auto_capitalize': read_default('NSGlobalDomain', 'NSAutomaticCapitalizationEnabled'),
        'smart_quotes': read_default('NSGlobalDomain', 'NSAutomaticQuoteSubstitutionEnabled'),
        'smart_dashes': read_default('NSGlobalDomain', 'NSAutomaticDashSubstitutionEnabled'),
    },
}
print(json.dumps(settings))
" 2>/dev/null || echo '{}'
}

collect_user_accounts() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi
  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

# List local user accounts (UID >= 500, not system)
users_raw = run('dscl . -list /Users UniqueID')
users = []
for line in users_raw.split('\n'):
    parts = line.split()
    if len(parts) == 2 and int(parts[1]) >= 500 and not parts[0].startswith('_'):
        name = parts[0]
        realname = run(f'dscl . -read /Users/{name} RealName 2>/dev/null').replace('RealName:', '').replace('\\n', '').strip()
        users.append({'username': name, 'uid': int(parts[1]), 'realname': realname})

result = {
    'users': users,
    'current_user': run('whoami'),
    'computer_name': run('scutil --get ComputerName'),
    'local_hostname': run('scutil --get LocalHostName'),
}
print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_wifi_networks() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi
  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# Known Wi-Fi networks (names only, not passwords)
networks_raw = run('networksetup -listpreferredwirelessnetworks en0 2>/dev/null')
if networks_raw:
    networks = [n.strip() for n in networks_raw.split('\n')[1:] if n.strip()]
    result['known_networks'] = networks

# Current Wi-Fi
current = run('/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null')
for line in current.split('\n'):
    if 'SSID' in line and 'BSSID' not in line:
        result['current_ssid'] = line.split(':',1)[1].strip()
        break

# Network services
services = run('networksetup -listallnetworkservices 2>/dev/null')
if services:
    result['network_services'] = [s.strip() for s in services.split('\n')[1:] if s.strip() and not s.startswith('*')]

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_printers() {
  if [[ "$OS" != "Darwin" ]]; then echo '[]'; return; fi
  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

printers = []
lpstat = run('lpstat -a 2>/dev/null')
for line in lpstat.split('\n'):
    if line.strip():
        name = line.split()[0]
        printers.append(name)

print(json.dumps(printers))
" 2>/dev/null || echo '[]'
}

collect_browser_extensions() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi
  python3 -c "
import os, json, plistlib, glob

result = {}

# Chrome extensions
chrome_ext_dir = os.path.expanduser('~/Library/Application Support/Google/Chrome/Default/Extensions')
if os.path.isdir(chrome_ext_dir):
    exts = []
    for ext_id in os.listdir(chrome_ext_dir):
        ext_path = os.path.join(chrome_ext_dir, ext_id)
        if os.path.isdir(ext_path) and not ext_id.startswith('.'):
            # Try to get name from manifest
            versions = sorted(os.listdir(ext_path))
            for v in reversed(versions):
                manifest = os.path.join(ext_path, v, 'manifest.json')
                if os.path.isfile(manifest):
                    try:
                        with open(manifest) as f:
                            m = json.load(f)
                            name = m.get('name', ext_id)
                            if not name.startswith('__MSG_'):
                                exts.append(name)
                            else:
                                exts.append(ext_id)
                    except: exts.append(ext_id)
                    break
    result['chrome'] = sorted(exts)
    result['chrome_count'] = len(exts)

# Safari extensions
safari_ext = os.path.expanduser('~/Library/Safari/Extensions')
if os.path.isdir(safari_ext):
    exts = [f.replace('.safariextz', '').replace('.appex', '') for f in os.listdir(safari_ext) if not f.startswith('.')]
    if exts:
        result['safari'] = sorted(exts)
        result['safari_count'] = len(exts)

# Firefox profiles (list extension IDs)
ff_profiles = glob.glob(os.path.expanduser('~/Library/Application Support/Firefox/Profiles/*.default*/extensions.json'))
for profile in ff_profiles[:1]:
    try:
        with open(profile) as f:
            data = json.load(f)
            addons = [a.get('defaultLocale', {}).get('name', a.get('id', ''))
                      for a in data.get('addons', [])
                      if a.get('type') == 'extension' and a.get('active')]
            if addons:
                result['firefox'] = sorted(addons)
                result['firefox_count'] = len(addons)
    except: pass

# Arc extensions (Chromium-based, same path structure)
arc_ext_dir = os.path.expanduser('~/Library/Application Support/Arc/User Data/Default/Extensions')
if os.path.isdir(arc_ext_dir):
    exts = []
    for ext_id in os.listdir(arc_ext_dir):
        ext_path = os.path.join(arc_ext_dir, ext_id)
        if os.path.isdir(ext_path) and not ext_id.startswith('.'):
            versions = sorted(os.listdir(ext_path))
            for v in reversed(versions):
                manifest = os.path.join(ext_path, v, 'manifest.json')
                if os.path.isfile(manifest):
                    try:
                        with open(manifest) as f:
                            m = json.load(f)
                            name = m.get('name', ext_id)
                            if not name.startswith('__MSG_'):
                                exts.append(name)
                            else:
                                exts.append(ext_id)
                    except: exts.append(ext_id)
                    break
    if exts:
        result['arc'] = sorted(exts)
        result['arc_count'] = len(exts)

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

# Note: collect_docker, collect_orbstack, collect_ollama are defined above
# (comprehensive versions in the main collector section)

# ══════════════════════════════════════════════════════════════════════════
# Assemble full audit
# ══════════════════════════════════════════════════════════════════════════

echo "Auditing $HOSTNAME ($OS/$ARCH)..." >&2

AUDIT=$(python3 -c "
import json, sys

sections = {}
for line in sys.stdin:
    line = line.strip()
    if line.startswith('---SECTION:'):
        current = line.replace('---SECTION:', '').strip()
        sections[current] = ''
    elif 'current' in dir():
        sections[current] += line + '\n'

result = {}
for name, data in sections.items():
    try:
        result[name] = json.loads(data.strip())
    except:
        result[name] = data.strip()

print(json.dumps(result, indent=2))
" <<AUDIT_DATA
---SECTION: system
$(collect_system)
---SECTION: homebrew
$(collect_homebrew)
---SECTION: mas_apps
$(collect_mas)
---SECTION: applications
$(collect_applications)
---SECTION: macos_defaults
$(collect_macos_defaults)
---SECTION: dock_apps
$(collect_dock_apps)
---SECTION: cli_tools
$(collect_cli_tools)
---SECTION: node_globals
$(collect_node_globals)
---SECTION: services
$(collect_services)
---SECTION: git_config
$(collect_git_config)
---SECTION: ssh_keys
$(collect_ssh_keys)
---SECTION: fonts
$(collect_fonts)
---SECTION: docker
$(collect_docker)
---SECTION: orbstack
$(collect_orbstack)
---SECTION: nix
$(collect_nix_state)
---SECTION: ai_infrastructure
$(collect_ai_infrastructure)
---SECTION: security
$(collect_security_posture)
---SECTION: tailscale
$(collect_tailscale)
---SECTION: crontabs
$(collect_crontabs)
---SECTION: resource_usage
$(collect_resource_usage)
---SECTION: shell_env
$(collect_shell_env)
---SECTION: editor_extensions
$(collect_editor_extensions)
---SECTION: toolchains
$(collect_toolchains)
---SECTION: certificates
$(collect_certificates)
---SECTION: login_items
$(collect_login_items)
---SECTION: macos_settings
$(collect_macos_settings)
---SECTION: user_accounts
$(collect_user_accounts)
---SECTION: wifi_networks
$(collect_wifi_networks)
---SECTION: printers
$(collect_printers)
---SECTION: browser_extensions
$(collect_browser_extensions)
AUDIT_DATA
)

# ── Device registration (replaces heartbeat.sh) ───────────────────────
# Read this device's currently-assigned role from the config service.
# Echoes the role, or empty string if the device isn't registered yet /
# the service is unreachable (callers decide the default).
fetch_device_role() {
  local config_url="$1"
  curl -sf "${config_url}/api/devices/${HOSTNAME}" --max-time 5 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('role','') or '')" 2>/dev/null
}

register_device() {
  local config_url="$1"
  local ts_ip="" ssh_pub="" age_pub="" uptime_str="" nix_ver="" nix_gen=""

  ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
  nix_ver=$(nix --version 2>/dev/null || echo "")
  uptime_str=$(uptime | sed 's/.*up //' | sed 's/,.*//')

  if [[ "$OS" == "Darwin" ]]; then
    nix_gen=$(darwin-rebuild --list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
  else
    nix_gen=$(nixos-rebuild list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
  fi

  for keyfile in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$keyfile" ]]; then ssh_pub=$(cat "$keyfile"); break; fi
  done

  if [[ -f "$HOME/.config/sops/age/keys.txt" ]]; then
    age_pub=$(age-keygen -y "$HOME/.config/sops/age/keys.txt" 2>/dev/null || echo "")
  fi

  # Preserve an already-assigned role — the audit script is an inventory
  # reporter, not the role authority, so it must not reset role on every run.
  # Default to "workstation" only for a brand-new (never-registered) device.
  local role
  role=$(fetch_device_role "$config_url")
  [[ -z "$role" ]] && role="workstation"

  curl -sf -X POST "${config_url}/api/devices/register" \
    -H "Content-Type: application/json" \
    -d "{
      \"hostname\": \"$HOSTNAME\",
      \"os\": \"$OS\",
      \"arch\": \"$ARCH\",
      \"role\": \"$role\",
      \"tailscale_ip\": \"$ts_ip\",
      \"nix_version\": \"$nix_ver\",
      \"nix_generation\": \"$nix_gen\",
      \"ssh_public_key\": \"$ssh_pub\",
      \"age_public_key\": \"$age_pub\"
    }" --max-time 5 >/dev/null 2>&1
}

# ── Post-setup checklist ───────────────────────────────────────────────
show_checklist() {
  local config_url="$1"
  local role
  role=$(fetch_device_role "$config_url")
  [[ -z "$role" ]] && role="workstation"

  local checklist
  checklist=$(curl -sf "${config_url}/api/fleet/checklist/${role}" --max-time 5 2>/dev/null)
  [[ -z "$checklist" ]] && return

  echo "" >&2
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}" >&2
  echo -e "${BOLD}${CYAN}│       Post-Setup Checklist               │${NC}" >&2
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}" >&2

  for cat in "sign-in" "permissions" "setup" "verify"; do
    local items
    items=$(echo "$checklist" | python3 -c "
import json, sys
data = json.load(sys.stdin)
steps = [s for s in data.get('steps', []) if s['category'] == '$cat']
if steps:
    print('${cat^^}')
    for s in steps:
        notes = f\"  ({s['notes']})\" if s.get('notes') else ''
        print(f\"  [ ] {s['app']}: {s['action']}{notes}\")
" 2>/dev/null)
    if [[ -n "$items" ]]; then
      echo "" >&2
      echo -e "${BOLD}${items%%$'\n'*}${NC}" >&2
      echo "$items" | tail -n +2 >&2
    fi
  done
  echo "" >&2
}

# ── Output based on mode ────────────────────────────────────────────────
case "$MODE" in
  --local)
    echo "$AUDIT"
    ;;
  --save)
    SAVE_DIR="$HOME/dotfiles-backups/audit"
    mkdir -p "$SAVE_DIR"
    echo "$AUDIT" > "$SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json"
    ok "Saved to $SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json" >&2
    ;;
  --run|--run-and-install|report)
    # Upload audit + register device
    CONFIG_URL=$(find_config_service)
    if [[ -n "$CONFIG_URL" ]]; then
      curl -sf -X POST "${CONFIG_URL}/api/audit/${HOSTNAME}" \
        -H "Content-Type: application/json" \
        -d "$AUDIT" --max-time 10 >/dev/null 2>&1 \
        && ok "Audit uploaded to fleet" >&2 \
        || warn "Audit upload failed" >&2
      register_device "$CONFIG_URL" \
        && ok "Device registered with fleet" >&2 \
        || warn "Device registration failed" >&2
      # Show checklist in interactive mode (not cron)
      if [[ -t 1 || "$MODE" == "--run-and-install" ]] && [[ -z "${CRON_TAG_PRESENT:-}" ]]; then
        show_checklist "$CONFIG_URL"
      fi
    else
      warn "Config service not reachable — printing audit locally" >&2
      echo "$AUDIT"
    fi
    # Install cron if requested
    if [[ "$MODE" == "--run-and-install" ]]; then
      install_cron
    fi
    ;;
esac
