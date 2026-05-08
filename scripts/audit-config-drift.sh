#!/usr/bin/env bash
# Compare local macOS state to declared nix-darwin config.
# Surfaces drift in dock, casks, /Applications, MAS apps, and key defaults
# so you can fold real-world changes back into the flake before rebuilding.
#
# Usage:
#   ./scripts/audit-config-drift.sh                  # audit vs declared config
#   ./scripts/audit-config-drift.sh Kassie-M5-Air13  # audit a specific host
#   ./scripts/audit-config-drift.sh --snapshot       # save baseline of all defaults
#   ./scripts/audit-config-drift.sh --diff           # diff current state vs baseline
#
# Snapshot/diff catches changes you haven't yet enumerated as "key knobs"
# (e.g. mouse speed, custom keyboard shortcuts, hidden defaults).
#
# Exit codes: 0 = no drift, 1 = drift detected, 2 = error.

set -euo pipefail

ACTION="audit"
HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) ACTION="snapshot"; shift ;;
    --diff)     ACTION="diff"; shift ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          HOST="$1"; shift ;;
  esac
done

HOST="${HOST:-$(hostname -s)}"
FLAKE_DIR="${DOTFILES:-$HOME/dotfiles}"
SNAPSHOT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-audit"
SNAPSHOT_FILE="$SNAPSHOT_DIR/baseline-$HOST.txt"
DRIFT=0
# Track drift direction separately so callers can distinguish risky from benign:
#   RISKY  = `+` items: present locally, not in config → 'switch' WILL overwrite.
#   BENIGN = `-` items: in config, not present locally → 'switch' WILL apply.
RISKY=0
BENIGN=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS only." >&2; exit 2
fi
if ! command -v jq >/dev/null; then
  echo "jq not found (install via 'brew install jq')." >&2; exit 2
fi
if [[ "$ACTION" == "audit" ]] && ! command -v nix >/dev/null; then
  echo "nix not found." >&2; exit 2
fi

# ── Output helpers ────────────────────────────────────────────────────
heading() { printf "\n\033[1;36m== %s ==\033[0m\n" "$*"; }
ok()      { printf "  \033[32m✓\033[0m %s\n" "$*"; }
add()     { printf "  \033[33m+\033[0m %s\n" "$*"; DRIFT=1; RISKY=$((RISKY+1)); }
sub()     { printf "  \033[31m-\033[0m %s\n" "$*"; DRIFT=1; BENIGN=$((BENIGN+1)); }
note()    { printf "  \033[90m· %s\033[0m\n" "$*"; }

# Evaluate an attribute of the host's darwinConfiguration as JSON.
# Returns empty string on failure (option may not be set).
eval_json() {
  nix eval --json \
    "$FLAKE_DIR#darwinConfigurations.\"$HOST\".config.$1" 2>/dev/null || echo ""
}

eval_str() {
  eval_json "$1" | jq -r 'if type=="string" then . else empty end' 2>/dev/null
}

eval_list() {
  eval_json "$1" | jq -r 'if type=="array" then .[] else empty end' 2>/dev/null
}

# Extract dock paths — nix-darwin wraps each entry as {tile-data:{file-data:{_CFURLString}}}.
eval_dock() {
  eval_json "system.defaults.dock.persistent-apps" \
    | jq -r 'if type=="array" then .[] | .["tile-data"]["file-data"]["_CFURLString"] else empty end' 2>/dev/null
}

# Extract cask names — nix-darwin wraps each entry as {name, brewfileLine, ...}.
eval_casks() {
  eval_json "homebrew.casks" \
    | jq -r 'if type=="array" then .[] | .name else empty end' 2>/dev/null
}

# Extract MAS app IDs from postActivation script (nix-darwin merges all postActivation.text together).
eval_mas_ids() {
  eval_json "system.activationScripts.postActivation.text" \
    | jq -r 'if type=="string" then . else empty end' 2>/dev/null \
    | grep -oE 'mas_install [0-9]+' | awk '{print $2}' | sort -u
}

# ── Snapshot/diff support ─────────────────────────────────────────────
# Domains we capture for snapshot-vs-diff. These cover most settings users
# reach for in System Settings (input, dock, finder) plus less-discoverable
# hidden defaults that nobody thinks to enumerate up front.
SNAPSHOT_DOMAINS=(
  NSGlobalDomain
  com.apple.dock
  com.apple.finder
  com.apple.trackpad
  com.apple.AppleMultitouchMouse
  com.apple.driver.AppleBluetoothMultitouch.mouse
  com.apple.driver.AppleBluetoothMultitouch.trackpad
  com.apple.HIToolbox
  com.apple.symbolichotkeys
  com.apple.systemuiserver
  com.apple.menuextra.clock
  com.apple.screencapture
)

