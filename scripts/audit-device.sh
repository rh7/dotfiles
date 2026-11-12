#!/usr/bin/env bash
# Fleet device audit — non-destructive inventory collection and registration.
# Replaces the old heartbeat.sh with a single daily audit + registration.
#
# Usage:
#   ./scripts/audit-device.sh              # interactive menu
#   ./scripts/audit-device.sh --run        # audit + upload (non-interactive, for cron)
#   ./scripts/audit-device.sh --local      # audit only, print JSON (no upload)
#   ./scripts/audit-device.sh --save       # audit and save to ~/dotfiles-backups/audit/
#   ./scripts/audit-device.sh --local --include-protected
#                                              # opt in to cloud/browser/personal-folder checks
#   ./scripts/audit-device.sh --install    # install daily schedule (LaunchAgent on macOS, cron on Linux)
#   ./scripts/audit-device.sh --uninstall  # remove daily schedule
#
# On machines without the dotfiles repo (e.g. fresh Mac):
#   curl -fsSL config.rh7labs.com/audit | bash

set -euo pipefail

# Preserve the hostname's canonical case (#62). The config service uses hostname
# as the devices-table PRIMARY KEY, and setup.sh registers + the flake names hosts
# in canonical case (scutil --set HostName "$HOSTNAME"). Lowercasing here made the
# daily audit POST under a different case, creating a SECOND (duplicate) row for
# any mixed-case host (e.g. Kassie-M5-Air13 vs kassie-m5-air13). Match setup/flake:
# strip a trailing .local, keep the case as the OS reports it.
HOSTNAME="$(hostname | sed 's/\.local$//')"
OS="$(uname -s)"
ARCH="$(uname -m)"
# Scheduled jobs do not inherit the interactive shell's Nix/Homebrew paths.
# Normalize them before collection so casks, MAS apps, and host config evaluation
# do not silently report "not installed" on otherwise-managed Macs.
export PATH="/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
MODE="interactive"
MODE_SEEN=0
# Standard and scheduled audits must not ask for access to personal folders,
# cloud-provider roots, browser profiles, Wi-Fi identity, or System Events.
# Operators can explicitly opt into those checks for a one-off deep audit.
AUDIT_INCLUDE_PROTECTED="${AUDIT_INCLUDE_PROTECTED:-0}"
for raw_arg in "$@"; do
  arg="${raw_arg//[$'\t\r\n ']/}"
  case "$arg" in
    "") ;;
    --include-protected) AUDIT_INCLUDE_PROTECTED=1 ;;
    *)
      if [[ "$MODE_SEEN" == "1" ]]; then
        MODE="__multiple_modes__"
      else
        MODE="$arg"
        MODE_SEEN=1
      fi
      ;;
  esac
done
[[ "$AUDIT_INCLUDE_PROTECTED" == "1" ]] || AUDIT_INCLUDE_PROTECTED=0
export AUDIT_INCLUDE_PROTECTED
SCRIPT_URL="https://config.rh7labs.com/audit"
CRON_TAG="# fleet-audit"
OLD_CRON_TAG="# fleet-heartbeat"

# ── Self-reexec guard: survive `curl … | bash` (#217) ──
# Under a pipe, fd 0 (stdin) *is* this script. Several collectors below shell out
# to commands that read stdin, which consume the not-yet-executed remainder of
# THIS script — so bash hits EOF and exits 0 *before* the upload/register/schedule
# code runs, leaving a silent half-audit (JSON built, never sent). If we're being
# read from a pipe (stdin is not a tty AND there is no real script file on disk),
# re-fetch ourselves to a temp file and exec from there with stdin detached, so no
# collector can eat the script:
#   • `bash file` / cron's `bash "$t"`          → BASH_SOURCE[0] is a real file → skip
#   • enroll's temp-file wrapper (`bash "$t" </dev/null`) → real file          → skip
#   • `curl … | bash -s`                        → BASH_SOURCE[0] empty/not-file → re-exec
# Fails soft: if the self-fetch (or mktemp) fails, fall through to the piped path,
# no worse than today. AUDIT_REEXEC prevents any re-exec loop.
if [[ -z "${AUDIT_REEXEC:-}" && ! -t 0 && ! -f "${BASH_SOURCE[0]:-/nonexistent}" ]]; then
  if _self="$(mktemp 2>/dev/null)" && curl -fsSL "$SCRIPT_URL" -o "$_self" 2>/dev/null && [[ -s "$_self" ]]; then
    AUDIT_REEXEC=1 exec bash "$_self" "$@" </dev/null
  fi
  [[ -n "${_self:-}" ]] && rm -f "$_self"   # couldn't self-fetch — fall through
fi

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

# run_timeout SECS CMD... — run a command with a hard timeout so a wedged daemon
# (e.g. a stuck tailscaled, #61) can't hang the audit forever. Prefers coreutils
# timeout/gtimeout (Linux, nix); falls back to perl (/usr/bin/perl ships on macOS,
# which has no `timeout`): the parent arms an alarm and SIGKILLs the child on
# overrun, exiting 124 like GNU timeout; the child execs the command so its stdout
# passes through for $() capture. On timeout the child is killed and we return
# non-zero with no output, so callers degrade via their existing `|| echo ""`.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; my $p=fork; if($p){$SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm $s; waitpid $p,0; exit($?>>8)} else {exec @ARGV or exit 127}' "$secs" "$@"
  else
    "$@"
  fi
}

# >>> BEGIN SHARED DATA CLASSIFICATION >>>
# What a folder on a Mac IS, for deciding whether its loss matters. This block is
# duplicated VERBATIM in scripts/pre-wipe-check.sh (bash 3.2, reads it through
# data_class_rule) and scripts/audit-device.sh (its data_inventory Python reads
# the same variables from the environment), and
# scripts/tests/data-inventory.test.sh fails if the two copies drift.
#
# It cannot be a sourced library or a Python module: both scripts are
# distributed as SINGLE SELF-CONTAINED FILES (the collector as one
# `git show <ref>:scripts/audit-device.sh` blob, pre-wipe-check via
# `curl … | bash`), so a sibling file never reaches the device. Plain data in a
# shell variable is the one format both a bash 3.2 `case` and Python's fnmatch
# read the same way. Same pattern as the shared config-service resolver.
#
# DATA_CLASS_RULES rows: scope|pattern|kind|category|status|note — first match
# wins, pattern is a shell glob (no `|`, no brackets).
#   scope    home = a top-level entry of $HOME; appdata = an entry of
#            ~/Library/Application Support, Containers or Group Containers
#   kind     pre-wipe-check's own judgement. home: skip dd standard music cloud
#            secret vm cache other; appdata: RED AMBER VM NONE, or - (no flag)
#   category data_inventory category; for kind=cloud the coverage token
#            (icloud, dropbox, cloud-storage) of everything under that root
#   status   data_inventory status: reinstallable / unprotected, or skip and
#            cloud (not an item: excluded from the inventory)
# Not listed = kind other, category user-data (home) / app-data, unprotected.
DATA_CLASS_RULES='home|Library|skip|-|skip|
home|.Trash|skip|-|skip|
home|Applications|skip|-|skip|
home|.DS_Store|skip|-|skip|
home|.CFUserTextEncoding|skip|-|skip|
home|.localized|skip|-|skip|
home|Desktop|dd|user-data|unprotected|
home|Documents|dd|user-data|unprotected|
home|Downloads|standard|downloads|unprotected|Downloads is never synced by iCloud
home|Movies|standard|user-data|unprotected|
home|Pictures|standard|user-data|unprotected|Photos libraries are listed separately
home|Public|standard|user-data|unprotected|
home|Sites|standard|user-data|unprotected|
home|Music|music|user-data|unprotected|purchases re-download; imported music does not
home|iCloud Drive (Archive)*|other|user-data|unprotected|local copy left when iCloud Drive was turned off
home|Dropbox|cloud|dropbox|cloud|
home|Dropbox (*|cloud|dropbox|cloud|
home|OneDrive|cloud|cloud-storage|cloud|
home|OneDrive*|cloud|cloud-storage|cloud|
home|Google Drive|cloud|cloud-storage|cloud|
home|Google Drive (*|cloud|cloud-storage|cloud|
home|Creative Cloud Files*|cloud|cloud-storage|cloud|
home|Box|cloud|cloud-storage|cloud|
home|Box Sync|cloud|cloud-storage|cloud|
home|iCloud Drive|cloud|icloud|cloud|
home|.ssh|secret|user-data|unprotected|credentials: escrow private keys
home|.gnupg|secret|user-data|unprotected|credentials: escrow secret keys
home|.aws|secret|user-data|unprotected|credentials
home|.kube|secret|user-data|unprotected|credentials
home|.netrc|secret|user-data|unprotected|credentials
home|.git-credentials|secret|user-data|unprotected|credentials
home|.password-store|secret|user-data|unprotected|credentials
home|.orbstack|vm|app-data|unprotected|VM/container disks are local only (images re-pull)
home|OrbStack|vm|app-data|unprotected|VM/container disks are local only (images re-pull)
home|.lima|vm|app-data|unprotected|VM disks are local only
home|.colima|vm|app-data|unprotected|VM disks are local only
home|.docker|vm|app-data|unprotected|container config and contexts
home|.vagrant.d|vm|app-data|unprotected|VM boxes re-download; VM disks do not
home|Parallels|vm|app-data|unprotected|VM disks are local only
home|Virtual Machines|vm|app-data|unprotected|VM disks are local only
home|Virtual Machines.localized|vm|app-data|unprotected|VM disks are local only
home|VirtualBox VMs|vm|app-data|unprotected|VM disks are local only
home|.dropbox|cache|app-data|reinstallable|Dropbox internal state (sync database, cache); re-created when Dropbox signs in
home|.dropbox-dist|cache|tooling|reinstallable|Dropbox app binaries
home|.dropbox-master|cache|app-data|reinstallable|Dropbox internal state
home|.cache|cache|cache|reinstallable|
home|.npm|cache|cache|reinstallable|
home|.pnpm-store|cache|cache|reinstallable|
home|.yarn|cache|cache|reinstallable|
home|.node-gyp|cache|cache|reinstallable|
home|.gradle|cache|cache|reinstallable|
home|.m2|cache|cache|reinstallable|
home|.pub-cache|cache|cache|reinstallable|
home|.dartServer|cache|cache|reinstallable|
home|.cocoapods|cache|cache|reinstallable|
home|.zsh_sessions|cache|cache|reinstallable|
home|.ollama|cache|tooling|reinstallable|model weights re-download (ollama pull)
home|.lmstudio|cache|tooling|reinstallable|model weights re-download
home|.huggingface|cache|tooling|reinstallable|model weights re-download
home|.npm-global|cache|tooling|reinstallable|
home|.cargo|cache|tooling|reinstallable|
home|.rustup|cache|tooling|reinstallable|
home|.bun|cache|tooling|reinstallable|
home|.nvm|cache|tooling|reinstallable|
home|.pyenv|cache|tooling|reinstallable|
home|.rbenv|cache|tooling|reinstallable|
home|.gem|cache|tooling|reinstallable|
home|.vscode|cache|tooling|reinstallable|editor extensions
home|.vscode-insiders|cache|tooling|reinstallable|editor extensions
home|.cursor|cache|tooling|reinstallable|editor extensions
home|.windsurf|cache|tooling|reinstallable|editor extensions
home|.deno|cache|tooling|reinstallable|
home|.expo|cache|tooling|reinstallable|
home|.android|cache|tooling|reinstallable|
home|.swiftpm|cache|tooling|reinstallable|
home|.platformio|cache|tooling|reinstallable|
home|go|cache|tooling|reinstallable|
home|.nix-defexpr|cache|tooling|reinstallable|
home|.nix-profile|cache|tooling|reinstallable|
home|.conda|cache|tooling|reinstallable|
home|miniconda3|cache|tooling|reinstallable|
home|anaconda3|cache|tooling|reinstallable|
appdata|Signal|RED|app-data|unprotected|Signal Desktop history is not synced to a new install
appdata|org.whispersystems.signal-desktop*|RED|app-data|unprotected|Signal Desktop history is not synced to a new install
appdata|*WhatsApp*|AMBER|app-data|reinstallable|WhatsApp Desktop history lives on the phone; re-link after the wipe
appdata|*whatsapp*|AMBER|app-data|reinstallable|WhatsApp Desktop history lives on the phone; re-link after the wipe
appdata|com.utmapp.UTM|VM|app-data|unprotected|virtual machine disks are local only
appdata|*Parallels*|VM|app-data|unprotected|virtual machine disks are local only
appdata|*parallels*|VM|app-data|unprotected|virtual machine disks are local only
appdata|VMware Fusion|VM|app-data|unprotected|virtual machine disks are local only
appdata|com.vmware.fusion*|VM|app-data|unprotected|virtual machine disks are local only
appdata|com.docker.docker|AMBER|app-data|unprotected|container volumes are local only (images re-pull)
appdata|Docker Desktop|AMBER|app-data|unprotected|container volumes are local only (images re-pull)
appdata|*dev.orbstack*|AMBER|app-data|unprotected|container volumes are local only (images re-pull)
appdata|OrbStack|AMBER|app-data|unprotected|container volumes are local only (images re-pull)
appdata|MobileSync|NONE|app-data|unprotected|iPhone/iPad backups made by Finder (pre-wipe-check judges them under Data cleanup candidates)
appdata|obsidian|NONE|app-data|reinstallable|Obsidian app settings; the vaults are separate folders
appdata|Dropbox|-|app-data|reinstallable|Dropbox app state; re-created on sign-in
appdata|CloudDocs|-|app-data|reinstallable|iCloud Drive internal state
appdata|Ollama|-|tooling|reinstallable|
appdata|LM Studio|-|tooling|reinstallable|
appdata|Steam|-|tooling|reinstallable|games re-download; saves sync via Steam Cloud
appdata|Caches|-|cache|reinstallable|'

# Chromium-family browsers: "Label:path under ~/Library/Application Support".
CHROMIUM_BROWSERS="Google Chrome:Google/Chrome
Brave:BraveSoftware/Brave-Browser
Microsoft Edge:Microsoft Edge
Vivaldi:Vivaldi
Arc:Arc/User Data
Dia:Dia/User Data
Chromium:Chromium"

# Wallet apps: "Name|keys|app bundles;…|data dirs under ~;…". keys=local means
# the app's own files may hold (encrypted) private keys; hardware means the
# keys are on a device and the app data is a cache. Folders are only tested
# for existence and sized — never opened.
WALLET_APPS="Exodus|local|Exodus.app|Library/Application Support/Exodus
Electrum|local|Electrum.app|.electrum;Library/Application Support/Electrum
Ledger Live|hardware|Ledger Live.app|Library/Application Support/Ledger Live
MyCrypto|local|MyCrypto.app|Library/Application Support/MyCrypto
KeepKey|hardware|KeepKey Desktop.app;KeepKey Client.app;KeepKey.app|Library/Application Support/KeepKey;Library/Application Support/keepkey-desktop;Library/Application Support/KeepKey Desktop
Cypherock|hardware|cySync.app;Cypherock cySync.app;Cypherock.app|Library/Application Support/cySync;Library/Application Support/Cypherock
Atomic Wallet|local|Atomic Wallet.app|Library/Application Support/atomic;Library/Application Support/Atomic Wallet"
# Wallet browser extensions (Chrome Web Store ids): "id|Name".
WALLET_EXTENSIONS="nkbihfbeogaeaoehlefnkodbefgpgknn|MetaMask
bfnaelmomeimhlpmgjnjophhpkkoljpa|Phantom
hnfanknocfeofbddgcijnmhnfnkdnaad|Coinbase Wallet
acmacodkjbdgmoleebolmdjonilkdbch|Rabby"

# data_class_rule SCOPE NAME → "kind|category|status|note" of the first
# matching row; returns 1 when no row matches. bash 3.2-safe, no temp files.
data_class_rule() {
  local scope="$1" name="$2" s pat kind cat st note
  while IFS='|' read -r s pat kind cat st note; do
    [ "$s" = "$scope" ] || continue
    # shellcheck disable=SC2254  # $pat IS the glob
    case "$name" in $pat) printf '%s|%s|%s|%s\n' "$kind" "$cat" "$st" "$note"; return 0 ;; esac
  done < <(printf '%s\n' "$DATA_CLASS_RULES")
  return 1
}
# <<< END SHARED DATA CLASSIFICATION <<<

# ── Validate mode up front ──────────────────────────────────────────────
# Fail loud on an unrecognized mode instead of silently running a no-op audit:
# the early-exit guards (--install/--uninstall/--checklist) use exact matches and
# the final dispatch has NO default case, so a garbled/mistyped flag would print
# "Auditing…", collect for ~30s, then exit having done nothing (no upload, no
# install). Catch it here, before the expensive audit.
case "$MODE" in
  interactive|--run|--local|--save|--install|--uninstall|--checklist|--run-and-install|report) ;;
  *)
    err "Unknown mode: '$MODE'"
    err "Valid: --run | --local | --save | --install | --uninstall | --checklist (or no arg for the menu)"
    err "Optional: --include-protected (may request access to personal/cloud folders and browser profiles)"
    exit 2
    ;;
