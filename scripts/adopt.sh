#!/usr/bin/env bash
# adopt.sh — bring an EXISTING (or fresh) Mac under fleet management, in one
# idempotent, resumable command. Run it on the Mac, from an admin account, in a
# GUI session (Terminal.app at the Mac or over Screen Sharing):
#
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/adopt.sh | bash
#   curl -fsSL …/adopt.sh | bash -s -- --dry-run      # preflight + plan, changes nothing
#   ~/dotfiles/scripts/adopt.sh [--dry-run] [--yes] [--skip-nix-install]
#
# Phases (each prints [OK] done / [DO] doing / [ASK] needs you, and skips
# itself when its end state already holds — so a re-run resumes):
#   preflight  read-only: macOS + arch, admin, GUI session, disk, FileVault,
#              Xcode CLT, Nix, hostname vs flake.nix (origin/main), the host's
#              mkMac settings, Tailscale, the config service (+ offer the pin);
#   flake      no darwinConfigurations entry for this hostname → STOP: the
#              owner generates one with scripts/new-host.sh from this Mac's
#              audit (offered here: read-only pre-wipe check + one audit);
#   xcode      Xcode Command Line Tools (macOS dialog, polled);
#   nix        the official multi-user installer (asks first);
#   dotfiles   clone ~/dotfiles, or fast-forward a clean main to origin/main;
#   rebuild    scripts/rebuild.sh --plan-only → (needsSecrets hosts:
#              scripts/setup-secrets.sh, which stops with the recipient-side
#              command when this Mac cannot decrypt yet) → confirm →
#              scripts/rebuild.sh, which asks its own questions (flakes,
#              Homebrew owner, /etc files, the switch itself) — this script
#              never answers them;
#   verify     fleet-update daemon, firewall, fleet launcher, one audit, and the
#              list of what stays manual (App Management, optional Full Disk
#              Access, restic token, Tailscale admin console, registry role).
#
# Flags:
#   --dry-run           preflight + plan only: no installs, no writes, no state
#                       file, no git fetch (ls-remote only), no audit upload.
#   --yes, -y           accept this script's NON-destructive defaults (pin file,
#                       Xcode CLT, Nix install, clone, audit, starting rebuild.sh).
#                       Never forwarded to rebuild.sh: its fixes and the switch
#                       are always answered by you.
#   --skip-nix-install  never install Nix; stop with the command instead.
#
# State: ~/.local/state/rh7-adopt/state.json (phase → status, timestamps, the
# origin/main revision the last successful rebuild applied). Logs of the
# rebuild.sh runs sit next to it.
#
# Exit: 0 adopted (optional manual items may remain), 1 a step failed,
#       3 stopped — needs an action listed in the output, 64 usage.
#
# bash 3.2 compatible (the stock macOS bash runs it before Nix exists).
# Everything lives in functions and `main` runs last, so a `curl | bash` reads
# the whole file before executing anything, and every prompt and child reads
# the terminal (/dev/tty), never the pipe.

set -uo pipefail

ADOPT_VERSION=1

RAW_BASE="${ADOPT_RAW_BASE:-https://raw.githubusercontent.com/rh7/dotfiles/main}"
REPO_URL="${ADOPT_REPO_URL:-https://github.com/rh7/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
STATE_DIR="${ADOPT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rh7-adopt}"
STATE_FILE="$STATE_DIR/state.json"
NIX_DAEMON_PROFILE="${ADOPT_NIX_DAEMON_PROFILE:-/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh}"
NIX_INSTALL_URL="${ADOPT_NIX_INSTALL_URL:-https://nixos.org/nix/install}"
CURRENT_SYSTEM="${ADOPT_CURRENT_SYSTEM:-/run/current-system}"
FLEET_LAUNCHER="${ADOPT_FLEET_LAUNCHER:-/usr/local/libexec/rh7-fleet-launcher}"
SOCKETFILTERFW="${ADOPT_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
TTY="${ADOPT_TTY:-/dev/tty}"
MIN_FREE_GB="${ADOPT_MIN_FREE_GB:-20}"
FDA_PANE="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
STUDIO_SSH_HOST="rouvens-mac-studio"

# Stock tools first: on a nix-managed Mac GNU coreutils can shadow the BSD
# `stat -f` / `df -g` this script uses. ADOPT_PATH_PREFIX is for the tests.
PATH="${ADOPT_PATH_PREFIX:+$ADOPT_PATH_PREFIX:}/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

DRY_RUN=false
ASSUME_YES=false
SKIP_NIX_INSTALL=false

# Facts gathered by preflight.
HOST=""; FLAKE_FILE=""; FLAKE_HAS_HOST=false; FLAKE_CASE_MATCH=""
P_USER=""; P_ROLE=""; P_SECRETS=true; P_AUTOUPDATE=""; P_RESTIC=false; P_HOMEPROFILE="full"
HAVE_CLT=false; HAVE_NIX=false; GUI_OK=false; CS_URL=""
SUMMARY=""; MANUAL=""; STOP_REASON=""
REBUILD_LOGS=""

# ── output ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[0;34m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_B=""; C_R=""; C_C=""; C_0=""
fi
say_ok()   { printf '%s[OK]%s   %s\n' "$C_G" "$C_0" "$*"; }
say_do()   { printf '%s[DO]%s   %s\n' "$C_B" "$C_0" "$*"; }
say_ask()  { printf '%s[ASK]%s  %s\n' "$C_Y" "$C_0" "$*"; }
say_warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
say_err()  { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
say_plan() { printf '%s[PLAN]%s %s\n' "$C_C" "$C_0" "$*"; }
say_info() { printf '       %s\n' "$*"; }
section()  { printf '\n%s── %s ──%s\n' "$C_C" "$*" "$C_0"; }

# summary <phase> <status> [detail]
summary() { SUMMARY="${SUMMARY}$(printf '  %-10s %-9s %s' "$1" "$2" "${3:-}")
"; }
manual() { MANUAL="${MANUAL}$*
"; }

# ── prompts ──────────────────────────────────────────────────────────────────
# have_tty: the terminal can actually be opened (`[ -r /dev/tty ]` is true even
# without a controlling terminal, e.g. under launchd or in CI).
have_tty() { { : <"$TTY"; } 2>/dev/null; }

# read_answer <prompt>: one line from the terminal into $ANSWER; 1 = no terminal.
read_answer() {
  ANSWER=""
  have_tty || return 1
  if { : >>"$TTY"; } 2>/dev/null; then printf '%s ' "$1" >>"$TTY"; else printf '%s ' "$1" >&2; fi
  IFS= read -r ANSWER <"$TTY" || return 1
  return 0
}

# ask <default y|n> <question> [auto]
#   auto — --yes may answer it (non-destructive steps only).
# Never asks in --dry-run (returns "no"). No terminal → the default only when
# it is "n"; a "y" default without a terminal and without --yes is a "no".
ask() {
  local def="$1" q="$2" auto="${3:-}" hint
  $DRY_RUN && return 1
  if [ "$auto" = auto ] && $ASSUME_YES; then
    say_ask "$q → yes (--yes)"
    return 0
  fi
  if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if ! read_answer "$(printf '%s[ASK]%s  %s %s' "$C_Y" "$C_0" "$q" "$hint")"; then
    say_info "(no terminal — treating as No)"
    return 1
  fi
  case "$ANSWER" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No) return 1 ;;
    "") [ "$def" = y ] ;;
    *) return 1 ;;
  esac
}