# Dump a defaults domain as deterministic, sorted JSON so diffs are clean.
# `defaults export -` is broken for some domains (NSGlobalDomain) — use a
# tempfile and Python's plistlib, which handles dates / binary blobs that
# `plutil -convert json` chokes on.
domain_json() {
  local tmp; tmp=$(mktemp)
  if defaults export "$1" "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    python3 - "$tmp" <<'PY' 2>/dev/null || echo "{}"
import json, plistlib, sys, base64, datetime
with open(sys.argv[1], "rb") as f:
    data = plistlib.load(f)
def norm(v):
    if isinstance(v, (bytes, bytearray)):
        return f"<binary {len(v)} bytes sha={base64.b16encode(v[:8]).decode()}>"
    if isinstance(v, datetime.datetime):
        return v.isoformat()
    if isinstance(v, dict):
        return {k: norm(vv) for k, vv in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v
print(json.dumps(norm(data), sort_keys=True, indent=2))
PY
  else
    echo "{}"
  fi
  rm -f "$tmp"
}

# Write a full snapshot to stdout.
write_snapshot() {
  for d in "${SNAPSHOT_DOMAINS[@]}"; do
    echo "===DOMAIN:$d==="
    domain_json "$d"
  done
  echo "===APPLICATIONS==="
  ls /Applications | sort
  echo "===HOMEBREW_CASKS==="
  brew list --cask 2>/dev/null | sort || true
  echo "===MAS_APPS==="
  mas list 2>/dev/null | sort -k1n || true
  echo "===DOCK_PERSISTENT==="
  defaults read com.apple.dock persistent-apps 2>/dev/null \
    | grep -E '"_CFURLString" =' \
    | sed -E 's/.*"_CFURLString" = "(file:\/\/)?([^"]+)";/\2/' \
    | sed 's/%20/ /g' | sed 's|/$||'
}

if [[ "$ACTION" == "snapshot" ]]; then
  mkdir -p "$SNAPSHOT_DIR"
  write_snapshot > "$SNAPSHOT_FILE"
  echo "Snapshot saved: $SNAPSHOT_FILE"
  echo "Lines: $(wc -l < "$SNAPSHOT_FILE" | tr -d ' ')"
  exit 0
fi

if [[ "$ACTION" == "diff" ]]; then
  if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "No baseline at $SNAPSHOT_FILE — run --snapshot first." >&2
    exit 2
  fi
  current=$(mktemp)
  trap 'rm -f "$current"' EXIT
  write_snapshot > "$current"
  if diff -q "$SNAPSHOT_FILE" "$current" >/dev/null; then
    printf "\033[1;32mNo changes since baseline (%s).\033[0m\n" \
      "$(stat -f '%Sm' "$SNAPSHOT_FILE")"
    exit 0
  fi
  printf "\033[1;33mChanges since baseline (%s):\033[0m\n\n" \
    "$(stat -f '%Sm' "$SNAPSHOT_FILE")"
  diff -u --label "baseline" --label "current" "$SNAPSHOT_FILE" "$current"
  exit 1
fi

echo "Auditing $HOST against $FLAKE_DIR ..."

# ── Dock drift ────────────────────────────────────────────────────────
heading "Dock"
declared_dock=$(eval_dock)
actual_dock=$(defaults read com.apple.dock persistent-apps 2>/dev/null \
  | grep -E '"_CFURLString" =' \
  | sed -E 's/.*"_CFURLString" = "(file:\/\/)?([^"]+)";/\2/' \
  | sed 's/%20/ /g' | sed 's|/$||')

if [[ -z "$declared_dock" ]]; then
  note "no dock declared for $HOST"
else
  added=$(comm -13 <(echo "$declared_dock" | sort -u) <(echo "$actual_dock" | sort -u))
  removed=$(comm -23 <(echo "$declared_dock" | sort -u) <(echo "$actual_dock" | sort -u))
  [[ -n "$added"   ]] && while read -r a; do add "$a (in dock, not in config)"; done <<<"$added"
  [[ -n "$removed" ]] && while read -r r; do sub "$r (in config, not in dock)"; done <<<"$removed"
  if diff -q <(echo "$declared_dock") <(echo "$actual_dock") >/dev/null 2>&1; then
    ok "dock matches config exactly"
  elif [[ -z "$added$removed" ]]; then
    note "same items, different order — declared:"
    echo "$declared_dock" | sed 's/^/    /'
    note "actual:"
    echo "$actual_dock" | sed 's/^/    /'
    DRIFT=1
    RISKY=$((RISKY+1))   # switch will overwrite manual reorder
  fi
fi

# ── Cask drift ────────────────────────────────────────────────────────
heading "Homebrew casks"
declared_casks=$(eval_casks | sort -u)
installed_casks=$(brew list --cask 2>/dev/null | sort -u)

orphan=$(comm -23 <(echo "$installed_casks") <(echo "$declared_casks"))
missing=$(comm -13 <(echo "$installed_casks") <(echo "$declared_casks"))
[[ -n "$orphan"  ]] && while read -r c; do add "$c (installed, not declared)"; done <<<"$orphan"
[[ -n "$missing" ]] && while read -r c; do sub "$c (declared, not installed)"; done <<<"$missing"
[[ -z "$orphan$missing" ]] && ok "all casks match"

# Apple stock MAS apps that ship pre-bundled and re-appear after install.
# These show up in `mas list` but aren't worth flagging as drift.
APPLE_STOCK_MAS_IDS="408981434 409183694 409201541 409203825 682658836"

# Casks that install via .pkg and don't expose a parseable .app artifact.
# Map cask-name -> known .app filename so we can account for them in /Applications.
declare -A PKG_CASK_APPS=(
  [tailscale-app]="Tailscale.app"
  [zoom]="zoom.us.app"
  [gpg-suite-no-mail]="GPG Keychain.app"
)

# ── Mac App Store drift ───────────────────────────────────────────────
heading "Mac App Store apps"
declared_mas=$(eval_mas_ids)
installed_mas_raw=$(mas list 2>/dev/null | awk '{print $1}' | sort -u)
# Filter out Apple stock apps from "installed" so they don't show as drift.
installed_mas=$(comm -23 <(echo "$installed_mas_raw") <(echo "$APPLE_STOCK_MAS_IDS" | tr ' ' '\n' | sort -u))

# Cache mas list output so we can resolve names cheaply.
mas_list_cache=$(mas list 2>/dev/null)
mas_name() {
  echo "$mas_list_cache" | awk -v i="$1" '$1==i{$1=""; sub(/^ /,""); sub(/  *\(.*\)$/,""); print}'
}

if [[ -z "$declared_mas$installed_mas" ]]; then
  note "no MAS apps declared or installed"
else
  orphan=$(comm -23 <(echo "$installed_mas") <(echo "$declared_mas"))
  missing=$(comm -13 <(echo "$installed_mas") <(echo "$declared_mas"))
  while read -r id; do
    [[ -z "$id" ]] && continue
    add "MAS $id $(mas_name "$id") (installed, not declared)"
  done <<<"$orphan"
  while read -r id; do
    [[ -z "$id" ]] && continue
    sub "MAS $id $(mas_name "$id") (declared, not installed)"
  done <<<"$missing"
  [[ -z "$orphan$missing" ]] && ok "all MAS apps match"
fi

# ── /Applications drift ───────────────────────────────────────────────
heading "Apps in /Applications not declared"
# Apps that ship with macOS — never expected to be in config.
APPLE_APPS_RE='^(Safari|GarageBand|iMovie|Keynote|Numbers|Pages|Utilities|Nix Apps|TestFlight|Xcode|FaceTime|Mail|Maps|Music|News|Notes|Photos|Podcasts|Stocks|TV|Weather|Reminders|Messages|Calendar|Books|Dictionary|App Store|Find My|Freeform|Home|Image Capture|Migration Assistant|Mission Control|Photo Booth|Preview|QuickTime Player|Shortcuts|Stickies|System Preferences|System Settings|TextEdit|Time Machine|Voice Memos|Calculator|Chess|Clock|Contacts|Font Book|Launchpad|Tips|VoiceOver Utility)\.?'

# Build the set of .app names that should exist on this machine:
#  1. Apps declared via casks (parsed from `brew info` artifacts)
#  2. Apps declared via MAS (resolved via `mas list`)
#  3. Manual overrides for Pkg-based casks
expected_apps=""
for c in $declared_casks; do
  # Handle direct ".app (App)" artifacts AND "Installer.app -> Real.app (App)" rename arrows.
  apps=$(brew info --cask "$c" 2>/dev/null \
    | awk '/^==> Artifacts/{flag=1; next} /^==>/{flag=0}
           flag && /\.app \(App\)$/ {
             line=$0
             # If "X -> Y.app (App)", take Y.app. Otherwise take the line minus " (App)".
             if (match(line, / -> /)) { line=substr(line, RSTART+RLENGTH) }
             sub(/ \(App\)$/, "", line)
             sub(/^[[:space:]]+/, "", line)
             print line
           }')
  expected_apps+=$'\n'"$apps"
  # Manual override for Pkg-based casks.
  if [[ -n "${PKG_CASK_APPS[$c]:-}" ]]; then
    expected_apps+=$'\n'"${PKG_CASK_APPS[$c]}"
  fi
done

# Add MAS-installed apps (declared OR Apple stock — both are "expected" on this machine).
for id in $declared_mas $APPLE_STOCK_MAS_IDS; do
  name=$(mas_name "$id")
  [[ -n "$name" ]] && expected_apps+=$'\n'"${name}.app"
done

expected_apps=$(echo "$expected_apps" | sort -u | sed '/^$/d')

unknown_count=0
for app in /Applications/*.app; do
  name=$(basename "$app")
  echo "$name" | grep -qE "$APPLE_APPS_RE" && continue
  echo "$expected_apps" | grep -qxF "$name" && continue
  add "$app"
  unknown_count=$((unknown_count + 1))
done
[[ $unknown_count -eq 0 ]] && ok "all /Applications entries accounted for"

# ── macOS defaults drift (key knobs) ──────────────────────────────────
heading "macOS defaults (key knobs)"
# Compare a curated set of settings users tend to change manually.
# Format: domain|key|nix-attr-path|label
checks=(
  "NSGlobalDomain|InitialKeyRepeat|system.defaults.NSGlobalDomain.InitialKeyRepeat|Initial key repeat"
  "NSGlobalDomain|KeyRepeat|system.defaults.NSGlobalDomain.KeyRepeat|Key repeat"
  "NSGlobalDomain|com.apple.mouse.scaling|system.defaults.\".GlobalPreferences\".\"com.apple.mouse.scaling\"|Mouse speed"
  "NSGlobalDomain|com.apple.trackpad.scaling|system.defaults.\".GlobalPreferences\".\"com.apple.trackpad.scaling\"|Trackpad speed"
  "NSGlobalDomain|com.apple.swipescrolldirection|system.defaults.NSGlobalDomain.\"com.apple.swipescrolldirection\"|Natural scrolling"
  "com.apple.dock|tilesize|system.defaults.dock.tilesize|Dock tile size"
  "com.apple.dock|autohide|system.defaults.dock.autohide|Dock autohide"
  "com.apple.dock|orientation|system.defaults.dock.orientation|Dock orientation"
  "com.apple.dock|show-recents|system.defaults.dock.show-recents|Dock show recents"
)

for line in "${checks[@]}"; do
  IFS='|' read -r domain key attr label <<<"$line"
  actual=$(defaults read "$domain" "$key" 2>/dev/null || echo "(unset)")
  declared=$(eval_json "$attr" 2>/dev/null | jq -r 'if . == null then "(null)" else tostring end' 2>/dev/null || echo "")
  declared="${declared:-(undeclared)}"

  # Normalise booleans (defaults reports 1/0; nix returns true/false).
  case "$declared" in true) declared=1 ;; false) declared=0 ;; esac

  if [[ "$declared" == "(undeclared)" || "$declared" == "(null)" ]]; then
    [[ "$actual" != "(unset)" ]] && note "$label: actual=$actual (not declared)"
  elif [[ "$declared" != "$actual" ]]; then
    add "$label: declared=$declared actual=$actual"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────
echo
# Machine-readable summary line — callers (e.g. rebuild.sh) parse this to
# distinguish risky drift (manual changes that 'switch' would overwrite)
# from benign drift (declared items not yet applied — 'switch' just applies them).
echo "DRIFT_RESULT: risky=$RISKY benign=$BENIGN"

if [[ $DRIFT -eq 0 ]]; then
  printf "\033[1;32mNo drift detected.\033[0m\n"
  exit 0
elif [[ $RISKY -eq 0 ]]; then
  printf "\033[1;36mOnly benign drift (%d declared item(s) pending) — 'switch' will apply.\033[0m\n" "$BENIGN"
  exit 1
else
  printf "\033[1;33mRisky drift detected — %d manual change(s) will be overwritten by 'switch'. Review above.\033[0m\n" "$RISKY"
  exit 1
fi