esac

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
    # Download-then-exec, NOT `curl … | bash`: under a pipe stdin is the script,
    # and a collector that reads stdin consumes the rest of it — truncating the
    # audit before it uploads (the no-clone daily audit would silently do
    # nothing). Running from a temp file avoids it (mirrors enroll.sh run_audit).
    echo "t=\"\$(mktemp)\" && curl -fsSL $SCRIPT_URL -o \"\$t\" && bash \"\$t\" --run; rm -f \"\$t\""
  fi
}

install_launchagent() {
  local audit_cmd
  audit_cmd="$(build_audit_cmd)"
  local hour=8
  local minute=$(( RANDOM % 30 ))

  mkdir -p "$HOME/Library/LaunchAgents" || {
    err "Cannot create ~/Library/LaunchAgents — daily audit NOT scheduled."; return 1; }
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

  # Explicit checks (don't rely on errexit): install_cron is called as
  # `install_cron || warn`, which suspends `set -e` inside this function, so a
  # failed plist write or `launchctl load` would otherwise fall through to the
  # "Installed" message and falsely return success.
  if [[ ! -s "$LAUNCHAGENT_PLIST" ]]; then
    err "Failed to write LaunchAgent plist ($LAUNCHAGENT_PLIST) — daily audit NOT scheduled."
    return 1
  fi
  launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
  if ! launchctl load "$LAUNCHAGENT_PLIST"; then
    err "Failed to load LaunchAgent (launchctl load) — daily audit NOT scheduled."
    return 1
  fi
  ok "Installed daily audit LaunchAgent ($(printf '%d:%02d' "$hour" "$minute") AM)"
  info "→ $LAUNCHAGENT_PLIST"
  info "→ $audit_cmd"
}

install_crontab() {
  local audit_cmd cron_min cron_line existing new_crontab
  if ! command -v crontab >/dev/null 2>&1; then
    err "cron is not installed on this host — the daily audit was NOT scheduled."
    err "Install it and re-run, e.g.: sudo apt-get install -y cron && sudo systemctl enable --now cron"
    return 1
  fi
  audit_cmd="$(build_audit_cmd)"
  cron_min=$(( RANDOM % 30 ))
  cron_line="${cron_min} 8 * * * ${audit_cmd} ${CRON_TAG}"
  # Read the existing crontab, stripping any prior fleet entries. On a fresh box
  # `crontab -l` is empty, so the `grep -v` filters find no match and exit 1;
  # under `set -euo pipefail` that used to abort the whole script HERE — before
  # the new line was ever written — so the schedule silently never installed.
  # `|| true` neutralizes the empty-input exit; the assignment always succeeds.
  existing="$(crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$OLD_CRON_TAG" || true)"
  if [[ -n "$existing" ]]; then
    new_crontab="${existing}"$'\n'"${cron_line}"
  else
    new_crontab="${cron_line}"
  fi
  if printf '%s\n' "$new_crontab" | crontab -; then
    ok "Installed daily audit cron (8:$(printf '%02d' "$cron_min") AM)"
    info "→ $audit_cmd"
  else
    err "Failed to write crontab (is the cron service running?) — daily audit NOT scheduled."
    return 1
  fi
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

# ── Find config service ─────────────────────────────────────────────────
#
# Defined HERE, above the mode dispatch, because `--checklist` below calls it.
# It used to be defined ~10 lines further down, after that call, so
# `--checklist` has never worked -- it died on
# `line 312: find_config_service: command not found`, and under `set -e` the
# failing command substitution took the whole invocation with it.
#
# CONTRACT -- DO NOT CHANGE: echo a base URL or nothing, and ALWAYS return 0.
# Both call sites run `CONFIG_URL=$(find_config_service)` under `set -euo
# pipefail`, so a non-zero return aborts the entire audit instead of degrading
# to the "print locally" path they carefully implement for an empty result.
#
# WHY THIS IS NOT A PROBE-FIRST LIST ANY MORE
# The previous implementation walked a hardcoded host list and took the FIRST
# RESPONDER, starting with `localhost`. Two consequences:
#
#   1. Any host that happens to run its own config-service instance silently
#      registers itself into that local database instead of the fleet's. Every
#      side looks perfectly healthy; each simply holds a subset of the fleet.
#      Moving the service to another host makes this near-certain rather than
#      theoretical, because the new host answers its own probe first.
#   2. Relocating the service means editing this list and waiting for every
#      host to pick up a new script -- discovery encoded as source control.
#
# So: an explicit pin wins, and probing survives only to bootstrap a host that
# has never been told anything. `/api/health` carries no instance identity
# (every instance returns the same body but for a timestamp), so a client
# CANNOT tell the authoritative service from any other by asking it. That is
# precisely why the answer has to be configuration rather than interrogation.
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

# `--checklist` above calls both of these, so like find_config_service they
# must be defined before the mode dispatch rather than ~2300 lines below it.
# They were not, so fixing the find_config_service ordering only moved the
# failure one line on, to `show_checklist: command not found`. Pure
# relocation — no logic changed. The later --run path calls them too and is
# unaffected, since a definition merely has to precede first RUNTIME use.
fetch_device_role() {
  local config_url="$1"
  curl -sf "${config_url}/api/devices/${HOSTNAME}" --max-time 5 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('role','') or '')" 2>/dev/null
}

