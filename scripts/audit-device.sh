#!/usr/bin/env bash
# Audit a device's current state — non-destructive inventory collection.
# Sends results to the config service for cross-device comparison.
#
# Usage:
#   ./scripts/audit-device.sh              # audit and report
#   ./scripts/audit-device.sh --local      # audit only, print JSON (no upload)
#   ./scripts/audit-device.sh --save       # audit and save to ~/dotfiles-backups/audit/

set -euo pipefail

HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')"
OS="$(uname -s)"
ARCH="$(uname -m)"
MODE="${1:-report}"

# ── Find config service ─────────────────────────────────────────────────
find_config_service() {
  for host in localhost rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
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
  cat <<JSON
{
  "hostname": "$HOSTNAME",
  "os": "$OS",
  "arch": "$ARCH",
  "macos_version": "$(sw_vers -productVersion 2>/dev/null || echo '')",
  "kernel": "$(uname -r)",
  "uptime": "$(uptime | sed 's/.*up //' | sed 's/,.*//')",
  "shell": "$SHELL",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
import shutil, json
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
    path = shutil.which(t)
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
import subprocess, json
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
AUDIT_DATA
)

# ── Output based on mode ────────────────────────────────────────────────
case "$MODE" in
  --local)
    echo "$AUDIT"
    ;;
  --save)
    SAVE_DIR="$HOME/dotfiles-backups/audit"
    mkdir -p "$SAVE_DIR"
    echo "$AUDIT" > "$SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json"
    echo "Saved to $SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json" >&2
    ;;
  *)
    # Upload to config service
    CONFIG_URL=$(find_config_service)
    if [[ -n "$CONFIG_URL" ]]; then
      curl -sf -X POST "${CONFIG_URL}/api/audit/${HOSTNAME}" \
        -H "Content-Type: application/json" \
        -d "$AUDIT" --max-time 10 >/dev/null 2>&1 \
        && echo "Audit uploaded to config service" >&2 \
        || echo "Upload failed — printing locally" >&2
    else
      echo "Config service not reachable — printing audit" >&2
    fi
    echo "$AUDIT"
    ;;
esac