# stdin for children that may prompt (rebuild.sh, sudo, the Nix installer).
tty_in() { if have_tty; then printf '%s' "$TTY"; else printf '/dev/null'; fi; }

# ── state file (flat JSON, no jq needed) ─────────────────────────────────────
STATE_KV=""
state_load() {
  STATE_KV=""
  [ -r "$STATE_FILE" ] || return 0
  STATE_KV=$(sed -n 's/^  "\([A-Za-z0-9_.-]*\)": "\([^"]*\)",\{0,1\}$/\1=\2/p' "$STATE_FILE")
}
state_get() {
  printf '%s\n' "$STATE_KV" | sed -n "s/^$1=//p" | head -n 1
}
state_set() {
  local k="$1" v rest
  v=$(printf '%s' "$2" | tr -d '"\\\n\r')
  rest=$(printf '%s\n' "$STATE_KV" | grep -v "^$k=" || true)
  STATE_KV=$(printf '%s\n%s=%s' "$rest" "$k" "$v" | sed '/^$/d')
  $DRY_RUN && return 0
  state_write
}
state_write() {
  local now tmp line k v
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp="$STATE_FILE.tmp.$$"
  {
    printf '{\n'
    printf '  "schema": "1",\n  "adopt_version": "%s",\n  "updated_at": "%s"' "$ADOPT_VERSION" "$now"
    printf '%s\n' "$STATE_KV" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in schema|adopt_version|updated_at) continue ;; esac
      printf ',\n  "%s": "%s"' "$k" "$v"
    done
    printf '\n}\n'
  } >"$tmp" && mv -f "$tmp" "$STATE_FILE"
  return 0
}
# phase_mark <phase> <status> [detail] — state + summary in one place.
phase_mark() {
  summary "$1" "$2" "${3:-}"
  state_set "phase.$1" "$2"
  state_set "phase.$1.at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# >>> BEGIN SHARED CONFIG-SERVICE RESOLVER >>>
# This block is duplicated VERBATIM in scripts/audit-device.sh and
# scripts/collector-runner.sh, and scripts/tests/find-config-service.test.sh
# fails if the two copies drift.
#
# It cannot be a sourced library. Both scripts are distributed as SINGLE
# SELF-CONTAINED FILES over HTTP: the collector is served as one blob by
# `git show <ref>:scripts/audit-device.sh` (config-service collectors.ts) and
# written to a cache file with no siblings on the device; the runner is fetched
# standalone via `curl ... | bash`. A `source` would break the no-clone path
# that is the entire point of both.
#
# Duplication was NOT the bug. Silent duplication was: collector-runner.sh kept
# the pre-#63 probe-first implementation for two months after audit-device.sh
# was fixed, and nothing noticed. Hence the drift test.
CONFIG_SERVICE_PORT="${CONFIG_SERVICE_PORT:-3456}"
CONFIG_SERVICE_PIN_SYSTEM="${CONFIG_SERVICE_PIN_SYSTEM:-/etc/rh7/config-service}"
CONFIG_SERVICE_PIN_USER="${CONFIG_SERVICE_PIN_USER:-${XDG_CONFIG_HOME:-$HOME/.config}/rh7/config-service}"
# `localhost` is deliberately ABSENT. A host must never default to itself --
# that is bug 1 above, and it is the whole reason this rewrite exists.
#
# This list names the CURRENT authority only, and is updated AT cutover, never
# before. Listing the migration target here early is its own split-brain: a
# staging instance is reachable long before it is authoritative, and every
# unpinned host would silently adopt it the moment the network allowed. That
# nearly happened here -- vps-honcho was first in this list during development
# while a rehearsal instance was already running on it, held back only by an
# unmerged ACL grant (rh7/tailscale-acl#36) that would have opened the path.
#
# Pins are what move the fleet. The migration is: deploy pins -> verify ->
# retire the old instance -> only then repoint this list.
# `rouvens-mac-studio-1` was removed 2026-08-22: verified absent from `tailscale
# status` -- the only Studio node is `rouvens-mac-studio` at 100.100.241.110. A
# dead name here costs a curl timeout on every bootstrap probe.
CONFIG_SERVICE_FALLBACKS="${CONFIG_SERVICE_FALLBACKS:-rouvens-mac-studio Rouvens-Mac-Studio.local 100.100.241.110}"

# A 200 on :3456/api/health used to be accepted as proof. Anything at all
# listening on that port would do. Check the service actually identifies
# itself; it is a cheap guard against pointing the fleet's audit POSTs at some
# unrelated process.
_config_service_answers() {
  local url="$1" body=""
  body=$(curl -sf "${url%/}/api/health" --max-time 2 2>/dev/null) || return 1
  case "$body" in
    *'"service":"config-service"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# First non-comment, non-blank line of a pin file, whitespace stripped.
_config_service_pin() {
  local file="$1" value=""
  [[ -r "$file" ]] || return 1
  value=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" 2>/dev/null | grep -m1 . || true)
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

find_config_service() {
  local pin="" source="" host="" url=""

  if [[ -n "${CONFIG_SERVICE_URL:-}" ]]; then
    pin="$CONFIG_SERVICE_URL"; source="\$CONFIG_SERVICE_URL"
  elif pin=$(_config_service_pin "$CONFIG_SERVICE_PIN_SYSTEM"); then
    source="$CONFIG_SERVICE_PIN_SYSTEM"
  elif pin=$(_config_service_pin "$CONFIG_SERVICE_PIN_USER"); then
    source="$CONFIG_SERVICE_PIN_USER"
  fi

  if [[ -n "$pin" ]]; then
    if _config_service_answers "$pin"; then
      printf '%s\n' "${pin%/}"
    else
      # FAIL CLOSED. Falling back to probing here would be the worst possible
      # moment for it: the pinned service is down, so a probe is most likely to
      # find some *other* instance and quietly start writing the fleet's audits
      # into it. A missed audit is recoverable on the next run; a split
      # registry is not obviously wrong until someone goes looking.
      echo "WARN: pinned config service '$pin' (from $source) did not answer — not probing for another instance" >&2
    fi
    return 0
  fi

  # Bootstrap only: this host has never been pinned.
  for host in $CONFIG_SERVICE_FALLBACKS; do
    case "$host" in
      *://*) url="${host%/}" ;;
      *)     url="http://${host}:${CONFIG_SERVICE_PORT}" ;;
    esac
    if _config_service_answers "$url"; then
      echo "WARN: no config-service pin on this host; discovered $url by probing." >&2
      echo "      Pin it:  echo $url | sudo tee $CONFIG_SERVICE_PIN_SYSTEM" >&2
      printf '%s\n' "$url"
      return 0
    fi
  done

  # Nothing found. Empty output, exit 0 — see the CONTRACT note above.
  return 0
}
# <<< END SHARED CONFIG-SERVICE RESOLVER <<<

# ── probes (read-only; one function each so the tests can stub them) ────────
probe_os()            { uname -s; }
probe_arch()          { uname -m; }
probe_macos_version() { sw_vers -productVersion 2>/dev/null; }
probe_euid()          { id -u; }
probe_hostname()      { hostname -s 2>/dev/null; }
probe_is_admin()      { id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; }
probe_user_exists()   { id "$1" >/dev/null 2>&1; }
# A GUI session: this user owns the console and the shell is not an SSH login.
# The Nix installer needs it (headless sessions cannot write the /etc/fstab
# entry for the Nix APFS volume); Xcode CLT's dialog does too.
probe_gui_session() {
  [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 1
  [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$(id -un)" ]
}
probe_free_gb()       { df -g / 2>/dev/null | awk 'NR==2 {print $4}'; }
probe_filevault()     { fdesetup status 2>/dev/null | grep -q 'FileVault is On'; }
probe_clt()           { xcode-select -p >/dev/null 2>&1 && [ -x "$(xcode-select -p)/usr/bin/git" ] 2>/dev/null; }
probe_nix() {
  command -v nix >/dev/null 2>&1 && return 0
  [ -x /nix/var/nix/profiles/default/bin/nix ]
}
probe_determinate()   { [ -e /nix/receipt.json ] || nix --version 2>/dev/null | grep -qi determinate; }
probe_tailscale_cli() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale; return 0; fi
  [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && { echo /Applications/Tailscale.app/Contents/MacOS/Tailscale; return 0; }
  return 1
}
probe_tailscale_running() { "$1" status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; }
probe_config_service() { find_config_service 2>/dev/null; }
probe_pin_present() {
  _config_service_pin "$CONFIG_SERVICE_PIN_SYSTEM" >/dev/null 2>&1 ||
    _config_service_pin "$CONFIG_SERVICE_PIN_USER" >/dev/null 2>&1
}
# Downloads flake.nix of origin/main to $1 (raw GitHub, so it works before git
# or nix exist). ADOPT_FLAKE_FILE overrides for tests.
fetch_flake() {
  if [ -n "${ADOPT_FLAKE_FILE:-}" ]; then cp "$ADOPT_FLAKE_FILE" "$1"; return; fi
  curl -fsSL --max-time 30 "$RAW_BASE/flake.nix" -o "$1"
}
probe_managed()        { [ -e "$CURRENT_SYSTEM/darwin-version.json" ]; }
probe_origin_rev() {   # origin/main as the remote has it — read-only (ls-remote)
  git ls-remote "$REPO_URL" refs/heads/main 2>/dev/null | awk '{print $1; exit}'
}
# dotfiles checkout state: absent | foreign | dirty | branch:<name> | <head-sha>
probe_dotfiles() {
  local d="$DOTFILES_DIR" url br
  [ -e "$d" ] || { echo absent; return; }
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || { echo foreign; return; }
  url=$(git -C "$d" remote get-url origin 2>/dev/null || true)
  case "$url" in *rh7/dotfiles|*rh7/dotfiles.git) ;; *) echo foreign; return ;; esac
  br=$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)
  [ "$br" = main ] || { echo "branch:$br"; return; }
  if [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then echo dirty; return; fi
  git -C "$d" rev-parse HEAD 2>/dev/null
}
probe_is_ancestor() { git -C "$DOTFILES_DIR" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
probe_local_origin_rev() { git -C "$DOTFILES_DIR" rev-parse origin/main 2>/dev/null; }
probe_age_key()     { [ -s "$HOME/.config/sops/age/keys.txt" ]; }
probe_fleet_update() {
  launchctl print system/org.rh7.fleet-update >/dev/null 2>&1 ||
    [ -e /Library/LaunchDaemons/org.rh7.fleet-update.plist ]
}
probe_firewall()    { "$SOCKETFILTERFW" --getglobalstate 2>/dev/null | grep -qi enabled; }
probe_launcher()    { [ -x "$FLEET_LAUNCHER" ]; }
probe_restic_configured() { [ -s "$1/.config/rh7-restic/repo-password" ] 2>/dev/null; }
probe_registry_role() {
  [ -n "$CS_URL" ] || return 1
  curl -sf --max-time 5 "$CS_URL/api/devices/$HOST" 2>/dev/null |
    sed -n 's/.*"role":"\([^"]*\)".*/\1/p' | head -n 1
}
user_home() { dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; }

# ── actions (the only functions that change anything) ────────────────────────
act_write_pin() {
  sudo mkdir -p "$(dirname "$CONFIG_SERVICE_PIN_SYSTEM")" <"$(tty_in)" &&
    printf '%s\n' "$1" | sudo tee "$CONFIG_SERVICE_PIN_SYSTEM" >/dev/null
}
act_install_clt() {
  xcode-select --install >/dev/null 2>&1 || true
  local waited=0
  say_info "Finish the macOS dialog (Install → Agree). Waiting up to 30 min…"
  while ! probe_clt; do
    [ "$waited" -ge 1800 ] && return 1
    sleep 10; waited=$((waited + 10))
  done
}
act_install_nix() {
  local inst
  inst=$(mktemp "${TMPDIR:-/tmp}/rh7-nix-install.XXXXXX") || return 1
  curl -fsSL --max-time 120 "$NIX_INSTALL_URL" -o "$inst" || { rm -f "$inst"; return 1; }
  sh "$inst" --daemon --yes <"$(tty_in)"
  local rc=$?
  rm -f "$inst"
  return "$rc"
}
source_nix() {
  command -v nix >/dev/null 2>&1 && return 0
  # shellcheck disable=SC1090
  [ -r "$NIX_DAEMON_PROFILE" ] && . "$NIX_DAEMON_PROFILE"
  command -v nix >/dev/null 2>&1
}
act_clone()  { git clone "$REPO_URL" "$DOTFILES_DIR"; }
act_fetch()  { git -C "$DOTFILES_DIR" fetch --quiet origin main; }
act_ff()     { git -C "$DOTFILES_DIR" merge --ff-only --quiet origin/main; }
act_setup_secrets() { "$DOTFILES_DIR/scripts/setup-secrets.sh" --hostname "$HOST" <"$(tty_in)"; }
# act_rebuild <logfile> [rebuild.sh args…] — under script(1) so rebuild.sh
# keeps a real terminal (its prompts, sudo/Touch ID) and we keep a log.
act_rebuild() {
  local log="$1"; shift
  mkdir -p "$STATE_DIR"
  ( cd "$DOTFILES_DIR" && script -q "$log" ./scripts/rebuild.sh "$@" <"$(tty_in)" )
}
act_prewipe() {
  local f; f=$(mktemp "${TMPDIR:-/tmp}/rh7-pre-wipe.XXXXXX") || return 1
  curl -fsSL --max-time 60 "$RAW_BASE/scripts/pre-wipe-check.sh" -o "$f" || { rm -f "$f"; return 1; }
  sudo bash "$f" --all-users <"$(tty_in)"
  local rc=$?; rm -f "$f"; return "$rc"
}
act_audit_remote() {
  local f; f=$(mktemp "${TMPDIR:-/tmp}/rh7-collector-runner.XXXXXX") || return 1
  curl -fsSL --max-time 60 "$RAW_BASE/scripts/collector-runner.sh" -o "$f" || { rm -f "$f"; return 1; }
  bash "$f" </dev/null
  local rc=$?; rm -f "$f"; return "$rc"
}
act_audit() {
  if [ -x "$CURRENT_SYSTEM/sw/bin/rh7-fleet-audit" ]; then
    "$CURRENT_SYSTEM/sw/bin/rh7-fleet-audit" </dev/null
  else
    bash "$DOTFILES_DIR/scripts/collector-runner.sh" </dev/null
  fi
}
act_open_fda() { open "$FDA_PANE" >/dev/null 2>&1; }

# ── flake.nix parsing (text only — nix may not exist yet) ────────────────────
flake_attrs() { sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*=[[:space:]]*mkMac[[:space:]]*{.*/\1/p' "$1"; }
flake_block() {
  awk -v h="\"$1\"" '
    !f { s=$0; sub(/^[ \t]+/, "", s); if (index(s, h) == 1 && s ~ /=[ \t]*mkMac[ \t]*\{/) f=1 }
    f { print; if ($0 ~ /^[ \t]*};[ \t]*$/) exit }' "$2"
}
# block_str <block> <key> — value of `key = "value";`
block_str()  { printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
block_bool() { printf '%s\n' "$1" | sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(true|false).*/\1/p" | head -n 1; }
block_role() { printf '%s\n' "$1" | sed -n 's|^[[:space:]]*role[[:space:]]*=[[:space:]]*\./modules/roles/\([A-Za-z0-9_-]*\)\.nix.*|\1|p' | head -n 1; }

# Roles that import modules/darwin/firewall.nix (client Macs, #93).
role_has_firewall() {
  case "$1" in workstation-mac|personal-mac|household-mac) return 0 ;; *) return 1 ;; esac
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase a — preflight (read-only)
# ═════════════════════════════════════════════════════════════════════════════
phase_preflight() {
  section "a. Preflight (read-only)"
  local os arch ver major free blk attrs a lower_host

  os=$(probe_os)
  [ "$os" = Darwin ] || { say_err "macOS only (this is $os)."; STOP_REASON="not macOS"; return 1; }
  ver=$(probe_macos_version); major=${ver%%.*}
  if [ -n "$major" ] && [ "$major" -ge 13 ] 2>/dev/null; then say_ok "macOS $ver"
  else say_warn "macOS ${ver:-unknown} — the fleet is tested on 13+"; fi

  arch=$(probe_arch)
  [ "$arch" = arm64 ] || { say_err "Apple silicon only: every mkMac host is aarch64-darwin (this is $arch)."; STOP_REASON="unsupported arch $arch"; return 1; }
  say_ok "arch arm64"

  [ "$(probe_euid)" != 0 ] || { say_err "Run as your admin user, not root/sudo (it asks for sudo itself)."; STOP_REASON="ran as root"; return 1; }
  if probe_is_admin; then say_ok "$(id -un) is an admin"
  else say_err "$(id -un) is not an admin — run from an admin account."; STOP_REASON="not admin"; return 1; fi

  if probe_gui_session; then GUI_OK=true; say_ok "GUI session"
  else GUI_OK=false; say_warn "not a GUI session (SSH or another console user) — fine unless Nix or Xcode CLT must be installed"; fi

  free=$(probe_free_gb)
  if [ -n "$free" ] && [ "$free" -ge "$MIN_FREE_GB" ] 2>/dev/null; then say_ok "${free} GB free on /"
  else say_warn "${free:-?} GB free on / — Nix + the first build want ${MIN_FREE_GB}+ GB"; fi

  if probe_filevault; then say_ok "FileVault on"
  else say_warn "FileVault is off"; manual "FileVault is off — turn it on: ~/dotfiles/scripts/fleet-fix.sh filevault --apply (store the recovery key in 1Password)."; fi

  if probe_clt; then HAVE_CLT=true; say_ok "Xcode Command Line Tools"
  else HAVE_CLT=false; say_do "Xcode Command Line Tools missing — phase c installs them"; fi

  if probe_nix; then
    HAVE_NIX=true
    if probe_determinate; then say_warn "Nix present but it is Determinate Nix — the fleet uses the official installer"; else say_ok "Nix installed"; fi
  else
    HAVE_NIX=false; say_do "Nix missing — phase c installs it (official installer, --daemon)"
    $GUI_OK || say_warn "…which needs a GUI session: run this from Terminal.app at the Mac or over Screen Sharing"
  fi

  HOST=$(probe_hostname)
  FLAKE_FILE=$(mktemp "${TMPDIR:-/tmp}/rh7-adopt-flake.XXXXXX") || return 1
  if ! fetch_flake "$FLAKE_FILE" || ! grep -q darwinConfigurations "$FLAKE_FILE"; then
    say_err "could not download flake.nix from $RAW_BASE"; STOP_REASON="flake.nix unreachable"; return 1
  fi
  attrs=$(flake_attrs "$FLAKE_FILE")
  FLAKE_HAS_HOST=false; FLAKE_CASE_MATCH=""
  lower_host=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
  for a in $attrs; do
    [ "$a" = "$HOST" ] && FLAKE_HAS_HOST=true
    if [ "$a" != "$HOST" ] && [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "$lower_host" ]; then FLAKE_CASE_MATCH="$a"; fi
  done
  if $FLAKE_HAS_HOST; then
    blk=$(flake_block "$HOST" "$FLAKE_FILE")
    P_USER=$(block_str "$blk" username); [ -n "$P_USER" ] || P_USER=rouvenheck
    P_ROLE=$(block_role "$blk"); [ -n "$P_ROLE" ] || P_ROLE=workstation-mac
    [ "$(block_bool "$blk" needsSecrets)" = false ] && P_SECRETS=false || P_SECRETS=true
    [ "$(block_bool "$blk" resticBackup)" = true ] && P_RESTIC=true || P_RESTIC=false
    P_AUTOUPDATE=$(block_str "$blk" autoUpdate)
    P_HOMEPROFILE=$(block_str "$blk" homeProfile); [ -n "$P_HOMEPROFILE" ] || P_HOMEPROFILE=full
    say_ok "hostname '$HOST' has a flake entry (origin/main)"
    say_info "role $P_ROLE · primary user $P_USER · home $P_HOMEPROFILE · secrets $P_SECRETS · autoUpdate ${P_AUTOUPDATE:-off} · restic $P_RESTIC"
    if [ "$P_USER" != "$(id -un)" ]; then
      if probe_user_exists "$P_USER"; then say_info "primary user '$P_USER' is not you: rebuild.sh runs Homebrew as $P_USER (owner-run adoption)"
      else say_err "the flake's primary user '$P_USER' has no account on this Mac — fix the flake entry first"; STOP_REASON="primary user $P_USER missing"; return 1; fi
    fi
  elif [ -n "$FLAKE_CASE_MATCH" ]; then
    say_ask "hostname '$HOST' only matches flake entry '$FLAKE_CASE_MATCH' up to case — rebuild.sh matches exactly"
  else
    say_ask "hostname '$HOST' has NO darwinConfigurations entry in flake.nix (origin/main)"
  fi

  local ts
  if ts=$(probe_tailscale_cli); then
    if probe_tailscale_running "$ts"; then say_ok "Tailscale connected"
    else say_warn "Tailscale installed but not connected — open Tailscale and log in"; manual "Connect Tailscale (menu bar → Log in), then re-run."; fi
  else
    say_warn "Tailscale not installed — install it from tailscale.com/download (kept manual: network-critical), log in, re-run"
    manual "Install + log in to Tailscale (https://tailscale.com/download), then re-run adopt.sh."
  fi

  CS_URL=$(probe_config_service)
  if [ -n "$CS_URL" ]; then
    say_ok "config service $CS_URL"
    if probe_pin_present; then say_ok "config-service pin present"
    elif $DRY_RUN; then say_plan "would offer to pin it: echo $CS_URL | sudo tee $CONFIG_SERVICE_PIN_SYSTEM"
    elif ask y "Pin the config service ($CS_URL) in $CONFIG_SERVICE_PIN_SYSTEM (sudo)?" auto; then
      if act_write_pin "$CS_URL"; then say_ok "pinned $CS_URL"; else say_warn "could not write the pin (continuing)"; fi
    else say_info "not pinned — audits keep probing the fallbacks"; fi
  else
    say_warn "config service not reachable (pin or $CONFIG_SERVICE_FALLBACKS) — audits will not upload until Tailscale reaches it"
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase b — no flake entry: stop, but help the owner generate one
# ═════════════════════════════════════════════════════════════════════════════
phase_no_flake_entry() {
  section "b. No flake entry for '$HOST'"
  if [ -n "$FLAKE_CASE_MATCH" ]; then
    say_ask "If this Mac IS '$FLAKE_CASE_MATCH', rename it (then re-run):"
    say_info "sudo scutil --set HostName $FLAKE_CASE_MATCH && sudo scutil --set LocalHostName $FLAKE_CASE_MATCH && sudo scutil --set ComputerName $FLAKE_CASE_MATCH"
  fi
  say_ask "The owner generates this Mac's config from its real inventory:"
  say_info "1. Here (read-only): a pre-wipe check (sudo, every account) and one fleet audit"
  say_info "   (uploads this Mac's inventory to the config service — the input for step 2)."
  if $DRY_RUN; then
    say_plan "would offer: sudo bash pre-wipe-check.sh --all-users   and   collector-runner.sh (one audit)"
  else
    if ask y "Run the read-only pre-wipe check now (sudo, a few minutes)?" auto; then
      if act_prewipe; then say_ok "pre-wipe report written to your home (pre-wipe-$HOST-*.md)"
      else say_warn "pre-wipe check failed or was interrupted (optional)"; fi
    fi
    if [ -z "$CS_URL" ]; then
      say_warn "config service unreachable — the audit cannot upload; fix Tailscale first"
    elif ask y "Run one fleet audit now (read-only; uploads to $CS_URL)?" auto; then
      if act_audit_remote; then say_ok "audit uploaded"; else say_warn "audit failed — see output above"; fi
    fi
  fi
  say_info "2. On an owner machine (gh + tailnet), from a dotfiles clone:"
  say_info "     scripts/new-host.sh $HOST --role household --user <daily-user>   # dry-run: prints the diff"
  say_info "     scripts/new-host.sh $HOST --role household --user <daily-user> --apply   # opens the PR"
  say_info "   (--role personal|workstation for a non-shared Mac), review, merge."
  say_info "3. Re-run this script here."
  STOP_REASON="no flake entry for $HOST — run scripts/new-host.sh on an owner machine"
  return 3
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase c — Xcode CLT + Nix
# ═════════════════════════════════════════════════════════════════════════════
phase_xcode() {
  section "c1. Xcode Command Line Tools"
  if $HAVE_CLT; then say_ok "present"; phase_mark xcode ok "present"; return 0; fi
  if $DRY_RUN; then say_plan "would run xcode-select --install and wait for the macOS dialog"; summary xcode plan; return 0; fi
  $GUI_OK || say_warn "not a GUI session — the install dialog appears on the Mac's screen"
  if ! ask y "Install the Xcode Command Line Tools (macOS dialog)?" auto; then
    STOP_REASON="Xcode CLT declined"; phase_mark xcode stopped "declined"; return 3
  fi
  say_do "xcode-select --install"
  if act_install_clt; then HAVE_CLT=true; say_ok "installed"; phase_mark xcode ok "installed"; return 0; fi
  say_err "Xcode CLT not installed after 30 min"; STOP_REASON="Xcode CLT install"; phase_mark xcode failed; return 1
}

phase_nix() {
  section "c2. Nix"
  if $HAVE_NIX; then
    if $DRY_RUN || source_nix; then say_ok "present"; phase_mark nix ok "present"; return 0; fi
    say_err "nix is installed but $NIX_DAEMON_PROFILE did not put it on PATH"; STOP_REASON="nix not on PATH"; phase_mark nix failed; return 1
  fi
  local cmd="sh <(curl -L $NIX_INSTALL_URL) --daemon"
  if $DRY_RUN; then say_plan "would ask, then run the official installer: $cmd --yes"; summary nix plan; return 0; fi
  if $SKIP_NIX_INSTALL; then
    say_ask "Nix missing and --skip-nix-install given. Install it yourself from a GUI session, then re-run:"
    say_info "$cmd"
    STOP_REASON="Nix not installed (--skip-nix-install)"; phase_mark nix stopped "skip-nix-install"; return 3
  fi
  if ! $GUI_OK; then
    say_ask "The Nix installer needs a GUI session (Terminal.app at the Mac or Screen Sharing, not SSH)."
    say_info "Re-run this script from there."
    STOP_REASON="Nix install needs a GUI session"; phase_mark nix stopped "no GUI session"; return 3
  fi
  say_info "Official multi-user installer: creates the /nix APFS volume, the nixbld users and the nix-daemon."
  if ! ask n "Install Nix now?" auto; then
    say_ask "Not installing Nix. Install it yourself, then re-run: $cmd"
    STOP_REASON="Nix install declined"; phase_mark nix stopped "declined"; return 3
  fi
  say_do "$cmd --yes"
  if ! act_install_nix; then say_err "the Nix installer failed — see its output"; STOP_REASON="Nix install failed"; phase_mark nix failed; return 1; fi
  if source_nix; then HAVE_NIX=true; say_ok "Nix installed ($(nix --version 2>/dev/null))"; phase_mark nix ok "installed"; return 0; fi
  say_err "installed, but nix is not on PATH — open a new terminal and re-run"; STOP_REASON="nix not on PATH"; phase_mark nix failed; return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase d — ~/dotfiles at origin/main
# ═════════════════════════════════════════════════════════════════════════════
phase_dotfiles() {
  section "d. ~/dotfiles at origin/main"
  local st remote
  st=$(probe_dotfiles)
  case "$st" in
    absent)
      if $DRY_RUN; then say_plan "would clone $REPO_URL → $DOTFILES_DIR"; summary dotfiles plan; return 0; fi
      ask y "Clone $REPO_URL into $DOTFILES_DIR?" auto || { STOP_REASON="clone declined"; phase_mark dotfiles stopped declined; return 3; }
      say_do "git clone $REPO_URL $DOTFILES_DIR"
      act_clone || { STOP_REASON="git clone failed"; phase_mark dotfiles failed; return 1; }
      say_ok "cloned $DOTFILES_DIR"; phase_mark dotfiles ok cloned; return 0 ;;
    foreign)
      say_ask "$DOTFILES_DIR exists but is not a clone of rh7/dotfiles — move it aside yourself, then re-run"
      STOP_REASON="$DOTFILES_DIR is not an rh7/dotfiles clone"; phase_mark dotfiles stopped foreign; return 3 ;;
    dirty|branch:*)
      say_ask "$DOTFILES_DIR is $( [ "$st" = dirty ] && echo 'main with uncommitted changes' || echo "on ${st#branch:}") — not touching it"
      say_info "rebuild.sh only builds a clean origin/main: commit/stash, 'git switch main', then re-run"
      STOP_REASON="$DOTFILES_DIR not on a clean main"; phase_mark dotfiles stopped "$st"; return 3 ;;
  esac
  # st is the checkout's HEAD sha on a clean main.
  if $DRY_RUN; then
    remote=$(probe_origin_rev)
    if [ -n "$remote" ] && [ "$remote" = "$st" ]; then say_ok "clean main at origin/main (${st:0:12})"; summary dotfiles ok "at origin/main"
    else say_plan "would fetch and fast-forward main (${st:0:12}) → origin/main (${remote:0:12})"; summary dotfiles plan; fi
    return 0
  fi
  act_fetch || { say_err "git fetch failed"; STOP_REASON="git fetch failed"; phase_mark dotfiles failed; return 1; }
  remote=$(probe_local_origin_rev)
  if [ "$st" = "$remote" ]; then say_ok "clean main at origin/main (${st:0:12})"; phase_mark dotfiles ok "at origin/main"; return 0; fi
  if probe_is_ancestor "$st" "$remote"; then
    say_do "fast-forward ${st:0:12} → ${remote:0:12}"
    act_ff || { STOP_REASON="fast-forward failed"; phase_mark dotfiles failed; return 1; }
    say_ok "at origin/main"; phase_mark dotfiles ok "fast-forwarded"; return 0
  fi
  say_ask "local main has commits that are not on origin/main — not touching it (push them via a PR, or reset yourself)"
  STOP_REASON="$DOTFILES_DIR main diverged from origin/main"; phase_mark dotfiles stopped diverged; return 3
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase e2 — sops recipient (needsSecrets hosts only). Runs inside phase e,
# after rebuild.sh --plan-only: that is what turns flakes on for a fresh Nix,
# and setup-secrets.sh evaluates the flake.
# ═════════════════════════════════════════════════════════════════════════════
phase_secrets() {
  section "e2. Secrets"
  if ! $P_SECRETS; then say_ok "needsSecrets = false — nothing to decrypt"; phase_mark secrets ok "not needed"; return 0; fi
  if $DRY_RUN; then
    if probe_age_key; then say_plan "age key present — would run scripts/setup-secrets.sh to confirm this Mac can decrypt"
    else say_plan "no age key — would run scripts/setup-secrets.sh (generates + registers it, then needs an existing recipient)"; fi
    summary secrets plan; return 0
  fi
  say_do "scripts/setup-secrets.sh --hostname $HOST"
  if act_setup_secrets; then say_ok "this Mac can decrypt its secrets"; phase_mark secrets ok; return 0; fi
  say_ask "This Mac is not a sops recipient yet. Run the command setup-secrets.sh printed above on an existing"
  say_info "recipient (rouvens-mac-studio or m5-air), merge that PR, then re-run this script."
  STOP_REASON="sops recipient missing — see setup-secrets.sh output"; phase_mark secrets stopped "not a recipient"; return 3
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase e — rebuild.sh (plan → confirm → apply)
# ═════════════════════════════════════════════════════════════════════════════
phase_rebuild() {
  section "e. Rebuild"
  local rev last_rev last_status plan_log run_log ts
  if $DRY_RUN; then rev=$(probe_origin_rev); else rev=$(probe_local_origin_rev); fi
  last_rev=$(state_get rebuild.rev); last_status=$(state_get phase.rebuild)

  if probe_managed && [ "$last_status" = ok ] && [ -n "$rev" ] && [ "$last_rev" = "$rev" ]; then
    say_ok "already applied origin/main ${rev:0:12} (state file)"; summary rebuild ok "already at ${rev:0:12}"; return 0
  fi
  if probe_managed && [ "$last_status" != failed ] && [ "$last_status" != stopped ]; then
    # Already under nix-darwin (adopted before, or managed before this script
    # existed): later rebuilds are the nightly fleet-update's (or the owner's)
    # job — so a re-run never rebuilds without an explicit "y".
    if $DRY_RUN; then say_ok "already under nix-darwin — would ask (default No) whether to rebuild to ${rev:0:12}"; summary rebuild ok "already managed"; return 0; fi
    if ! ask n "Already under nix-darwin. Rebuild now to apply origin/main ${rev:0:12}?"; then
      say_ok "already under nix-darwin — skipping the rebuild"; phase_mark rebuild skipped "already managed"; return 0
    fi
  elif $DRY_RUN; then
    say_plan "would run scripts/rebuild.sh --plan-only, ask, then scripts/rebuild.sh (its own prompts: flakes, Homebrew owner, /etc files, the switch)"
    summary rebuild plan
    phase_secrets
    return 0
  fi

  ts=$(date +%Y%m%d-%H%M%S)
  plan_log="$STATE_DIR/rebuild-plan-$ts.log"; run_log="$STATE_DIR/rebuild-$ts.log"
  say_do "scripts/rebuild.sh --plan-only   (log: $plan_log)"
  if ! act_rebuild "$plan_log" --plan-only; then
    REBUILD_LOGS="$plan_log"
    say_err "rebuild.sh --plan-only stopped — fix what it printed above, then re-run this script"
    STOP_REASON="rebuild.sh --plan-only failed"; phase_mark rebuild failed "plan-only"; return 1
  fi
  REBUILD_LOGS="$plan_log"
  phase_secrets || return $?
  if ! ask y "Apply this plan now? (rebuild.sh still asks before it switches)" auto; then
    STOP_REASON="rebuild declined"; phase_mark rebuild stopped declined; return 3
  fi
  say_do "scripts/rebuild.sh   (log: $run_log)"
  if act_rebuild "$run_log"; then
    REBUILD_LOGS="$REBUILD_LOGS $run_log"
    say_ok "rebuild applied ${rev:0:12}"
    state_set rebuild.rev "$rev"
    phase_mark rebuild ok "${rev:0:12}"; return 0
  fi
  REBUILD_LOGS="$REBUILD_LOGS $run_log"
  say_err "rebuild.sh did not complete — fix what it printed above, then re-run this script"
  STOP_REASON="rebuild.sh failed"; phase_mark rebuild failed; return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# Phase f — post-checks + what stays manual
# ═════════════════════════════════════════════════════════════════════════════
phase_verify() {
  section "f. Verify"
  local fails=0 role_reg l home restic_cmd

  if [ -n "$P_AUTOUPDATE" ]; then
    if probe_fleet_update; then say_ok "org.rh7.fleet-update loaded (channel $P_AUTOUPDATE)"
    else say_warn "org.rh7.fleet-update not loaded (autoUpdate = $P_AUTOUPDATE)"; fails=$((fails + 1)); fi
  else say_ok "autoUpdate off for $HOST — no fleet-update daemon expected"; fi

  if role_has_firewall "$P_ROLE"; then
    if probe_firewall; then say_ok "application firewall on"
    else say_warn "application firewall off — ~/dotfiles/scripts/fleet-fix.sh firewall --apply"; fails=$((fails + 1)); fi
  else say_ok "firewall not managed by role $P_ROLE"; fi

  if probe_launcher; then say_ok "fleet launcher $FLEET_LAUNCHER"
  else say_warn "fleet launcher missing ($FLEET_LAUNCHER) — a rebuild from current main installs it"; fails=$((fails + 1)); fi

  if $DRY_RUN; then say_plan "would run one audit (rh7-fleet-audit, else ~/dotfiles/scripts/collector-runner.sh)"
  elif [ -z "$CS_URL" ]; then say_warn "config service unreachable — skipping the audit"
  elif ask y "Run one fleet audit now (read-only; uploads to $CS_URL)?" auto; then
    if act_audit; then say_ok "audit uploaded"; state_set audit.at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else say_warn "audit failed — re-run: ~/dotfiles/scripts/collector-runner.sh"; fails=$((fails + 1)); fi
  fi

  # What stays manual — each with the exact step.
  for l in $REBUILD_LOGS; do
    if [ -r "$l" ] && grep -q 'App Management' "$l"; then
      manual "App Management: rebuild.sh needed it this run — System Settings → Privacy & Security → App Management → your terminal stays allowed (or remove it again once adoption is done)."
      break
    fi
  done
  manual "Optional Full Disk Access (lets the audit and restic see Desktop/Documents/Photos…): System Settings → Privacy & Security → Full Disk Access → + → ⇧⌘G → $FLEET_LAUNCHER → Open, switch on; then launchctl kickstart -k gui/\$(id -u $P_USER)/com.rh7.collector-runner"
  if ! $DRY_RUN && probe_launcher && ask n "Open the Full Disk Access settings pane now?"; then act_open_fda || true; fi

  if $P_RESTIC; then
    home=$(user_home "$P_USER"); [ -n "$home" ] || home="/Users/$P_USER"
    if probe_restic_configured "$home"; then say_ok "restic configured for $P_USER"
    else
      if [ "$P_USER" = "$(id -un)" ]; then restic_cmd="rh7-restic-backup setup"; else restic_cmd="sudo -u $P_USER -H rh7-restic-backup setup"; fi
      manual "Restic (resticBackup = true): ssh $STUDIO_SSH_HOST '~/rh-device-management/scripts/restic-server-add-host.sh $HOST' | $restic_cmd   — then escrow ~/.config/rh7-restic/repo-password (escrow-secrets-1password.sh --env …), then rh7-restic-backup run"
    fi
  fi

  manual "Tailscale admin console (login.tailscale.com/admin/machines): disable key expiry for $HOST and check its identity/tags — the ACL (rh7/tailscale-acl) must let it reach $STUDIO_SSH_HOST:3456 (audits)$($P_RESTIC && echo ' and :8000 (restic)')."
  role_reg=$(probe_registry_role 2>/dev/null || true)
  if [ "$role_reg" = unknown ]; then
    manual "Registry role is 'unknown' — from an admin tailnet identity: curl -s -X PATCH -H 'content-type: application/json' -d '{\"role\":\"personal\"}' $CS_URL/api/devices/$HOST   (pick the right role)"
  fi

  if $DRY_RUN; then summary verify plan "$fails check(s) not yet satisfied"
  elif [ "$fails" -eq 0 ]; then phase_mark verify ok
  else phase_mark verify warn "$fails check(s) need attention"; fi
  return 0
}

# ── driver ───────────────────────────────────────────────────────────────────
usage() {
  local self="${BASH_SOURCE[0]:-}"
  if [ -n "$self" ] && [ -r "$self" ]; then sed -n '2,50p' "$self" | sed 's/^# \{0,1\}//'
  else echo "usage: adopt.sh [--dry-run] [--yes] [--skip-nix-install]"; fi
}

print_summary() {
  local rc="$1"
  section "Summary"
  $DRY_RUN && say_info "DRY RUN — nothing was changed and no state was written."
  [ -n "$SUMMARY" ] && printf '%s' "$SUMMARY"
  if [ -n "$STOP_REASON" ]; then
    printf '\n'
    if [ "$rc" -eq 3 ]; then say_ask "Stopped: $STOP_REASON"; else say_err "Stopped: $STOP_REASON"; fi
  fi
  if [ -n "$MANUAL" ]; then
    printf '\n%sRemaining manual steps%s\n' "$C_C" "$C_0"
    printf '%s' "$MANUAL" | awk 'NF {n++; printf "  %d. %s\n", n, $0}'
  fi
  if ! $DRY_RUN && [ -r "$STATE_FILE" ]; then printf '\n  state: %s\n' "$STATE_FILE"; fi
  [ "$rc" -eq 3 ] && say_info "Re-run the same command after that; finished phases are skipped."
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --yes|-y) ASSUME_YES=true ;;
      --skip-nix-install) SKIP_NIX_INSTALL=true ;;
      -h|--help) usage; return 0 ;;
      *) echo "adopt.sh: unknown option '$1' (try --help)" >&2; return 64 ;;
    esac
    shift
  done

  printf '%srh7 adopt v%s%s%s\n' "$C_C" "$ADOPT_VERSION" "$($DRY_RUN && echo ' — DRY RUN (no changes)')" "$C_0"
  trap '[ -n "$FLAKE_FILE" ] && rm -f "$FLAKE_FILE"' EXIT
  state_load
  local last; last=$(state_get updated_at)
  [ -n "$last" ] && say_info "resuming — last run $last (state: $STATE_FILE)"

  local rc=0
  phase_preflight || rc=$?
  if [ "$rc" -ne 0 ]; then summary preflight failed; print_summary 1; return 1; fi
  phase_mark preflight ok "$HOST"
  state_set host "$HOST"

  if ! $FLAKE_HAS_HOST; then
    phase_no_flake_entry; rc=$?
    phase_mark flake stopped "no entry"
    print_summary "$rc"; return "$rc"
  fi
  phase_mark flake ok "entry present"

  local p
  for p in phase_xcode phase_nix phase_dotfiles phase_rebuild; do
    "$p"; rc=$?
    if [ "$rc" -ne 0 ]; then print_summary "$rc"; return "$rc"; fi
  done
  phase_verify
  [ -n "$FLAKE_FILE" ] && rm -f "$FLAKE_FILE"
  print_summary 0
  return 0
}

if [ "${ADOPT_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
  exit $?
fi