show_checklist() {
  local config_url="$1"
  local role
  # `|| true`: this is a cosmetic display step and MUST NOT abort the script.
  # Under `set -euo pipefail`, a role the server has no checklist for (e.g.
  # `server`, which 400s) makes `curl -sf` exit 22 — which used to kill the
  # whole audit run right here, skipping the cron install that follows.
  role=$(fetch_device_role "$config_url" || true)
  [[ -z "$role" ]] && role="workstation"

  local checklist
  checklist=$(curl -sf "${config_url}/api/fleet/checklist/${role}" --max-time 5 2>/dev/null || true)
  [[ -z "$checklist" ]] && return 0

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

collect_virtualization_prerequisites() {
  local lima_version=""

  if command -v limactl >/dev/null 2>&1; then
    # `limactl --version` currently prints "limactl version X.Y.Z". Keep only
    # the final token so the fleet audit exposes no executable or state paths.
    lima_version="$(limactl --version 2>/dev/null | awk 'NR == 1 { print $NF }' || true)"
    python3 - "$lima_version" <<'PY'
import json
import sys

version = sys.argv[1].strip()
print(json.dumps({
    "lima": {
        "installed": True,
        "version": version or None,
    }
}))
PY
  else
    echo '{"lima":{"installed":false,"version":null}}'
  fi
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

collect_config_drift() {
  if [[ "$OS" != "Darwin" ]]; then
    echo '{"supported":false,"status":"unavailable","reason":"macOS only"}'
    return
  fi

  local drift_script="${DOTFILES:-$HOME/dotfiles}/scripts/audit-config-drift.sh"
  if [[ ! -x "$drift_script" ]]; then
    echo '{"supported":false,"status":"unavailable","reason":"audit-config-drift.sh not found in dotfiles checkout"}'
    return
  fi

  local result
  result=$(run_timeout 180 "$drift_script" --json "$HOSTNAME" 2>/dev/null || true)
  if [[ -n "$result" ]] && python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$result" 2>/dev/null; then
    echo "$result"
  else
    echo '{"supported":false,"status":"error","reason":"config drift audit failed or returned invalid JSON"}'
  fi
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

collect_npm_config() {
  if ! command -v npm &>/dev/null; then echo '{"installed":false}'; return; fi

  local npm_path node_path prefix global_root cache userconfig globalconfig
  npm_path="$(command -v npm 2>/dev/null || true)"
  node_path="$(command -v node 2>/dev/null || true)"
  prefix="$(npm config get prefix 2>/dev/null || true)"
  global_root="$(npm root -g 2>/dev/null || true)"
  cache="$(npm config get cache 2>/dev/null || true)"
  userconfig="$(npm config get userconfig 2>/dev/null || true)"
  globalconfig="$(npm config get globalconfig 2>/dev/null || true)"

  python3 - "$npm_path" "$node_path" "$prefix" "$global_root" "$cache" "$userconfig" "$globalconfig" "$PATH" <<'PY' 2>/dev/null || echo '{}'
import json, os, sys

def clean(value):
    value = (value or '').strip()
    return '' if value == 'undefined' else value

npm_path, node_path, prefix, global_root, cache, userconfig, globalconfig, path = map(clean, sys.argv[1:9])
prefix_bin = os.path.join(prefix, 'bin') if prefix else ''

print(json.dumps({
    'installed': True,
    'npm_path': npm_path,
    'node_path': node_path,
    'prefix': prefix,
    'global_root': global_root,
    'cache': cache,
    'userconfig': userconfig,
    'globalconfig': globalconfig,
    'prefix_in_nix_store': prefix.startswith('/nix/store/'),
    'global_root_in_nix_store': global_root.startswith('/nix/store/'),
    'prefix_bin_on_path': bool(prefix_bin and prefix_bin in path.split(os.pathsep)),
}))
PY
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
  # SSH public keys with fingerprints (#67): {name, type, bits, SHA256
  # fingerprint, comment}. Fingerprints let the same key be matched across
  # devices for the authorization graph + dead-grant detection. Reads .pub files
  # only — no private material leaves the device, and no passphrase prompt.
  python3 - <<'PYEOF' 2>/dev/null || echo '[]'
import os, json, subprocess
ssh_dir = os.path.expanduser('~/.ssh')
keys = []
if os.path.isdir(ssh_dir):
    for f in sorted(os.listdir(ssh_dir)):
        if not f.endswith('.pub'):
            continue
        path = os.path.join(ssh_dir, f)
        entry = {'name': f[:-4]}
        try:
            r = subprocess.run(['ssh-keygen', '-lf', path], capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                # "256 SHA256:xxxx comment with spaces (ED25519)"
                parts = r.stdout.strip().split()
                if len(parts) >= 2:
                    entry['bits'] = int(parts[0]) if parts[0].isdigit() else None
                    entry['fingerprint'] = parts[1]
                    if parts[-1].startswith('(') and parts[-1].endswith(')'):
                        entry['type'] = parts[-1][1:-1]
                    entry['comment'] = ' '.join(parts[2:-1])
        except Exception:
            pass
        keys.append(entry)
print(json.dumps(keys))
PYEOF
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

# Workload registry feed (rh-device-management #128, epic #126). Emits a flat,
# normalized array of the managed processes RUNNING on this host so the config
# service can answer "what runs where, how critical, healthy?" across the fleet.
# Server expects: [{name, kind(docker|compose|launchd|systemd), status, port?,
# image?, restart?, compose_project?}]. tier/deploy_repo are NOT set here — the
# server curates those from src/workloads.ts. Reports running processes only and
# stays bounded: docker containers, non-Apple launchd agents (skips com.apple.*),
# and running systemd services. The server classifies each into app/infra/system
# and collapses OS plumbing in the UI. Fails soft to [].
collect_workloads() {
  python3 - "$OS" <<'PYEOF' 2>/dev/null || echo '[]'
import subprocess, json, sys, re
host_os = sys.argv[1] if len(sys.argv) > 1 else ''

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''

def first_host_port(ports):
    # "0.0.0.0:3456->3456/tcp, :::3456->..." -> 3456 (first published host port)
    m = re.search(r':(\d+)->', ports or '')
    return int(m.group(1)) if m else None

workloads = []

# --- Docker (running only); compose-managed containers => kind 'compose' ---
if run('command -v docker'):
    out = run("docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Labels}}'")
    for line in (out.split('\n') if out else []):
        if not line.strip():
            continue
        p = line.split('\t')
        if len(p) < 5:
            p += [''] * (5 - len(p))
        name, image, status, ports, labels = p[0], p[1], p[2], p[3], p[4]
        project = None
        for kv in (labels or '').split(','):
            if kv.startswith('com.docker.compose.project='):
                project = kv.split('=', 1)[1]
        w = {'name': name, 'kind': 'compose' if project else 'docker',
             'status': 'running', 'image': image}
        port = first_host_port(ports)
        if port: w['port'] = port
        if project: w['compose_project'] = project
        workloads.append(w)

# --- macOS: non-Apple launchd agents, running ---
# Collect everything EXCEPT com.apple.* — that's ~500 OS agents/Mac (uniform,
# Apple-managed, non-actionable: 10x payload bloat for ~zero fleet value). The
# remaining non-Apple agents (com.local.*/com.rh7.* + homebrew + third-party) are
# the actionable layer; the server classifies them (app/infra/system) and the
# dashboard collapses any `system` ones. Drop com.apple here, not the meaningful
# rest — collect-don't-drop, scoped only where the volume is absurd.
if host_os == 'Darwin':
    out = run('launchctl list')
    for line in (out.split('\n')[1:] if out else []):
        cols = line.split('\t')
        if len(cols) < 3:
            continue
        pid, label = cols[0].strip(), cols[2].strip()
        # Skip com.apple.* (OS agents) and application.* (transient GUI-app
        # instances like Terminal/1Password — not services; a "missing" GUI app
        # isn't drift, so dropping these at collection is correct, not lossy).
        if not label or label.startswith('com.apple.') or label.startswith('application.'):
            continue
        # Running == has a numeric PID (not '-').
        if not pid.isdigit():
            continue
        workloads.append({'name': label, 'kind': 'launchd', 'status': 'running'})

# --- Linux: running systemd services (user + system), de-duped ---
else:
    seen = set()
    for scope in ('--user ', ''):
        out = run("systemctl %s list-units --type=service --state=running --no-legend --plain 2>/dev/null" % scope)
        for line in (out.split('\n') if out else []):
            unit = line.split()[0] if line.split() else ''
            if not unit.endswith('.service') or unit in seen:
                continue
            seen.add(unit)
            workloads.append({'name': unit[:-len('.service')], 'kind': 'systemd', 'status': 'running'})

print(json.dumps(workloads))
PYEOF
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

# SSH authorized_keys count + fingerprints (metadata only — for the cross-device
# authorization graph + dead-grant detection, #67).
auth_keys = os.path.expanduser('~/.ssh/authorized_keys')
if os.path.isfile(auth_keys):
    with open(auth_keys) as f:
        result['authorized_keys_count'] = len([l for l in f if l.strip() and not l.startswith('#')])
    try:
        r = subprocess.run(['ssh-keygen', '-lf', auth_keys], capture_output=True, text=True, timeout=5)
        fps = []
        if r.returncode == 0:
            for line in r.stdout.strip().split('\n'):
                parts = line.split()
                if len(parts) >= 2 and parts[1].startswith('SHA256:'):
                    fp = {'fingerprint': parts[1], 'comment': ' '.join(parts[2:-1])}
                    if parts[-1].startswith('(') and parts[-1].endswith(')'):
                        fp['type'] = parts[-1][1:-1]
                    fps.append(fp)
        if fps:
            result['authorized_keys_fingerprints'] = fps
    except Exception:
        pass

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

# Disk usage by key directories. Never recurse through the whole home directory
# in a standard audit: on macOS that crosses Desktop, Documents, iCloud Drive,
# Dropbox/File Provider roots, and browser data, triggering a wall of TCC access
# prompts. Root-disk capacity is already collected below.
dirs_to_check = {
    '/nix/store': '/nix/store',
    'docker': '/var/lib/docker',
}
if os.environ.get('AUDIT_INCLUDE_PROTECTED') == '1' or platform.system() != 'Darwin':
    dirs_to_check['home'] = os.path.expanduser('~')
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

# Usage and activity — is this machine actually being used, and by whom?
#
# Every other collector in this file records what a machine HAS: packages,
# containers, services, keys, config. None record whether anyone or anything
# is USING it. That gap is why a box can sit in the registry for months looking
# identical whether it is a daily driver or a forgotten VPS still paying rent.
# `resource_usage` is one instantaneous load-average reading per night, which
# cannot distinguish the two.
#
# This collects the cheap, high-signal answers: when a human last logged in,
# who is on the box right now, whether there are live tmux sessions, what is
# actually consuming CPU and memory, and per-container resource use.
#
# PRIVACY: process COMMAND LINES are deliberately not collected — only the
# executable name (`comm`). Full argv routinely carries tokens, connection
# strings and API keys, and this payload is POSTed to the config service and
# stored there. Shell history is reported by MODIFICATION TIME only, never
# content: "a human typed something here 4 hours ago" is the signal we want,
# and the commands themselves are none of the registry's business.
collect_usage_activity() {
  python3 -c "
import subprocess, json, os, platform, time, re, glob

def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ''

now = time.time()
result = {}
is_mac = platform.system() == 'Darwin'

# Boot time and uptime in SECONDS — comparable across hosts, unlike 'up 4 weeks'.
if is_mac:
    bt = run('sysctl -n kern.boottime')
    m = re.search(r'sec\s*=\s*(\d+)', bt)
    if m:
        result['boot_epoch'] = int(m.group(1))
        result['uptime_seconds'] = int(now - int(m.group(1)))
else:
    up = run('cat /proc/uptime')
    if up:
        try:
            secs = int(float(up.split()[0]))
            result['uptime_seconds'] = secs
            result['boot_epoch'] = int(now - secs)
        except Exception:
            pass

# Login history — the headline signal: when did a real person last touch this?
# Pseudo-entries are excluded so a rebooting box does not read as an active one.
SYSTEM_USERS = {'reboot', 'shutdown', 'runlevel', 'wtmp', 'btmp'}
logins = []
for line in run('last -n 60 2>/dev/null').split('\n'):
    line = line.strip()
    if not line or line.startswith('wtmp') or line.startswith('btmp'):
        continue
    parts = line.split()
    if len(parts) < 3 or parts[0] in SYSTEM_USERS:
        continue
    logins.append({'user': parts[0], 'tty': parts[1], 'from': parts[2],
                   'when': ' '.join(parts[3:8])})
result['recent_logins'] = logins[:25]
result['distinct_login_users'] = sorted({l['user'] for l in logins})
result['login_count_recent'] = len(logins)

# Who is on the box RIGHT NOW.
sessions = []
for line in run('who 2>/dev/null').split('\n'):
    parts = line.split()
    if len(parts) >= 2:
        sessions.append({'user': parts[0], 'tty': parts[1],
                         'since': ' '.join(parts[2:4]),
                         'from': parts[-1].strip('()') if parts[-1].startswith('(') else ''})
result['active_sessions'] = sessions
result['active_session_count'] = len(sessions)

# tmux — how this operator actually works. A long-lived attached session is the
# strongest cheap signal that a box is in daily hands-on use.
tmux_sessions = []
for line in run(\"tmux ls -F '#{session_name}|#{session_attached}|#{session_activity}' 2>/dev/null\").split('\n'):
    if '|' in line:
        name, attached, activity = (line.split('|') + ['', '', ''])[:3]
        entry = {'name': name, 'attached': attached not in ('0', '')}
        try:
            entry['idle_seconds'] = int(now - int(activity))
        except Exception:
            pass
        tmux_sessions.append(entry)
result['tmux_sessions'] = tmux_sessions
result['tmux_session_count'] = len(tmux_sessions)

# Shell history recency, by mtime only. Never the contents — see PRIVACY above.
hist = []
for pattern in ('/root/.zsh_history', '/root/.bash_history',
                '/home/*/.zsh_history', '/home/*/.bash_history',
                '/Users/*/.zsh_history', '/Users/*/.bash_history'):
    for path in glob.glob(pattern):
        try:
            st = os.stat(path)
            segs = path.split('/')
            hist.append({'path': path,
                         'user': segs[2] if len(segs) > 2 else '',
                         'modified_epoch': int(st.st_mtime),
                         'age_hours': round((now - st.st_mtime) / 3600, 1)})
        except Exception:
            pass
hist.sort(key=lambda h: h['modified_epoch'], reverse=True)
result['shell_history_activity'] = hist[:10]
if hist:
    result['hours_since_human_shell'] = hist[0]['age_hours']

# Top processes. Executable name only — see the PRIVACY note above.
#
# BSD and GNU ps disagree here: Linux has 'etimes' (raw seconds), macOS has only
# 'etime' ([[dd-]hh:]mm:ss). Asking macOS for 'etimes' does not fail the command —
# it warns on stderr and prints the remaining columns, so the row silently loses a
# field and every parse below drops it. That produced an empty process list on
# every Mac in the fleet while looking like a working collector.
def elapsed_to_seconds(v):
    try:
        return int(v)                      # Linux: already seconds
    except ValueError:
        pass
    days = 0
    if '-' in v:                           # macOS: [[dd-]hh:]mm:ss
        d, _, v = v.partition('-')
        days = int(d)
    bits = [int(x) for x in v.split(':')]
    while len(bits) < 3:
        bits.insert(0, 0)
    return days * 86400 + bits[0] * 3600 + bits[1] * 60 + bits[2]

procs = []
fmt = 'ps -Aeo pcpu,rss,etime,comm -r' if is_mac else 'ps -eo pcpu,rss,etimes,comm --sort=-pcpu'
for line in run(fmt).split('\n')[1:26]:
    parts = line.split(None, 3)
    if len(parts) == 4:
        try:
            cmd = os.path.basename(parts[3].strip())
            # Drop the measuring instrument: ps samples its own CPU during
            # startup and reports several hundred percent, so it lands at the top
            # of every host's list every night and pushes out a real entry. The
            # collector's own python3 may still appear; that one is at least
            # indistinguishable from a genuine python workload.
            #
            # NB: no backticks anywhere inside this python3 -c "..." string. It is
            # double-quoted shell, so a backtick pair is command substitution --
            # the shell runs it and pastes the OUTPUT into the python source. That
            # yields a SyntaxError, which the trailing 2>/dev/null || echo '{}'
            # then swallows into an empty section on every host, indefinitely.
            if cmd == 'ps':
                continue
            procs.append({'cpu_pct': float(parts[0]),
                          'rss_mb': round(int(parts[1]) / 1024, 1),
                          'elapsed_seconds': elapsed_to_seconds(parts[2]),
                          'command': cmd})
        except Exception:
            pass
result['top_processes_by_cpu'] = procs[:12]
result['top_processes_by_memory'] = sorted(procs, key=lambda p: p['rss_mb'], reverse=True)[:12]

# Per-container resource use. Container PRESENCE is already collected elsewhere;
# this says whether a running container is doing work or merely resident.
stats = []
for line in run(\"docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}' 2>/dev/null\", timeout=25).split('\n'):
    if '|' in line:
        name, cpu, mem, memp, net = (line.split('|') + [''] * 5)[:5]
        stats.append({'name': name, 'cpu_pct': cpu, 'mem_usage': mem,
                      'mem_pct': memp, 'net_io': net})
result['container_stats'] = stats

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

# Backup / replication posture (rh-device-management#76). Metadata ONLY — never
# reads file contents. Detection is not restore-verification; cloud sync is
# reported as enabled+coverage, explicitly NOT verified-current (there is no
# reliable upload-current CLI). Uses a quoted heredoc so the (larger) Python
# body needs no shell-escaping.
collect_backup_posture() {
  python3 - <<'PYEOF' 2>/dev/null || echo '{}'
import json, os, subprocess, platform, shutil, time, re, glob

def run(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ''

now = time.time()
sys = platform.system()
home = os.path.expanduser('~')
# Linux has no macOS TCC boundary, so preserve the existing root-based client
# detection there. The opt-in gate applies to macOS protected locations.
include_protected = os.environ.get('AUDIT_INCLUDE_PROTECTED') == '1' or sys != 'Darwin'
result = {
    'platform': sys,
    'protected_location_checks': 'collected' if include_protected else 'skipped',
}

def age_hours(epoch):
    try:
        return round((now - float(epoch)) / 3600.0, 1)
    except Exception:
        return None

# Presence of the paths the server's role policy may treat as important
# (backup-policy.ts: common + personal + developer + server sets). The server
# knows WHICH paths a role should protect but not which ones this device has,
# so without this it cannot tell "never created" from "exists and unprotected"
# — and reports a critical backup blocker for a directory that doesn't exist.
#
# Union of every role's set, so the server can look up whatever its policy
# produces. isdir() is a stat, not a listing, so this stays permission-safe and
# needs no --include-protected opt-in.
result['important_path_presence'] = {
    p: os.path.isdir(os.path.expanduser(p))
    for p in [
        '~/.config/sops/age',
        '~/.ssh',
        '~/.config',
        '~/Documents',
        '~/Desktop',
        '~/Pictures',
        '~/Projects',
        '~/localtesting',
        '~/code',
        '~/mac-studio-services',
    ]
}

if sys == 'Darwin':
    # Time Machine
    tm = {'configured': False, 'destinations': []}
    di = run('tmutil destinationinfo 2>/dev/null', timeout=8)
    if di and 'No destinations' not in di:
        dest = {}
        for line in di.split('\n'):
            s = line.strip()
            # Records are separated by a blank line OR a ==== rule; a repeated
            # Name: also begins a new record (belt-and-suspenders).
            if not s or set(s) == {'='}:
                if dest:
                    tm['destinations'].append(dest); dest = {}
                continue
            if ':' in s:
                k, v = s.split(':', 1)
                k = k.strip().lower(); v = v.strip()
                if k == 'name' and 'name' in dest:
                    tm['destinations'].append(dest); dest = {}
                if k == 'name': dest['name'] = v
                elif k == 'kind': dest['kind'] = v
        if dest: tm['destinations'].append(dest)
        tm['configured'] = len(tm['destinations']) > 0
    latest = run('tmutil latestbackup 2>/dev/null', timeout=8)
    if latest:
        tm['latest_backup'] = latest
        m = re.search(r'(\d{4}-\d{2}-\d{2}-\d{6})', latest)
        if m:
            try:
                ts = time.mktime(time.strptime(m.group(1), '%Y-%m-%d-%H%M%S'))
                tm['latest_backup_age_hours'] = age_hours(ts)
            except Exception:
                pass
    result['time_machine'] = tm

    # iCloud Drive — enabled + coverage only; currency NOT verifiable via CLI.
    # Desktop & Documents sync presents two ways: ~/Desktop may resolve into
    # Mobile Documents, OR (more common) it stays a normal dir while CloudDocs
    # holds the Desktop/Documents copies. Check both; require BOTH folders in
    # CloudDocs to avoid a manually-created iCloud "Desktop" false positive.
    if include_protected:
        icloud_root = os.path.expanduser('~/Library/Mobile Documents/com~apple~CloudDocs')
        desk = os.path.realpath(os.path.expanduser('~/Desktop'))
        docs = os.path.realpath(os.path.expanduser('~/Documents'))
        dd_synced = (('Mobile Documents' in desk) or ('Mobile Documents' in docs) or
                     (os.path.exists(os.path.join(icloud_root, 'Desktop')) and
                      os.path.exists(os.path.join(icloud_root, 'Documents'))))
        result['icloud_drive'] = {
            'enabled': os.path.isdir(icloud_root),
            'desktop_documents_synced': dd_synced,
            'currency_verified': False,
        }
    else:
        result['icloud_drive'] = {
            'collection_status': 'skipped',
            'reason': 'protected macOS location; use --include-protected for a one-off deep audit',
        }

    # FileVault personal recovery key escrow — needs root; report unknown if so.
    hprk = run('fdesetup haspersonalrecoverykey 2>/dev/null')
    if hprk in ('true', 'false'):
        result['filevault_personal_recovery_key'] = (hprk == 'true')
    else:
        result['filevault_personal_recovery_key'] = None
        result['filevault_recovery_key_note'] = 'requires root to determine'

    commercial = []
    for app in ['Backblaze', 'Arq', 'Carbon Copy Cloner', 'SuperDuper!']:
        if os.path.isdir('/Applications/%s.app' % app):
            commercial.append({'app': app, 'present': True})
    if commercial:
        result['commercial'] = commercial
else:
    # Linux: filesystem snapshots (LUKS disk encryption already in `security`).
    snaps = {}
    zfs = run('zfs list -t snapshot -H -o name 2>/dev/null')
    if zfs:
        snaps['zfs_snapshot_count'] = len([l for l in zfs.split('\n') if l.strip()])
    btrfs = run('btrfs subvolume list -s / 2>/dev/null')
    if btrfs:
        snaps['btrfs_snapshot_count'] = len([l for l in btrfs.split('\n') if l.strip()])
    if snaps:
        result['filesystem_snapshots'] = snaps

# Cloud-sync clients (presence + coverage only; currency NOT verified).
# macOS File Provider uses ONE shared ~/Library/CloudStorage container, so match
# PROVIDER-SPECIFIC subfolders (GoogleDrive-*, OneDrive-*) rather than the
# container itself, which any provider can create.
cloud_sync = []
cs = os.path.expanduser('~/Library/CloudStorage')
for provider, proc, app_name, binary, patterns in [
    ('Dropbox', 'Dropbox', 'Dropbox', 'dropbox', ['~/Dropbox', cs + '/Dropbox*']),
    ('Google Drive', 'Google Drive', 'Google Drive', None, [cs + '/GoogleDrive-*']),
    ('OneDrive', 'OneDrive', 'OneDrive', 'onedrive', ['~/OneDrive', cs + '/OneDrive-*']),
]:
    running = bool(run('pgrep -if "%s" 2>/dev/null' % proc))
    installed = os.path.isdir('/Applications/%s.app' % app_name) or bool(binary and shutil.which(binary))
    root = None
    if include_protected:
        for pat in patterns:
            matches = glob.glob(os.path.expanduser(pat))
            if matches:
                root = matches[0].replace(home, '~'); break
    if running or installed or root:
        cloud_sync.append({'provider': provider, 'running': running, 'installed': installed,
                           'root': root, 'root_exists': (root is not None) if include_protected else None,
                           'root_collection_status': 'collected' if include_protected else 'skipped',
                           'currency_verified': False})
if cloud_sync:
    result['cloud_sync'] = cloud_sync

# Programmatic backup tools (restic/borg/kopia/rclone). Snapshot age only when a
# password is already in the environment (never prompt / never read secrets).
prog = []
for tool in ['restic', 'borg', 'kopia', 'rclone']:
    if not shutil.which(tool):
        continue
    entry = {'tool': tool, 'present': True}
    if tool == 'restic':
        repo = os.environ.get('RESTIC_REPOSITORY')
        entry['repo_configured'] = bool(repo)
        if repo and (os.environ.get('RESTIC_PASSWORD') or os.environ.get('RESTIC_PASSWORD_FILE')):
            snap = run('restic snapshots --latest 1 --json 2>/dev/null', timeout=10)
            try:
                arr = json.loads(snap)
                if arr:
                    entry['latest_snapshot_time'] = arr[-1].get('time')
            except Exception:
                pass
        elif repo:
            entry['note'] = 'repo configured but no password in env; snapshot age unavailable'
    prog.append(entry)

# rh7-restic (modules/darwin/restic-backup.nix): the scheduled job records each
# run in a status file, so its snapshot age is known without a password in the
# environment. It REPLACES the env-based restic entry; `paths` scopes what it
# covers (the config service credits only policy paths at or under them).
# Missing, unreadable or foreign-schema file -> the detection above stands.
# Only while the job still exists (its LaunchAgent or the wrapper): disabling
# the module leaves the status file behind, and stale state must not keep
# reporting coverage.
try:
    restic_job = (os.path.exists(os.path.join(home, 'Library/LaunchAgents/org.rh7.restic-backup.plist'))
                  or bool(shutil.which('rh7-restic-backup')))
    with open(os.path.join(home, '.local/state/rh7-restic/status.json')) as f:
        st = json.load(f)
    if restic_job and isinstance(st, dict) and st.get('schema') == 1:
        paths = st.get('paths')
        prog = [e for e in prog if e.get('tool') != 'restic']
        prog.append({
            'tool': 'restic',
            'present': True,
            'repo_configured': st.get('configured') is True,
            'latest_snapshot_time': st.get('last_snapshot_time'),
            'paths': [p for p in paths if isinstance(p, str)] if isinstance(paths, list) else [],
            'source': 'rh7-restic',
            'last_result': st.get('last_result'),
        })
except Exception:
    pass
if prog:
    result['programmatic'] = prog

print(json.dumps(result))
PYEOF
}

# Uncommitted / unpushed git work (rh-device-management#78). Scans known dev
# roots (each root + its direct children, depth 1; prunes dotdirs/node_modules)
# and reports per-repo dirty/ahead/no-remote COUNTS only — never diffs/contents.
collect_git_repos() {
  python3 - <<'PYEOF' 2>/dev/null || echo '{}'
import json, os, subprocess, time

def git(repo, args, timeout=5):
    try:
        r = subprocess.run(['git', '-C', repo] + args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except Exception:
        return 1, ''

home = os.path.expanduser('~')
roots = [os.path.join(home, d) for d in
         ['localtesting', 'dotfiles', 'rh-device-management', 'mac-studio-services',
          'Projects', 'code', 'src', 'dev']]

def is_repo(p):
    # `.git` is a DIR for a normal repo but a FILE for a worktree/submodule, so
    # use exists() (not isdir) — else those are silently dropped (#78). Checking
    # at the exact path (vs `rev-parse` which walks up) avoids misattributing a
    # plain subdir of some ancestor repo.
    return os.path.exists(os.path.join(p, '.git'))

candidates = []
for root in roots:
    if not os.path.isdir(root):
        continue
    if is_repo(root):
        candidates.append(root)
    # Always also scan direct children: a root can be a repo AND contain child
    # repos/submodules (depth-1), so this is NOT an else-branch (#78).
    try:
        for name in sorted(os.listdir(root)):
            if name.startswith('.') or name == 'node_modules':
                continue
            child = os.path.join(root, name)
            if os.path.isdir(child) and is_repo(child):
                candidates.append(child)
    except Exception:
        pass

now = time.time()
repos = []
seen = set()
for repo in candidates:
    rp = repo.replace(home, '~')
    if rp in seen:
        continue
    seen.add(rp)
    info = {'path': rp}
    rc, branch = git(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])
    info['branch'] = branch if rc == 0 else None
    rc, porc = git(repo, ['status', '--porcelain'])
    info['dirty'] = len([l for l in porc.split('\n') if l.strip()]) if (rc == 0 and porc) else 0
    rc, remotes = git(repo, ['remote'])
    info['has_remote'] = bool(remotes.strip()) if rc == 0 else False
    # Upstream of the CURRENT branch + how far ahead (informational).
    rc, up = git(repo, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'])
    if rc == 0 and up:
        info['upstream'] = up
        rc2, cnt = git(repo, ['rev-list', '--count', '@{u}..HEAD'])
        info['ahead'] = int(cnt) if (rc2 == 0 and cnt.isdigit()) else 0
    else:
        info['upstream'] = None
        info['no_upstream'] = True
        info['ahead'] = 0
    # Comprehensive unpushed signal: commits reachable from ANY local branch tip
    # that are on NO remote-tracking ref. Catches unpushed work on a
    # non-checked-out / no-upstream branch, not only the current one (#78).
    if info['has_remote']:
        rc3, cnt3 = git(repo, ['rev-list', '--count', '--branches', '--not', '--remotes'])
        info['unpushed'] = int(cnt3) if (rc3 == 0 and cnt3.isdigit()) else 0
    else:
        info['unpushed'] = None  # no remote -> nothing replicated (flagged via has_remote)
    rc, ct = git(repo, ['log', '-1', '--format=%ct'])
    if rc == 0 and ct.isdigit():
        info['last_commit_age_days'] = round((now - float(ct)) / 86400.0, 1)
    info['at_risk'] = (info['dirty'] > 0) or (not info['has_remote']) or bool(info['unpushed'])
    repos.append(info)

result = {
    'scanned_roots': [r.replace(home, '~') for r in roots if os.path.isdir(r)],
    'repos': repos,
    'repo_count': len(repos),
    'at_risk_count': len([r for r in repos if r['at_risk']]),
}
print(json.dumps(result))
PYEOF
}

# Data inventory (rh-device-management fleet data view): what important data
# this account holds that nothing replicates, for a per-item owner decision
# (back up / ignore / delete later). Contract: top-level `data_inventory`,
# schema 1 — items (path, category, size, files, newest mtime, coverage,
# status) + the 20 largest files. Folder/file NAMES and sizes only, never
# contents.
#
# Privacy: without Full Disk Access (probed via TCC.db, which never prompts)
# the macOS-protected folders are not opened — they are reported
# `not-inspected` (Photos: `unprotected` unless iCloud Photos is on). Granting
# FDA to /usr/local/libexec/rh7-fleet-launcher (modules/darwin/fleet-launcher.nix)
# unlocks them for the scheduled run.
#
# Cost: one wall-clock budget (AUDIT_DATA_BUDGET, 90s) with a du cap per item;
# sizes are cached in ~/.local/state/rh7-audit/data-inventory-cache.json and
# reused for a week unless the folder's mtime changed, so a daily run is
# seconds once warm. The cache is the one file this collector writes.
# Classification rules: the SHARED DATA CLASSIFICATION block above.
collect_data_inventory() {
  DATA_CLASS_RULES="$DATA_CLASS_RULES" WALLET_APPS="$WALLET_APPS" WALLET_EXTENSIONS="$WALLET_EXTENSIONS" \
  CHROMIUM_BROWSERS="$CHROMIUM_BROWSERS" GIT_REPOS_JSON="${GIT_REPOS_JSON:-}" \
    python3 - <<'PYEOF' 2>/dev/null || echo '{"schema": 1, "error": "collector-failed", "items": [], "largest_files": []}'
import calendar, fnmatch, json, pwd, os, platform, plistlib, re, shutil, stat, subprocess, sys, time

T0 = time.monotonic()
NOW = time.time()

def knob(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)

BUDGET = knob('AUDIT_DATA_BUDGET', 90)            # whole-section wall clock
DU_TIMEOUT = knob('AUDIT_DATA_DU_TIMEOUT', 20)    # one du
WALK_TIMEOUT = knob('AUDIT_DATA_WALK_TIMEOUT', 5)  # file count / newest mtime walk
LARGEST_TIMEOUT = knob('AUDIT_DATA_LARGEST_TIMEOUT', 45)
LARGEST_MIN_MB = int(knob('AUDIT_DATA_LARGEST_MIN_MB', 500))
REUSE_SECS = 7 * 86400   # a cached measurement is reused for a week ...
FRESH_HOURS = 48         # restic / Time Machine count only when this recent
MB = 1024 * 1024
APPDATA_MIN = 100 * MB   # app-data folders smaller than this are not items
SMALL = 1 * MB           # home folders smaller than this are noise ...
DEADLINE = T0 + BUDGET

HOME = os.path.realpath(os.path.expanduser('~'))
SYSTEM = os.environ.get('AUDIT_DATA_PLATFORM') or platform.system()
DARWIN = SYSTEM == 'Darwin'
INCLUDE_PROTECTED = os.environ.get('AUDIT_INCLUDE_PROTECTED') == '1'
STATE_DIR = os.environ.get('AUDIT_DATA_STATE_DIR') or os.path.join(HOME, '.local/state/rh7-audit')
CACHE_FILE = os.path.join(STATE_DIR, 'data-inventory-cache.json')
LIB = os.path.join(HOME, 'Library')

budget_exhausted = False

def tilde(p):
    if p == HOME:
        return '~'
    return '~/' + p[len(HOME) + 1:] if p.startswith(HOME + '/') else p

def iso(epoch):
    try:
        return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(float(epoch)))
    except Exception:
        return None

def under(p, root):
    return p == root or p.startswith(root.rstrip('/') + '/')

def remaining():
    return DEADLINE - time.monotonic()

# ── shared classification (DATA_CLASS_RULES, see the shared block) ──────────
RULES = []
for line in os.environ.get('DATA_CLASS_RULES', '').split('\n'):
    f = line.split('|')
    if len(f) >= 6:
        RULES.append((f[0], f[1], f[2], f[3], f[4], '|'.join(f[5:])))

def rule(scope, name):
    for s, pat, kind, cat, st, note in RULES:
        if s == scope and fnmatch.fnmatchcase(name, pat):
            return {'kind': kind, 'category': cat, 'status': st, 'note': note or None}
    return None

CLOUD_ROOTS = []   # (abs path, coverage token)
try:
    for name in os.listdir(HOME):
        r = rule('home', name)
        if r and r['status'] == 'cloud':
            CLOUD_ROOTS.append((os.path.join(HOME, name), r['category']))
except Exception:
    pass
CLOUD_ROOTS.append((os.path.join(LIB, 'Mobile Documents'), 'icloud'))
CLOUD_ROOTS.append((os.path.join(LIB, 'CloudStorage'), 'cloud-storage'))

# ── access: Full Disk Access and the protected folders ──────────────────────
# TCC.db is readable only with Full Disk Access, and a denied FDA check never
# raises a prompt — unlike opening Desktop/Documents/Downloads, which can. So
# without FDA the protected folders are NOT touched (stat at most) unless the
# operator opted in with --include-protected for a one-off deep audit.
def fda_granted():
    if not DARWIN:
        return True
    try:
        with open(os.path.join(LIB, 'Application Support/com.apple.TCC/TCC.db'), 'rb') as f:
            f.read(1)
        return True
    except Exception:
        return False

FDA = fda_granted()
PROTECTED_HOME = {'Desktop', 'Documents', 'Downloads', 'Pictures', 'Movies', 'Music'}
PROTECTED_LIB = [os.path.join(LIB, n) for n in ('Messages', 'Mail', 'Containers', 'Group Containers', 'Safari')]
MAY_TOUCH_PROTECTED = FDA or INCLUDE_PROTECTED or not DARWIN

def is_protected(p):
    if not DARWIN:
        return False
    for n in PROTECTED_HOME:
        if under(p, os.path.join(HOME, n)):
            return True
    if under(p, os.path.join(HOME, '.Trash')):
        return True
    return any(under(p, q) for q in PROTECTED_LIB)

touched_ok, touched_denied = [], []

def accessible(p):
    """True = may be measured. Protected paths are probed only when allowed."""
    if is_protected(p) and not MAY_TOUCH_PROTECTED:
        return False
    try:
        if os.path.isdir(p):
            os.listdir(p)
        else:
            with open(p, 'rb'):
                pass
        if is_protected(p):
            touched_ok.append(p)
        return True
    except Exception:
        if is_protected(p):
            touched_denied.append(p)
        return False

# ── iCloud / cloud account state (preferences only: never protected) ───────
def plist(path):
    try:
        with open(path, 'rb') as f:
            return plistlib.load(f)
    except Exception:
        return {}

icloud_services = {}
if DARWIN:
    accts = plist(os.path.join(LIB, 'Preferences/MobileMeAccounts.plist')).get('Accounts') or []
    if accts and isinstance(accts[0], dict):
        for s in accts[0].get('Services') or []:
            if isinstance(s, dict) and s.get('Name'):
                icloud_services[s['Name']] = {'enabled': s.get('Enabled') is True, 'status': s.get('status')}
finder = plist(os.path.join(LIB, 'Preferences/com.apple.finder.plist')) if DARWIN else {}
dd_both = icloud_services.get('CLOUDDESKTOP', {}).get('status') == 'active'
DD_SYNCED = {
    'Desktop': dd_both or finder.get('FXICloudDriveDesktop') in (1, True),
    'Documents': dd_both or finder.get('FXICloudDriveDocuments') in (1, True),
}
icloud_photos = any(icloud_services.get(n, {}).get('enabled') for n in ('PHOTO_STREAM', 'PHOTOS', 'CLOUDPHOTOS'))
photos_prefs = plist(os.path.join(LIB, 'Preferences/com.apple.photos.shareddefaults.plist')) if DARWIN else {}
icloud_photos_ever = bool(photos_prefs.get('iCloudPhotoLibraryHasBeenEnabledAccountIdentifiers'))

# ── backups that can cover a path ───────────────────────────────────────────
def run(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=max(1, timeout))
        return r.returncode, r.stdout
    except Exception:
        return 1, ''

def parse_iso(s):
    try:
        return calendar.timegm(time.strptime(s[:19], '%Y-%m-%dT%H:%M:%S')) if s else None
    except Exception:
        return None

restic_paths = []   # absolute roots of the latest fresh rh7-restic snapshot
restic_snap = None  # its time (epoch)
try:
    job = (os.path.exists(os.path.join(LIB, 'LaunchAgents/org.rh7.restic-backup.plist'))
           or bool(shutil.which('rh7-restic-backup')))
    with open(os.path.join(HOME, '.local/state/rh7-restic/status.json')) as f:
        st = json.load(f)
    snap = parse_iso(st.get('last_snapshot_time') or '')
    if job and st.get('schema') == 1 and snap and NOW - snap < FRESH_HOURS * 3600:
        restic_snap = snap
        for p in st.get('paths') or []:
            if isinstance(p, str):
                a = HOME + p[1:] if p == '~' or p.startswith('~/') else p
                if a.startswith('/'):
                    restic_paths.append(a.rstrip('/') or '/')
except Exception:
    pass

tm_fresh = False
tm_snap = None   # time of the latest Time Machine backup (epoch)
if DARWIN and shutil.which('tmutil'):
    rc, di = run(['tmutil', 'destinationinfo'])
    if rc == 0 and di.strip() and 'No destinations' not in di:
        rc, latest = run(['tmutil', 'latestbackup'])
        m = re.search(r'(\d{4}-\d{2}-\d{2}-\d{6})', latest or '')
        if m:
            try:
                tm_snap = time.mktime(time.strptime(m.group(1), '%Y-%m-%d-%H%M%S'))
                tm_fresh = NOW - tm_snap < FRESH_HOURS * 3600
            except Exception:
                pass

try:
    git = json.loads(os.environ.get('GIT_REPOS_JSON') or '{}')
except Exception:
    git = {}
repos = {}
for r in git.get('repos') or []:
    if isinstance(r, dict) and isinstance(r.get('path'), str):
        p = r['path']
        repos[HOME + p[1:] if p.startswith('~/') else p] = r

# A backup can only hold what existed when it ran: a folder created after the
# latest restic snapshot / Time Machine backup is in neither, however fresh the
# backup and whatever its include rules say. Birth time where the platform has
# one (macOS), else ctime — later than creation, so it errs toward NOT covered.
def born_before(p, epoch):
    if epoch is None:
        return False
    try:
        st = os.stat(p)
    except Exception:
        return False
    return (getattr(st, 'st_birthtime', None) or st.st_ctime) < epoch

def coverage_of(p, name=None):
    cov = []
    for root, token in CLOUD_ROOTS:
        if under(p, root) and token not in cov:
            cov.append(token)
    for n in ('Desktop', 'Documents'):
        if DD_SYNCED[n] and under(p, os.path.join(HOME, n)) and 'icloud' not in cov:
            cov.append('icloud')
    r = repos.get(p)
    if r is not None and not r.get('at_risk'):
        cov.append('git-remote')
    if any(under(p, rp) for rp in restic_paths) and born_before(p, restic_snap):
        cov.append('restic')
    return cov

# ── measuring: du for size, a bounded walk for files/newest, weekly cache ──
try:
    with open(CACHE_FILE) as f:
        CACHE = json.load(f)
    if not isinstance(CACHE, dict) or CACHE.get('schema') != 1:
        raise ValueError
except Exception:
    CACHE = {'schema': 1, 'items': {}, 'largest': None}
CACHE.setdefault('items', {})
cache_dirty = False

def dir_mtime(p):
    try:
        return os.stat(p).st_mtime
    except Exception:
        return None

def du_bytes(p, timeout):
    """(bytes|None, state): ok, partial (some subtree unreadable), timeout, error."""
    try:
        r = subprocess.run(['du', '-skx', p], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, 'timeout'
    except Exception:
        return None, 'error'
    lines = [l for l in r.stdout.strip().split('\n') if l.strip()]
    kb = lines[-1].split('\t')[0].strip() if lines else ''
    if not kb.isdigit():
        return None, 'error'
    return int(kb) * 1024, ('partial' if r.returncode != 0 else 'ok')

def walk_stats(p, timeout):
    """(files, newest mtime) or (None, None) when the walk did not finish."""
    end = time.monotonic() + timeout
    files, newest, n = 0, None, 0
    stack = [p]
    try:
        dev = os.lstat(p).st_dev
    except Exception:
        return None, None
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except Exception:
            continue
        with it:
            for e in it:
                n += 1
                if n % 2000 == 0 and time.monotonic() > end:
                    return None, None
                try:
                    s = e.stat(follow_symlinks=False)
                except Exception:
                    continue
                if stat.S_ISDIR(s.st_mode):
                    if s.st_dev == dev:
                        stack.append(e.path)
                elif stat.S_ISREG(s.st_mode):
                    files += 1
                    if newest is None or s.st_mtime > newest:
                        newest = s.st_mtime
    if os.path.isfile(p):
        try:
            s = os.stat(p)
            return 1, s.st_mtime
        except Exception:
            return None, None
    return files, newest

def measure(p):
    """Cached-or-fresh measurement of one path, within the section budget."""
    global budget_exhausted, cache_dirty
    c = CACHE['items'].get(p)
    mt = dir_mtime(p)
    if c and NOW - c.get('measured_at', 0) < REUSE_SECS and c.get('dir_mtime') == mt:
        return c, None
    left = remaining()
    if left < 1:
        budget_exhausted = True
        if c and c.get('size_bytes') is not None:
            return c, 'size from %s (time budget exhausted)' % (iso(c.get('measured_at')) or '?')[:10]
        return None, 'not sized: time budget exhausted'
    size, state = du_bytes(p, min(DU_TIMEOUT, left))
    if state == 'timeout':
        budget_exhausted = True
        # Remembered, so a folder too big for the cap is not retried daily.
        CACHE['items'][p] = {'size_bytes': None, 'timed_out': True, 'measured_at': NOW, 'dir_mtime': mt}
        cache_dirty = True
        return None, 'not sized: du exceeded %ds (retried weekly)' % int(DU_TIMEOUT)
    if state == 'error':
        return None, 'not sized: du failed'
    files, newest = walk_stats(p, max(0.5, min(WALK_TIMEOUT, remaining())))
    c = {'size_bytes': size, 'files': files, 'newest_mtime': newest, 'partial': state == 'partial',
         'measured_at': NOW, 'dir_mtime': mt}
    CACHE['items'][p] = c
    cache_dirty = True
    return c, None

# ── candidates ──────────────────────────────────────────────────────────────
cands = {}   # abs path -> dict(category, status(rule), note, kind, protected_item)

def add(p, category, status='unprotected', note=None, kind=None, always=False, min_size=0):
    if p in cands:
        return
    cands[p] = {'category': category, 'rule_status': status, 'notes': [note] if note else [],
                'kind': kind, 'always': always, 'min_size': min_size}

# 1. top-level home folders
try:
    names = sorted(os.listdir(HOME))
except Exception:
    names = []
for name in names:
    p = os.path.join(HOME, name)
    if os.path.islink(p) or not os.path.isdir(p):
        continue
    r = rule('home', name) or {'kind': 'other', 'category': 'user-data', 'status': 'unprotected', 'note': None}
    if r['status'] in ('skip', 'cloud'):
        continue
    # Protected folders stay listed even unmeasured: "not-inspected" is the point.
    keep = r['kind'] in ('secret', 'dd') or name == 'Downloads' or (DARWIN and name in PROTECTED_HOME)
    add(p, r['category'], r['status'], r['note'], r['kind'], always=keep, min_size=0 if keep else SMALL)

# 2. Photos libraries (owner rule: always reported)
pictures = os.path.join(HOME, 'Pictures')
photo_libs = []
photo_default_assumed = False
if DARWIN:
    if accessible(pictures):
        for base in [pictures] + [e.path for e in os.scandir(pictures) if e.is_dir() and not e.name.endswith('.photoslibrary')]:
            try:
                photo_libs += [e.path for e in os.scandir(base) if e.name.endswith('.photoslibrary') and e.is_dir()]
            except Exception:
                pass
    # Evidence from preferences only: even a stat inside ~/Library/Containers
    # can raise macOS's "access data from other apps" prompt.
    elif photos_prefs or icloud_photos or os.path.exists(os.path.join(LIB, 'Preferences/com.apple.Photos.plist')):
        photo_libs.append(os.path.join(pictures, 'Photos Library.photoslibrary'))
        photo_default_assumed = True
for lib in sorted(set(photo_libs)):
    add(lib, 'photos', always=True)

# 3. Messages, Mail
if DARWIN:
    for sub, cat, note in [
        ('Messages', 'messages', None),
        ('Mail', 'mail', 'IMAP/Exchange mail re-downloads; local "On My Mac" mailboxes do not'),
    ]:
        p = os.path.join(LIB, sub)
        if os.path.isdir(p):
            add(p, cat, note=note, always=True)

# 4. wallets (size only; never opened)
for line in (os.environ.get('WALLET_APPS') or '').split('\n'):
    f = line.split('|')
    if len(f) < 4:
        continue
    name, keys, dirs = f[0], f[1], f[3]
    for d in dirs.split(';'):
        p = os.path.join(HOME, d)
        if d and os.path.isdir(p):
            if keys == 'hardware':
                add(p, 'wallet', 'reinstallable', '%s: keys live on the hardware device; this is app data' % name, always=True)
            else:
                add(p, 'wallet', 'unprotected', '%s: may hold encrypted private keys — confirm the seed phrase is stored offline' % name, always=True)
exts = [l.split('|', 1) for l in (os.environ.get('WALLET_EXTENSIONS') or '').split('\n') if '|' in l]
for line in (os.environ.get('CHROMIUM_BROWSERS') or '').split('\n'):
    if ':' not in line:
        continue
    browser, rel = line.split(':', 1)
    root = os.path.join(LIB, 'Application Support', rel)
    if not os.path.isdir(root):
        continue
    try:
        profiles = [e.name for e in os.scandir(root) if e.is_dir() and (e.name == 'Default' or e.name.startswith('Profile '))]
    except Exception:
        profiles = []
    for prof in sorted(profiles):
        for ext_id, ext_name in exts:
            p = os.path.join(root, prof, 'Local Extension Settings', ext_id)
            if os.path.isdir(p):
                add(p, 'wallet', 'unprotected', '%s extension (%s, %s): encrypted vault — the seed phrase is the backup'
                    % (ext_name, browser, prof), always=True)

# 5. app data: Application Support (non-protected), Containers + Group Containers (protected)
appdata_roots = [os.path.join(LIB, 'Application Support')]
if DARWIN:
    appdata_roots += [os.path.join(LIB, 'Containers'), os.path.join(LIB, 'Group Containers')]
for root in appdata_roots:
    if not os.path.isdir(root):
        continue
    if is_protected(root) and not accessible(root):
        add(root, 'app-data', note='sandboxed app data (listed per app once Full Disk Access is granted)', always=True)
        continue
    try:
        entries = sorted(e.path for e in os.scandir(root) if e.is_dir(follow_symlinks=False))
    except Exception:
        continue
    for p in entries:
        name = os.path.basename(p)
        r = rule('appdata', name)
        if r:
            add(p, r['category'], r['status'], r['note'], always=r['status'] == 'unprotected',
                min_size=0 if r['status'] == 'unprotected' else APPDATA_MIN)
        else:
            add(p, 'app-data', note='app data a reinstall does not restore — confirm it syncs or is disposable',
                min_size=APPDATA_MIN)

# 6. git repos at risk (from the git_repos section)
for p, r in sorted(repos.items()):
    if r.get('at_risk'):
        why = []
        if r.get('dirty'):
            why.append('%d uncommitted change(s)' % r['dirty'])
        if not r.get('has_remote'):
            why.append('no remote')
        if r.get('unpushed'):
            why.append('%d unpushed commit(s)' % r['unpushed'])
        if p in cands:   # a top-level folder that is itself a repo
            cands[p]['category'] = 'repo'
            cands[p]['always'] = True
            cands[p]['notes'].append('git: ' + ', '.join(why or ['at risk']))
        else:
            add(p, 'repo', note='git: ' + ', '.join(why or ['at risk']), always=True)

# Home folders that hold repos: say so (untracked/ignored files are not in git).
for p, c in cands.items():
    held = [rp for rp in repos if rp != p and under(rp, p)]
    if held:
        risky = len([rp for rp in held if repos[rp].get('at_risk')])
        c['notes'].append('holds %d git repo(s), %d at risk' % (len(held), risky))

# ── measure (unmeasured first, so a short budget fills in over a few days) ──
# The largest-files list is cached per access scope: names found WITH access
# to protected folders must never be reported once that access is gone.
LARGEST_SCOPE = 'all' if MAY_TOUCH_PROTECTED else 'unprotected'
largest_cached = CACHE.get('largest') if isinstance(CACHE.get('largest'), dict) else None
if largest_cached and largest_cached.get('scope') != LARGEST_SCOPE:
    largest_cached = None
largest_fresh = bool(largest_cached and NOW - largest_cached.get('measured_at', 0) < REUSE_SECS)
if not largest_fresh:
    DEADLINE = T0 + max(BUDGET * 0.5, BUDGET - LARGEST_TIMEOUT)   # leave room for the find
order = sorted(cands, key=lambda p: (p in CACHE['items'], CACHE['items'].get(p, {}).get('measured_at', 0), p))
results = {}
for p in order:
    c = cands[p]
    inspectable = accessible(p) if is_protected(p) else os.access(p, os.R_OK | os.X_OK) or os.path.isfile(p)
    if not inspectable:
        results[p] = (None, 'denied' if (MAY_TOUCH_PROTECTED or not is_protected(p)) else 'not-allowed')
        continue
    results[p] = measure(p)
DEADLINE = T0 + BUDGET

# ── items ───────────────────────────────────────────────────────────────────
lib_bytes = 0
lib_unknown = False
for lib in photo_libs:
    m = results.get(lib, (None, None))[0] if isinstance(results.get(lib, (None, None))[0], dict) else None
    if m and m.get('size_bytes') is not None:
        lib_bytes += m['size_bytes']
    else:
        lib_unknown = True

items = []
for p, c in cands.items():
    m, extra = results.get(p, (None, None))
    inspected = isinstance(m, dict) or extra not in ('denied', 'not-allowed')
    notes = list(c['notes'])
    size = files = newest = None
    if isinstance(m, dict):
        size, files, newest = m.get('size_bytes'), m.get('files'), m.get('newest_mtime')
        if m.get('partial'):
            notes.append('partly unreadable: size is a lower bound')
        if m.get('timed_out'):
            notes.append('not sized: du exceeded its cap (retried weekly)')
    elif extra == 'not-allowed':
        notes.append('not inspected: no Full Disk Access')
    elif extra == 'denied':
        notes.append('not inspected: access denied')
    elif extra:
        notes.append(extra)
    if isinstance(m, dict) and extra:
        notes.append(extra)
    if p == pictures and size is not None and photo_libs:
        size = max(0, size - lib_bytes)
        notes.append('excludes Photos libraries' + (' (some unsized)' if lib_unknown else ''))
    if not c['always'] and (not inspected or (size is not None and size < c['min_size'])):
        continue   # too small to matter, or a size-gated candidate that could not be judged
    cov = coverage_of(p)
    if c['category'] == 'photos':
        if icloud_photos and 'icloud' not in cov:
            cov.append('icloud')
            notes.append('iCloud Photos on (best effort); whether originals are kept on this Mac is not detectable')
        elif not icloud_photos:
            notes.append('iCloud Photos not confirmed' + (' (was enabled at some point)' if icloud_photos_ever else ''))
        if photo_default_assumed:
            notes.append('default library location assumed, existence not verified')
    if c['rule_status'] == 'reinstallable':
        status = 'reinstallable'
    elif cov:
        status = 'covered'
    elif not inspected and c['category'] != 'photos':
        status = 'not-inspected'
    else:
        status = 'unprotected'
    items.append({
        '_abs': p, '_inspected': inspected,
        'path': tilde(p),
        'category': c['category'],
        'size_bytes': size if inspected else None,
        'files': files if inspected else None,
        'newest_mtime': iso(newest) if (inspected and newest) else None,
        'coverage': cov,
        'status': status,
        'note': '; '.join(n for n in notes if n) or None,
    })

# Time Machine: one batched `tmutil isexcluded`, only for paths that may be
# stat'ed, and only when the latest backup is fresh. Best effort.
if tm_fresh:
    tm_paths = [i['_abs'] for i in items if i['_inspected']]
    if tm_paths and remaining() > 2:
        rc, out = run(['tmutil', 'isexcluded'] + tm_paths, timeout=min(15, remaining()))
        included = set()
        for line in out.split('\n'):
            mm = re.match(r'^\[Included\]\s+(.*\S)\s*$', line.strip())
            if mm:
                included.add(mm.group(1))
        for i in items:
            if i['_abs'] in included and born_before(i['_abs'], tm_snap):
                i['coverage'].append('time-machine')
                if i['status'] in ('unprotected',):
                    i['status'] = 'covered'
for i in items:
    del i['_abs'], i['_inspected']

# ── largest files (top 20 over the threshold) ───────────────────────────────
def find_largest(timeout):
    prune = [os.path.join(LIB, 'Caches'), os.path.join(HOME, '.cache')] + [r for r, _ in CLOUD_ROOTS]
    roots = [HOME]
    if DARWIN and not MAY_TOUCH_PROTECTED:
        prune += [LIB, os.path.join(HOME, '.Trash')] + [os.path.join(HOME, n) for n in sorted(PROTECTED_HOME)]
        roots.append(os.path.join(LIB, 'Application Support'))
    expr = []
    for q in prune:
        expr += ['-path', q, '-o']
    expr += ['-name', '*.photoslibrary']
    out, timed_out = '', False
    for root in roots:
        if not os.path.isdir(root):
            continue
        left = min(timeout, remaining())
        if left < 2:
            timed_out = True
            break
        cmd = ['find', root, '-xdev', '('] + expr + [')', '-prune', '-o', '-type', 'f',
               '-size', '+%dM' % LARGEST_MIN_MB, '-print0']
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=left)
            out += r.stdout.decode('utf-8', 'replace')
        except subprocess.TimeoutExpired as e:
            timed_out = True
            out += (e.stdout or b'').decode('utf-8', 'replace')
        except Exception:
            pass
    rows = []
    for p in set(x for x in out.split('\0') if x):
        try:
            s = os.stat(p)
            rows.append({'path': tilde(p), 'size_bytes': s.st_size, 'mtime': iso(s.st_mtime)})
        except Exception:
            pass
    rows.sort(key=lambda r: (-r['size_bytes'], r['path']))
    return rows[:20], timed_out

if largest_fresh:
    largest = largest_cached.get('files') or []
else:
    largest, to = find_largest(LARGEST_TIMEOUT)
    if to:
        budget_exhausted = True
        if not largest and largest_cached:
            largest = largest_cached.get('files') or []
    else:
        CACHE['largest'] = {'measured_at': NOW, 'scope': LARGEST_SCOPE, 'files': largest}
        cache_dirty = True

# Belt and braces: whatever the source, no protected path leaves this Mac
# while this run may not look there.
if not MAY_TOUCH_PROTECTED:
    largest = [f for f in largest if not is_protected(HOME + f['path'][1:] if f['path'].startswith('~/') else f['path'])]

# ── cache write (atomic, 0600: it holds folder and file names) ──────────────
if cache_dirty:
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        tmp = CACHE_FILE + '.%d.tmp' % os.getpid()
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(CACHE, f)
        os.replace(tmp, CACHE_FILE)
    except Exception:
        pass

if not DARWIN or FDA:
    access = 'granted'
elif touched_ok:
    access = 'partial'
else:
    access = 'denied'

order_status = {'unprotected': 0, 'not-inspected': 1, 'covered': 2, 'reinstallable': 3}
items.sort(key=lambda i: (order_status.get(i['status'], 9), -(i['size_bytes'] or 0), i['path']))
print(json.dumps({
    'schema': 1,
    'collected_at': iso(NOW),
    'account': pwd.getpwuid(os.getuid()).pw_name,
    'protected_access': access,
    'budget_exhausted': budget_exhausted,
    'elapsed_seconds': round(time.monotonic() - T0, 1),
    'items': items,
    'largest_files': largest,
}))
PYEOF
}

# Secret inventory (rh-device-management#68). Normalized secret records for
# cross-device orphan detection (GROUP BY fingerprint server-side). Captures
# whole classes not previously inventoried: GPG secret keys, cloud/CLI cred
# files, .env/.envrc files, code-signing identities. METADATA ONLY — never key
# material or secret values (fingerprints, paths, mtimes, key counts). Keychain
# enumeration is intentionally omitted (it triggers an interactive unlock/TCC
# prompt — not headless-safe).
collect_secret_inventory() {
  python3 - <<'PYEOF' 2>/dev/null || echo '{"entries": [], "counts": {}, "total": 0}'
import os, json, subprocess, glob, time, platform, shutil, re

home = os.path.expanduser('~')
entries = []

def run(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ''

def mtime_iso(p):
    try:
        return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(os.path.getmtime(p)))
    except Exception:
        return None

# GPG secret keys — fingerprints only (never exported key material).
if shutil.which('gpg'):
    out = run('gpg --list-secret-keys --with-colons 2>/dev/null', timeout=8)
    for line in out.split('\n'):
        if line.startswith('fpr:'):
            cols = line.split(':')
            fpr = cols[9] if len(cols) > 9 else ''
            if fpr:
                entries.append({'category': 'gpg', 'type': 'gpg-secret-key', 'fingerprint': fpr,
                                'path': None, 'last_modified': None, 'encrypted': None, 'source': 'gpg'})

# Cloud / CLI credential files — names + mtime only, NEVER values.
for name, p in [
    ('aws', '~/.aws/credentials'), ('gcloud', '~/.config/gcloud/credentials.db'),
    ('gh', '~/.config/gh/hosts.yml'), ('docker', '~/.docker/config.json'),
    ('npm', '~/.npmrc'), ('pypi', '~/.pypirc'), ('kube', '~/.kube/config'),
    ('cloudflare', '~/.cloudflared/cert.pem'),
]:
    fp = os.path.expanduser(p)
    if os.path.isfile(fp):
        entries.append({'category': 'cloud_cred', 'type': name + '-cred', 'fingerprint': None,
                        'path': p, 'last_modified': mtime_iso(fp), 'encrypted': False, 'source': 'file'})

# .env / .envrc files under known roots — paths + key COUNT only (skip examples).
roots = [os.path.join(home, d) for d in
         ['localtesting', 'code', 'Projects', 'mac-studio-services', 'dotfiles',
          'rh-device-management', 'dev', 'src']]
seen = set()
for root in roots:
    if not os.path.isdir(root):
        continue
    for pat in ['.env', '.envrc', '*/.env', '*/.envrc', '*/*/.env', '*/*/.envrc']:
        for fp in glob.glob(os.path.join(root, pat)):
            if not os.path.isfile(fp) or 'node_modules' in fp or '/.git/' in fp:
                continue
            base = os.path.basename(fp)
            if '.example' in base or '.sample' in base or base.endswith('.dist'):
                continue
            rp = fp.replace(home, '~')
            if rp in seen:
                continue
            seen.add(rp)
            kc = 0
            try:
                with open(fp, 'r', errors='ignore') as f:
                    for l in f:
                        s = l.strip()
                        if s and not s.startswith('#') and '=' in s:
                            kc += 1
            except Exception:
                pass
            entries.append({'category': 'env', 'type': 'dotenv', 'fingerprint': None, 'path': rp,
                            'last_modified': mtime_iso(fp), 'encrypted': False, 'source': 'file', 'key_count': kc})

# Code-signing identities (macOS) — identity name + cert SHA-1, never private key.
if platform.system() == 'Darwin':
    out = run('security find-identity -v -p codesigning 2>/dev/null')
    for line in out.split('\n'):
        m = re.search(r'\)\s+([0-9A-Fa-f]{40})\s+"(.+)"', line.strip())
        if m:
            entries.append({'category': 'code_signing', 'type': 'codesigning-identity',
                            'fingerprint': m.group(1).upper(), 'name': m.group(2),
                            'path': None, 'last_modified': None, 'encrypted': None, 'source': 'keychain'})

counts = {}
for e in entries:
    counts[e['category']] = counts.get(e['category'], 0) + 1
print(json.dumps({'entries': entries, 'counts': counts, 'total': len(entries)}))
PYEOF
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

# Querying System Events causes an Automation permission dialog. Scheduled and
# standard audits intentionally skip it; launch agents below remain visible.
if os.environ.get('AUDIT_INCLUDE_PROTECTED') == '1':
    try:
        r = subprocess.run(['osascript', '-e', 'tell application \"System Events\" to get the name of every login item'],
                           capture_output=True, text=True, timeout=10)
        result['login_items'] = [i.strip() for i in r.stdout.strip().split(',') if i.strip()]
    except: result['login_items'] = []
else:
    result['login_items_collection'] = {'status': 'skipped', 'reason': 'avoids macOS Automation permission request'}

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
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# Wi-Fi names can require Location access on current macOS releases. They are
# useful only for an intentional deep inventory, not fleet health.
if os.environ.get('AUDIT_INCLUDE_PROTECTED') == '1':
    networks_raw = run('networksetup -listpreferredwirelessnetworks en0 2>/dev/null')
    if networks_raw:
        result['known_networks'] = [n.strip() for n in networks_raw.split('\n')[1:] if n.strip()]
    current = run('/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null')
    for line in current.split('\n'):
        if 'SSID' in line and 'BSSID' not in line:
            result['current_ssid'] = line.split(':',1)[1].strip()
            break
else:
    result['wifi_identity_collection'] = {'status': 'skipped', 'reason': 'avoids macOS Location permission request'}

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
  if [[ "$AUDIT_INCLUDE_PROTECTED" != "1" ]]; then
    echo '{"collection_status":"skipped","reason":"browser profiles are protected personal data","opt_in_flag":"--include-protected"}'
    return
  fi
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

# ── Fleet update daemon (rh-device-management fleet_update contract) ────────
# Reports the state of the unattended updater (modules/darwin/fleet-update.nix):
#   - plist absent                 -> {"enabled": false}
#   - plist present, state missing
#     or not a valid schema-1 file -> {"enabled": true, "error": "state-unreadable"}
#   - otherwise                    -> the state file, restricted to the contract
#                                     fields (nothing else is ever forwarded).
# Linux has no such daemon -> {"enabled": false}. Paths are parameters so the
# test suite can point them at fixtures.
collect_fleet_update() {
  local plist="${1:-/Library/LaunchDaemons/org.rh7.fleet-update.plist}"
  local state="${2:-/var/lib/rh7-fleet-update/state.json}"
  if [[ "$OS" != "Darwin" || ! -e "$plist" ]]; then
    echo '{"enabled": false}'
    return
  fi
  python3 - "$state" <<'PYEOF' 2>/dev/null || echo '{"enabled": true, "error": "state-unreadable"}'
import json, re, sys

UNREADABLE = {"enabled": True, "error": "state-unreadable"}
SHA = re.compile(r"^[0-9a-f]{40}$")
ISO = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
REFUSED = {"signature-invalid", "signer-key-expired", "not-fast-forward", "not-in-main"}
SKIPPED = {"on-battery", "lock-held", "rebuild-in-progress"}
FAILED = {"fetch-failed", "build-failed", "activation-failed", "brew-failed", "unknown"}
# result -> the reasons it may carry (None = reason must be null)
RESULT_REASONS = {"applied": {None}, "no-op": {None}, "skipped": SKIPPED,
                  "failed": FAILED, "refused": REFUSED}

KEYS = ("schema", "enabled", "channel", "last_run_at", "last_result", "reason",
        "target_commit", "applied_commit", "last_success_at", "generation",
        "consecutive_failures")

def valid(s):
    if not isinstance(s, dict) or any(k not in s for k in KEYS):
        return False
    if s["schema"] != 1 or s["enabled"] is not True:
        return False
    if s.get("channel") not in ("main", "fleet/stable"):
        return False
    if not (isinstance(s["last_run_at"], str) and ISO.match(s["last_run_at"])):
        return False
    if s["last_result"] not in RESULT_REASONS or s["reason"] not in RESULT_REASONS[s["last_result"]]:
        return False
    for k in ("target_commit", "applied_commit"):
        v = s.get(k)
        if v is not None and not (isinstance(v, str) and SHA.match(v)):
            return False
    if s["last_success_at"] is not None and not (isinstance(s["last_success_at"], str) and ISO.match(s["last_success_at"])):
        return False
    g = s.get("generation")
    if g is not None and (isinstance(g, bool) or not isinstance(g, int) or g < 0):
        return False
    f = s.get("consecutive_failures")
    if isinstance(f, bool) or not isinstance(f, int) or f < 0:
        return False
    return True

try:
    with open(sys.argv[1]) as fh:
        state = json.load(fh)
except Exception:
    state = None

if not valid(state):
    print(json.dumps(UNREADABLE))
else:
    print(json.dumps({k: state[k] for k in KEYS}))
PYEOF
}

collect_audit_scope() {
  if [[ "$AUDIT_INCLUDE_PROTECTED" == "1" || "$OS" != "Darwin" ]]; then
    echo '{"mode":"deep","protected_locations":true,"permission_note":"May request macOS access to personal/cloud folders, browser profiles, Location, and System Events."}'
  else
    echo '{"mode":"standard","protected_locations":false,"permission_note":"Does not request access to personal/cloud folders, browser profiles, Location, or System Events.","opt_in_flag":"--include-protected"}'
  fi
}

echo "Auditing $HOSTNAME ($OS/$ARCH)..." >&2
# git_repos is computed once: its own section AND data_inventory's repo items
# and git-remote coverage read it.
GIT_REPOS_JSON="$(collect_git_repos)"

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
---SECTION: audit_scope
$(collect_audit_scope)
---SECTION: system
$(collect_system)
---SECTION: homebrew
$(collect_homebrew)
---SECTION: virtualization_prerequisites
$(collect_virtualization_prerequisites)
---SECTION: mas_apps
$(collect_mas)
---SECTION: applications
$(collect_applications)
---SECTION: macos_defaults
$(collect_macos_defaults)
---SECTION: dock_apps
$(collect_dock_apps)
---SECTION: config_drift
$(collect_config_drift)
---SECTION: cli_tools
$(collect_cli_tools)
---SECTION: node_globals
$(collect_node_globals)
---SECTION: npm_config
$(collect_npm_config)
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
---SECTION: workloads
$(collect_workloads)
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
---SECTION: usage_activity
$(collect_usage_activity)
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
---SECTION: backup_posture
$(collect_backup_posture)
---SECTION: git_repos
$GIT_REPOS_JSON
---SECTION: data_inventory
$(collect_data_inventory)
---SECTION: secret_inventory
$(collect_secret_inventory)
---SECTION: fleet_update
$(collect_fleet_update)
AUDIT_DATA
)

# ── Device registration (replaces heartbeat.sh) ───────────────────────
# Read this device's currently-assigned role from the config service.
# Echoes the role, or empty string if the device isn't registered yet /
# the service is unreachable (callers decide the default).

register_device() {
  local config_url="$1"
  local ts_ip="" ssh_pub="" age_pub="" uptime_str="" nix_ver="" nix_gen=""

  ts_ip=$(run_timeout 5 tailscale ip -4 2>/dev/null || echo "")
  nix_ver=$(run_timeout 5 nix --version 2>/dev/null || echo "")
  uptime_str=$(uptime | sed 's/.*up //' | sed 's/,.*//')

  if [[ "$OS" == "Darwin" ]]; then
    nix_gen=$(run_timeout 10 darwin-rebuild --list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
  else
    nix_gen=$(run_timeout 10 nixos-rebuild list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
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
    else
      warn "Config service not reachable — printing audit locally" >&2
      echo "$AUDIT"
    fi
    # Install the daily schedule FIRST — it's the critical step and must not be
    # skipped by a later (cosmetic) failure. Runs whether or not the service was
    # reachable; `|| warn` keeps a failed install from aborting under set -e.
    if [[ "$MODE" == "--run-and-install" ]]; then
      install_cron || warn "Daily audit schedule was NOT installed (see message above)" >&2
    fi
    # Then the post-setup checklist (cosmetic; only when the service is reachable).
    if [[ -n "$CONFIG_URL" ]] && { [[ -t 1 || "$MODE" == "--run-and-install" ]]; } && [[ -z "${CRON_TAG_PRESENT:-}" ]]; then
      show_checklist "$CONFIG_URL"
    fi
    ;;
esac
