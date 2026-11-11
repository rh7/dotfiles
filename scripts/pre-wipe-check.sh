#!/usr/bin/env bash
# pre-wipe-check.sh — READ-ONLY "is it safe to wipe this Mac?" report.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash -s -- --skip-protected
#   ./scripts/pre-wipe-check.sh [--skip-protected] [--suggest-casks] [--offline] [--host NAME]
#   sudo ./scripts/pre-wipe-check.sh --all-users [--skip-protected] [--offline] [--host NAME]
#
#   --skip-protected  never touch macOS privacy-protected locations (Desktop,
#                     Documents, Downloads, Pictures/Photos, iCloud Drive,
#                     ~/Library/CloudStorage, app containers, Mail, Messages).
#                     Without it they are read in ONE announced step, which may
#                     raise macOS permission prompts; denying is safe.
#   --suggest-casks   also run `brew search` for manual apps with no exact cask
#                     match (slow: ~1s per app)
#   --offline         do not query the fleet control plane
#   --host NAME       control-plane hostname to check (default: this Mac's
#                     hostname, lowercased, without .local)
#   --all-users       admin mode: run with sudo from a terminal that has Full
#                     Disk Access. Lists every real account (UID >= 501, not
#                     hidden, home under /Users) and checks each one AS that
#                     account (sudo -u), into one combined report owned by you.
#
# What it guarantees:
#   * Read-only. The only file this script writes is the report,
#     ~/pre-wipe-<host>-<YYYYmmdd-HHMM>.md (mode 600; with --all-users it is
#     written as, and into the home of, the admin who ran sudo). Git is run with
#     GIT_OPTIONAL_LOCKS=0 so `git status` does not refresh the index. Here-strings
#     are avoided because bash 3.2 backs them with temp files. Tools it queries
#     may still touch their OWN caches: Homebrew (bootsnap disabled, but it can
#     refresh ~/Library/Caches/Homebrew) and gpg (may start gpg-agent). npm logs
#     are turned off. No user data is ever modified or deleted — the cleanup
#     section only measures.
#   * Nothing leaves the machine except one GET of this host's retirement verdict
#     from the fleet config service. No file names or contents are uploaded.
#   * No sudo, except --all-users, which must itself be started with sudo; it
#     only uses root to list accounts, size homes and drop to each account.
#   * Secrets: names, counts and public fingerprints only — never contents.
#     Wallet files are never opened: presence and folder size only.
#   * Stock macOS only (bash 3.2, osascript/JXA for JSON+plists, du, find,
#     defaults, plutil, perl for timeouts). brew/mas/jq/gpg/npm/pipx/uv are used
#     when present; /usr/bin/git is used only when the developer tools are
#     actually installed (the stub would pop an install dialog).
#
# Exit codes: 0 = no RED items, 1 = RED items present, 2 = script error.

# The report shows paths as "~/…" for the reader; those tildes are literal text.
# shellcheck disable=SC2088
set -o pipefail

PWC_VERSION="1"
PWC_RAW_URL="https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh"

SKIP_PROTECTED=0
SUGGEST_CASKS=0
OFFLINE=0
HOST_OVERRIDE=""
ALL_USERS=0       # --all-users: root parent that re-invokes itself per account
AS_USER=""        # --as-user NAME: internal, the per-account child
PART=all          # --part system|user: what a child checks (all = single-user run)

BIG_KB=102400      # 100 MB: a local-only folder this size is called out RED
SMALL_KB=1024      # 1 MB: below this a folder is treated as empty
DU_TIMEOUT=20      # seconds per du target
SIZE_BUDGET=100    # seconds of du across the whole run before sizing stops
CLEANUP_BUDGET=120 # fresh du budget for the cleanup + wallet sections
GIT_TIMEOUT=10     # seconds per git command
FIND_TIMEOUT=60    # seconds for the repo discovery walk
LARGE_FIND_TIMEOUT=120 # seconds for the largest-files walk
LARGE_MIN_MB=500   # "largest files" threshold
LARGE_TOP=30       # rows in the largest-files table
INSTALLER_MIN_MB=200
ACCOUNT_DU_TIMEOUT=90  # --all-users: seconds to size one whole home

USERS_ROOT=/Users      # real accounts' homes live here
APPS_DIR=/Applications
STUDIO_HOST=rouvens-mac-studio   # fleet restic REST server (rh-device-management)
RESTIC_PORT=8000
STUDIO_FREE_NOTE="433 GB free on 2026-11-11"

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

# The script's own text, for --all-users re-invocation (fed to each child on
# stdin, so an account that cannot read the admin's home can still run it).
PWC_SELF="${BASH_SOURCE[0]:-}"
SELF_TEXT=""

# ── report buffer + findings ────────────────────────────────────────────────
# The verdict goes at the TOP but is only known at the end, so the body is
# buffered and printed (and saved) once.
BODY=""
N_RED=0; N_AMBER=0; N_GREEN=0
RED_ITEMS=""; AMBER_ITEMS=""
PLAN_ROWS=""     # "USER\tLEVEL\tKB\tPATH\tLABEL" — what the backup plan copies
PLAN_USER=""
PROGRESS_TAG="pre-wipe"

emit()  { BODY+="$*"$'\n'; }
blank() { BODY+=$'\n'; }
progress() { printf '[%s] %s\n' "$PROGRESS_TAG" "$*" >&2; }

# plan_path LEVEL KB PATH LABEL — a local-only path the backup plan must copy
# (RED) or should consider (AMBER). KB may be "?".
plan_path() { PLAN_ROWS+="$PLAN_USER"$'\t'"$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'; }

finding() { # finding RED|AMBER|GREEN text
  case "$1" in
    RED)   N_RED=$((N_RED + 1));     RED_ITEMS+="- $2"$'\n' ;;
    AMBER) N_AMBER=$((N_AMBER + 1)); AMBER_ITEMS+="- $2"$'\n' ;;
    GREEN) N_GREEN=$((N_GREEN + 1)) ;;
  esac
  emit "- **[$1]** $2"
}

# ── pure helpers (covered by scripts/tests/pre-wipe-check.test.sh) ──────────

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The registry key a device is filed under: the config service lowercases every
# hostname it is given (canonicalizeHostname, #62) and audit-device.sh sends
# `hostname` minus a trailing .local, so mirror both.
canonical_host() {
  local h
  h="$(lower "$(printf '%s' "$1" | tr -d '[:space:]')")"
  h="${h%.}"
  h="${h%.local}"
  printf '%s' "$h"
}

human_kb() {
  awk -v k="$1" 'BEGIN {
    if (k !~ /^[0-9]+$/) { print "?"; exit }
    split("KB MB GB TB", u, " "); i = 1
    while (k >= 1024 && i < 4) { k /= 1024; i++ }
    if (i == 1) printf "%d %s\n", k, u[i]; else printf "%.1f %s\n", k, u[i]
  }'
}

verdict_word() { # verdict_word RED AMBER
  if [ "${1:-0}" -gt 0 ]; then echo "no"
  elif [ "${2:-0}" -gt 0 ]; then echo "check"
  else echo "likely"; fi
}

tilde_path() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

md_cell() { # escape a value for a markdown table cell
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# Best guess at the Homebrew cask token for an app name ("Google Chrome.app" →
# google-chrome). Only ever used as a suggestion, never as a classification.
cask_token_guess() {
  local n="${1%.app}"
  n="$(lower "$n")"
  n="${n// /-}"
  printf '%s' "$n" | tr -cd 'a-z0-9.+@-'
}

# classify_app PATH BUNDLE_ID RECEIPT(0|1|2) IN_CASK(0|1)
#   → nix | mas | apple | brew | setapp | manual
# RECEIPT: 1 = Contents/_MASReceipt, 2 = iOS/iPadOS wrapper (App Store only).
# Only apps that ship WITH macOS count as "apple" (skipped). Apple-authored
# downloads — Xcode from developer.apple.com, Safari Technology Preview — must
# be reinstalled like anything else, so they fall through to cask/manual.
classify_app() {
  case "$1" in
    */"Nix Apps"/*|*/"Home Manager Apps"/*|/nix/store/*) echo nix; return ;;
  esac
  case "$3" in 1|2) echo mas; return ;; esac
  [ "$4" = 1 ] && { echo brew; return; }
  case "$2" in
    com.apple.*)
      case "$1" in
        /System/*|/Applications/Safari.app|/Applications/Utilities/*) echo apple; return ;;
      esac ;;
  esac
  case "$1" in */Setapp/*) echo setapp; return ;; esac
  case "$2" in *-setapp|*.setapp) echo setapp; return ;; esac
  echo manual
}

# What a top-level entry of $HOME is, for deciding how much its loss matters.
home_entry_kind() {
  case "$1" in
    Library|.Trash|Applications|.DS_Store|.CFUserTextEncoding|.localized) echo skip ;;
    Desktop|Documents) echo dd ;;
    Downloads|Movies|Pictures|Public|Sites) echo standard ;;
    Music) echo music ;;
    "iCloud Drive (Archive)"*) echo other ;;
    Dropbox|"Dropbox ("*|OneDrive|OneDrive*|"Google Drive"|"Google Drive ("*|"Creative Cloud Files"*|Box|"Box Sync"|"iCloud Drive") echo cloud ;;
    .ssh|.gnupg|.aws|.kube|.netrc|.git-credentials|.password-store) echo secret ;;
    .orbstack|OrbStack|.lima|.colima|.docker|.vagrant.d|Parallels|"Virtual Machines"|"Virtual Machines.localized"|"VirtualBox VMs") echo vm ;;
    .cache|.npm|.npm-global|.cargo|.rustup|.gradle|.m2|.pnpm-store|.bun|.nvm|.pyenv|.rbenv|.gem|.ollama|.lmstudio|.vscode|.vscode-insiders|.cursor|.windsurf|.node-gyp|.yarn|.deno|.expo|.android|.swiftpm|.platformio|go|.nix-defexpr|.nix-profile|.cocoapods|.conda|miniconda3|anaconda3|.pub-cache|.dartServer|.huggingface|.zsh_sessions) echo cache ;;
    *) echo other ;;
  esac
}

# home_entry_level KIND KB DD_SYNCED(0|1) HAS_REPOS(0|1) NAME [DENIED(0|1)]
#   → "LEVEL<TAB>note"
# LEVEL is RED, AMBER, GREEN, REPO (folded into one finding) or NONE (table
# note only). A partly unreadable folder only has a lower-bound size, so it is
# never allowed to read as harmless (NONE/REPO): it becomes AMBER instead.
home_entry_level() {
  local r
  r="$(_home_level_by_size "$@")"
  if [ "${6:-0}" = 1 ]; then
    case "$1" in cache|secret) ;;
      *) case "${r%%$'\t'*}" in NONE|REPO) r="AMBER"$'\t'"partly unreadable: the size is a lower bound, check it by hand" ;; esac ;;
    esac
  fi
  printf '%s\n' "$r"
}

_home_level_by_size() {
  local kind="$1" kb="$2" synced="$3" repos="$4" name="$5"
  if [ "$kb" = "?" ]; then
    printf 'AMBER\tcheck it by hand\n'; return
  fi
  case "$kind" in
    dd)
      if [ "$synced" = 1 ]; then printf 'GREEN\tiCloud Desktop & Documents\n'
      elif [ "$kb" -ge "$SMALL_KB" ]; then printf 'RED\tnot iCloud-synced: local only\n'
      else printf 'NONE\tnot synced, (near) empty\n'; fi ;;
    standard)
      if [ "$kb" -ge "$BIG_KB" ]; then
        if [ "$name" = Downloads ]; then printf 'RED\tDownloads is never synced\n'
        else printf 'RED\tnot synced by iCloud Drive\n'; fi
      else printf 'NONE\tsmall\n'; fi ;;
    music)
      if [ "$kb" -ge "$BIG_KB" ]; then printf 'AMBER\tpurchases re-download; ripped/imported music does not\n'
      else printf 'NONE\tsmall\n'; fi ;;
    cache)  printf 'NONE\ttools/caches, re-installable\n' ;;
    secret) printf 'NONE\tsee Secrets\n' ;;
    vm)
      if [ "$kb" -ge "$BIG_KB" ]; then printf 'RED\tVM/container disks are local only\n'
      else printf 'NONE\tsmall\n'; fi ;;
    *)
      if [ "$repos" = 1 ]; then printf 'REPO\tholds git repos (see Git)\n'
      elif [ "$kb" -ge "$BIG_KB" ]; then printf 'RED\tlocal only\n'
      elif [ "$kb" -ge "$SMALL_KB" ]; then printf 'NONE\tsmall, local only\n'
      else printf 'NONE\t(near) empty\n'; fi ;;
  esac
}

# Known app data that a reinstall does NOT bring back. Matches an
# Application Support / Containers / Group Containers entry name.
# → "LEVEL<TAB>note" or nothing.
appdata_flag() {
  case "$1" in
    Signal|org.whispersystems.signal-desktop*)
      printf 'RED\tSignal Desktop history is not synced to a new install\n' ;;
    *WhatsApp*|*whatsapp*)
      printf 'AMBER\tWhatsApp Desktop history lives on the phone; re-link after the wipe\n' ;;
    com.utmapp.UTM|*Parallels*|*parallels*|"VMware Fusion"|com.vmware.fusion*)
      printf 'VM\tvirtual machine disks are local only\n' ;;
    com.docker.docker|"Docker Desktop"|*dev.orbstack*|OrbStack)
      printf 'AMBER\tcontainer volumes are local only (images re-pull)\n' ;;
    MobileSync)
      printf 'NONE\tdevice backups: judged under Data cleanup candidates\n' ;;
    obsidian)
      printf 'NONE\tvaults checked separately below\n' ;;
  esac
}

# git_at_risk DIRTY UNPUSHED NOREMOTE STASHES → 0 (safe) / 1 (unique work here)
git_at_risk() {
  [ "${1:-0}" != 0 ] || [ "${2:-0}" != 0 ] || [ "${3:-0}" != 0 ] || [ "${4:-0}" != 0 ]
}

# mas list → "ID<TAB>Name"
parse_mas_list() {
  sed -n -E 's/^[[:space:]]*([0-9]+)[[:space:]]+(.*[^[:space:]])[[:space:]]+\(.*\)[[:space:]]*$/\1	\2/p'
}

# gpg --with-colons → primary secret key fingerprints (subkeys skipped)
parse_gpg_fprs() {
  awk -F: '/^sec:/ { want = 1; next } /^ssb:/ { want = 0 } /^fpr:/ && want { print $10; want = 0 }'
}

# Is a path inside something that is synced off this Mac? Same provider roots
# as home_entry_kind's "cloud" set, so the two never disagree.
is_cloud_path() { # is_cloud_path PATH DD_SYNCED
  local top rest
  case "$1" in
    "$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*) return 0 ;;
    "$HOME/Desktop"|"$HOME/Desktop/"*|"$HOME/Documents"|"$HOME/Documents/"*) [ "$2" = 1 ]; return ;;
    "$HOME"/*)
      rest="${1#"$HOME"/}"; top="${rest%%/*}"
      [ "$(home_entry_kind "$top")" = cloud ] ;;
    *) return 1 ;;
  esac
}

# Lookup in a "\nKEY\tVALUE\n" table without forking (bash 3.2 has no
# associative arrays). Prints VALUE, returns 1 when KEY is absent.
table_get() { # table_get TABLE KEY
  local t="$1" k="$2" rest
  case "$t" in
    *$'\n'"$k"$'\t'*) rest="${t#*$'\n'"$k"$'\t'}"; printf '%s' "${rest%%$'\n'*}"; return 0 ;;
  esac
  return 1
}

# ── multi-user + cleanup helpers (covered by the test file, with stubs) ─────

# dscl . -read /Users/NAME NFSHomeDirectory IsHidden → "HOME<TAB>HIDDEN(0|1)".
# dscl puts a value containing spaces on its own indented line, and reports
# IsHidden as "dsAttrTypeNative:IsHidden".
parse_dscl_user() {
  awk '
    /^[^ \t]/ {
      line = $0; sub(/^dsAttrTypeNative:/, "", line)
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[ \t]*/, "", val)
      if (val != "") v[key] = val
      next
    }
    /^[ \t]/ { if (key != "" && !(key in v)) { s = $0; sub(/^[ \t]+/, "", s); v[key] = s } }
    END {
      h = ("NFSHomeDirectory" in v) ? v["NFSHomeDirectory"] : ""
      x = ("IsHidden" in v) ? tolower(v["IsHidden"]) : ""
      printf "%s\t%d\n", h, (x == "1" || x == "yes" || x == "true")
    }'
}

# Real, visible local accounts → "NAME<TAB>UID<TAB>HOME". Excludes system
# accounts (UID < 501, _names), hidden accounts (IsHidden) and anything whose
# home is not an existing folder under $USERS_ROOT (sharing-only users).
list_real_users() {
  local name uid info home hidden
  dscl . -list /Users UniqueID 2>/dev/null | while read -r name uid; do
    case "$name" in ''|_*) continue ;; esac
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 501 ] || continue
    info="$(dscl . -read "/Users/$name" NFSHomeDirectory IsHidden 2>/dev/null | parse_dscl_user)"
    home="${info%%$'\t'*}"; hidden="${info##*$'\t'}"
    [ "$hidden" = 1 ] && continue
    case "$home" in "$USERS_ROOT"/?*) ;; *) continue ;; esac
    [ -d "$home" ] || continue
    printf '%s\t%s\t%s\n' "$name" "$uid" "$home"
  done
}

user_is_admin() { # user_is_admin NAME
  local m
  m=" $(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership://' | tr '\n' ' ') "
  case "$m" in *" $1 "*) return 0 ;; esac
  return 1
}

last_login() { # last_login NAME → "Wed Nov 11 16:26" or nothing
  run_timeout 10 last -1 "$1" 2>/dev/null \
    | sed -n -E '/^wtmp begins/d; s/.*([A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}).*/\1/p' | head -1
}

# fda_probe DIR... — Full Disk Access check: TCC lets anyone stat these
# folders but only an FDA-granted terminal list them, even as root.
# Prints the first blocked folder. 0 = all readable, 1 = blocked, 2 = none exist.
fda_probe() {
  local p any=0
  for p in "$@"; do
    [ -d "$p" ] || continue
    any=1
    if ! ls -A "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; return 1; fi
  done
  [ "$any" = 1 ] || return 2
  return 0
}

fda_help() { # fda_help BLOCKED_DIR SELF
  local term
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) term="Terminal (/System/Applications/Utilities/Terminal.app)" ;;
    iTerm.app) term="iTerm (/Applications/iTerm.app)" ;;
    ghostty) term="Ghostty (/Applications/Ghostty.app)" ;;
    WezTerm) term="WezTerm" ;;
    vscode) term="Visual Studio Code (its integrated terminal)" ;;
    '') term="the terminal app you ran sudo from (Terminal, iTerm, Ghostty, …)" ;;
    *) term="your terminal app ($TERM_PROGRAM)" ;;
  esac
  printf '%s\n' \
    "pre-wipe-check: this terminal does not have Full Disk Access." \
    "macOS refused to list $1 even as root, so other accounts' Mail, Messages," \
    "Safari and app data would silently be missing from the report. Nothing was checked." \
    "" \
    "Grant it, then re-run:" \
    "  1. Open System Settings → Privacy & Security → Full Disk Access" \
    "     (shortcut: open \"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles\")" \
    "  2. Click +, authenticate with your admin password, and add $term." \
    "     In the file picker, ⇧⌘G and type /Applications or /System/Applications/Utilities." \
    "  3. Make sure its switch is ON." \
    "  4. Quit the terminal completely (⌘Q) and open it again — the grant only applies to newly started apps." \
    "  5. Re-run: sudo $2 --all-users" \
    "" \
    "Revoke it afterwards in the same pane if you do not want the terminal to keep it."
}

# build_child_argv NAME HOME PART → CHILD_ARGV: re-run this script AS that
# account with its own HOME, so iCloud/defaults/keychain-adjacent reads are
# that account's. The script text arrives on stdin (bash -s): the account may
# not be able to read the admin's copy of it.
build_child_argv() {
  CHILD_ARGV=(sudo -n -u "$1" -H /usr/bin/env "HOME=$2" "USER=$1" "LOGNAME=$1")
  [ "$3" = system ] && [ -n "${CONFIG_SERVICE_URL:-}" ] && CHILD_ARGV+=("CONFIG_SERVICE_URL=$CONFIG_SERVICE_URL")
  CHILD_ARGV+=(/bin/bash -s -- --as-user "$1" --part "$3")
  [ "$SKIP_PROTECTED" = 1 ] && CHILD_ARGV+=(--skip-protected)
  [ "$OFFLINE" = 1 ] && CHILD_ARGV+=(--offline)
  [ "$3" = system ] && [ "$SUGGEST_CASKS" = 1 ] && CHILD_ARGV+=(--suggest-casks)
  [ -n "$HOST_OVERRIDE" ] && CHILD_ARGV+=(--host "$HOST_OVERRIDE")
  return 0
}

# A child prints its findings as a fragment; the parent folds it in.
emit_fragment() {
  local l
  printf '@@PWC-FRAGMENT\t1\n'
  printf '@@COUNTS\t%s\t%s\t%s\n' "$N_RED" "$N_AMBER" "$N_GREEN"
  [ -z "$CFG_URL" ] || printf '@@CFG\t%s\n' "$CFG_URL"
  while IFS= read -r l; do [ -z "$l" ] || printf '@@RED\t%s\n' "${l#- }"; done < <(printf '%s' "$RED_ITEMS")
  while IFS= read -r l; do [ -z "$l" ] || printf '@@AMBER\t%s\n' "${l#- }"; done < <(printf '%s' "$AMBER_ITEMS")
  while IFS= read -r l; do [ -z "$l" ] || printf '@@PLAN\t%s\n' "$l"; done < <(printf '%s' "$PLAN_ROWS")
  printf '@@BODY\n%s@@END\n' "$BODY"
}

# parse_fragment TEXT LABEL — adds the child's counts, items (prefixed
# "[LABEL]") and plan rows; sets FRAG_BODY. 1 = not a complete fragment.
parse_fragment() {
  local text="$1" hdr line a b c
  FRAG_BODY=""
  case "$text" in "@@PWC-FRAGMENT"$'\t'1$'\n'*$'\n'@@BODY$'\n'*@@END) ;; *) return 1 ;; esac
  hdr="${text%%$'\n'@@BODY$'\n'*}"
  FRAG_BODY="${text#*$'\n'@@BODY$'\n'}"; FRAG_BODY="${FRAG_BODY%@@END}"
  while IFS= read -r line; do
    case "$line" in
      @@COUNTS$'\t'*)
        line="${line#*$'\t'}"; a="${line%%$'\t'*}"; line="${line#*$'\t'}"
        b="${line%%$'\t'*}"; c="${line#*$'\t'}"
        case "$a" in ''|*[!0-9]*) return 1 ;; esac
        case "$b" in ''|*[!0-9]*) return 1 ;; esac
        case "$c" in ''|*[!0-9]*) return 1 ;; esac
        N_RED=$((N_RED + a)); N_AMBER=$((N_AMBER + b)); N_GREEN=$((N_GREEN + c)) ;;
      @@RED$'\t'*)   RED_ITEMS+="- [$2] ${line#*$'\t'}"$'\n' ;;
      @@AMBER$'\t'*) AMBER_ITEMS+="- [$2] ${line#*$'\t'}"$'\n' ;;
      @@PLAN$'\t'*)  PLAN_ROWS+="${line#*$'\t'}"$'\n' ;;
      @@CFG$'\t'*)   CFG_URL="${line#*$'\t'}" ;;
    esac
  done < <(printf '%s\n' "$hdr")
  return 0
}

# One heading level down, outside code fences (per-account sections nest
# under "## Account …").
demote_headings() { awk '/^```/ { f = !f } !f && /^#/ { print "#" $0; next } { print }'; }

# Data cleanup classes. → "CLASS<TAB>note"
cleanup_class() {
  case "$1" in
    caches)        printf 'SAFE-TO-DELETE\tapps rebuild their caches\n' ;;
    deriveddata)   printf 'SAFE-TO-DELETE\tXcode rebuilds it\n' ;;
    devicesupport) printf 'SAFE-TO-DELETE\tXcode copies device symbols again when a device connects\n' ;;
    sim-caches)    printf 'SAFE-TO-DELETE\tsimulator caches, rebuilt on demand\n' ;;
    maildownloads) printf 'SAFE-TO-DELETE\tcopies of attachments opened from Mail; the originals stay in the mailbox\n' ;;
    conda-pkgs)    printf 'SAFE-TO-DELETE\tconda package cache (`conda clean --all`)\n' ;;
    cargo-cache)   printf 'SAFE-TO-DELETE\tcargo download cache, re-fetched on the next build\n' ;;
    rustup)        printf 'SAFE-TO-DELETE\tRust toolchains; rustup reinstalls them\n' ;;
    node_modules)  printf 'SAFE-TO-DELETE\t`npm install` recreates them\n' ;;
    installer-installed) printf 'SAFE-TO-DELETE\tinstaller for an app that is installed\n' ;;
    sim-devices)   printf 'REVIEW\tsimulator devices hold test-app data; `xcrun simctl delete unavailable` removes only stale ones\n' ;;
    cargo-bin)     printf 'REVIEW\t`cargo install`ed binaries: `cargo install --list` to recreate (config/credentials: see Secrets)\n' ;;
    xcarchives)    printf 'REVIEW\tholds the dSYMs of shipped builds\n' ;;
    mobilesync)    printf 'REVIEW\tmay be the ONLY copy of an old iPhone/iPad: keep or copy off, not cleanup\n' ;;
    trash)         printf 'REVIEW\talready discarded, but look before emptying\n' ;;
    downloads)     printf 'REVIEW\tnever synced; sort before deleting\n' ;;
    conda-env)     printf 'REVIEW\texport first: `conda env export -n <env> > <env>.yml`\n' ;;
    docker|orbstack) printf 'REVIEW\timages re-pull; volumes and VM disks are local only\n' ;;
    installer)     printf 'REVIEW\tno matching installed app found\n' ;;
    archive)       printf 'REVIEW\tzip archive: may hold data, not just an installer\n' ;;
    photos-dup)    printf 'REVIEW\tseveral Photos libraries: only the System Photo Library syncs with iCloud Photos\n' ;;
    photos)        printf 'KEEP\tthe Photos library (see Photos above)\n' ;;
    *)             printf 'KEEP\tunclassified\n' ;;
  esac
}

letters_only() { lower "${1%.app}" | tr -cd 'a-z'; }

# installer_kind FILENAME APPS("\nletters\n…", from letters_only) →
# installer-installed | installer | archive. Matches the installer's leading
# name (before any version digits) against installed app names; both sides
# must be >= 4 letters, so "vlc" stays REVIEW rather than risk a false SAFE.
installer_kind() {
  local n stem a
  n="$(lower "$1")"
  case "$n" in *.zip) echo archive; return ;; esac
  n="${n%.*}"; n="${n%%[0-9]*}"
  stem="$(printf '%s' "$n" | tr -cd 'a-z')"
  if [ "${#stem}" -ge 4 ]; then
    while IFS= read -r a; do
      [ "${#a}" -ge 4 ] || continue
      case "$stem" in "$a"*) echo installer-installed; return ;; esac
      case "$a" in "$stem"*) echo installer-installed; return ;; esac
    done < <(printf '%s\n' "$2")
  fi
  echo installer
}

fmt_epoch() { [ -n "$1" ] && date -r "$1" '+%Y-%m-%d' 2>/dev/null; }

# Single-quote for a copy-pasteable shell command. The quote and its escape go
# through variables: bash 3.2 and 5 parse a quoted replacement differently.
shq() { local q="'" r="'\\''"; local s="${1//$q/$r}"; printf "'%s'" "$s"; }

# plan_summary USER LEVEL → "KB<TAB>PATHS<TAB>UNKNOWN_SIZES" over the plan
# rows, a path inside another listed path counted once (via its ancestor).
plan_summary() {
  printf '%s' "$PLAN_ROWS" | awk -F'\t' -v u="$1" -v lv="$2" '$1 == u && $2 == lv { print $4 "\t" $3 }' \
    | LC_ALL=C sort -t$'\t' -k1,1 -u \
    | awk -F'\t' '{ for (i = 1; i <= n; i++) if (index($1, k[i] "/") == 1) next
                    k[++n] = $1; if ($2 ~ /^[0-9]+$/) s += $2; else unk++ }
                  END { printf "%d\t%d\t%d\n", s, n, unk }'
}
plan_paths() { # plan_paths USER LEVEL → unique paths, ancestors win
  printf '%s' "$PLAN_ROWS" | awk -F'\t' -v u="$1" -v lv="$2" '$1 == u && $2 == lv { print $4 }' \
    | LC_ALL=C sort -u \
    | awk '{ for (i = 1; i <= n; i++) if (index($0, k[i] "/") == 1) next; k[++n] = $0; print }'
}

# ── platform helpers ───────────────────────────────────────────────────────

# run_timeout SECS CMD... — macOS has no `timeout`; perl ships with it. On
# overrun the child is SIGKILLed and 124 returned (same as audit-device.sh).
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; my $p=fork; if($p){$SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm $s; waitpid $p,0; exit($?>>8)} else {exec @ARGV or exit 127}' "$secs" "$@"
  else
    "$@"
  fi
}

# du_size PATH — sets DU_KB (KB or "?") and DU_DENIED (1 if any part was
# unreadable, i.e. the number is a lower bound). Shares one time budget.
DU_KB="?"; DU_DENIED=0
SIZE_DEADLINE=0
du_size() {
  local out last
  DU_KB="?"; DU_DENIED=0
  [ "$SECONDS" -lt "$SIZE_DEADLINE" ] || return 0
  out="$(run_timeout "$DU_TIMEOUT" du -skx "$1" 2>&1)"
  last="${out##*$'\n'}"
  case "$last" in [0-9]*$'\t'*) DU_KB="${last%%$'\t'*}" ;; esac
  case "$out" in *"not permitted"*|*"Permission denied"*) DU_DENIED=1 ;; esac
}

size_label() { # size_label KB DENIED
  if [ "$1" = "?" ]; then
    if [ "$2" = 1 ]; then printf 'unreadable'; else printf 'unknown (timed out)'; fi
    return
  fi
  local s; s="$(human_kb "$1")"
  [ "$2" = 1 ] && s="≥ $s (partly unreadable)"
  printf '%s' "$s"
}

# Is PATH a mount point (e.g. OrbStack's ~/OrbStack NFS view)? Those are views
# of data stored elsewhere, so they are listed but never sized or walked.
is_mount_point() {
  local a b
  a="$(stat -f %d "$1" 2>/dev/null)" || return 1
  b="$(stat -f %d "$HOME" 2>/dev/null)" || return 1
  [ "$a" != "$b" ]
}

# /usr/bin/git without the developer tools is a stub that opens an install
# dialog; never call it on a fresh Mac.
have_git() {
  local g dev
  g="$(command -v git 2>/dev/null)" || return 1
  if [ "$g" = /usr/bin/git ]; then
    dev="$(xcode-select -p 2>/dev/null)" || return 1
    [ -x "$dev/usr/bin/git" ] || return 1
  fi
  return 0
}

g() { GIT_OPTIONAL_LOCKS=0 run_timeout "$GIT_TIMEOUT" git -C "$@" 2>/dev/null; }

brew_q() {
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_BOOTSNAP=1 run_timeout 90 brew "$@" 2>/dev/null
}

# JSON / plist evaluation through JXA (osascript ships with every macOS; jq and
# python3 do not). The expression is a JS function body over `d`.
JXA_JSON='ObjC.import("Foundation");
function run(argv) {
  var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  var s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
  var d; try { d = JSON.parse(s); } catch (e) { return ""; }
  var r; try { r = (new Function("d", argv[0]))(d); } catch (e) { return ""; }
  return (r === undefined || r === null) ? "" : String(r);
}'
JXA_PLIST='ObjC.import("Foundation");
function run(argv) {
  var x = $.NSDictionary.dictionaryWithContentsOfFile(argv[0]);
  if (x.isNil()) return "";
  var d = ObjC.deepUnwrap(x);
  var r; try { r = (new Function("d", argv[1]))(d); } catch (e) { return ""; }
  return (r === undefined || r === null) ? "" : String(r);
}'
# stdin: one .app path per line → "path<TAB>bundle id<TAB>version<TAB>receipt"
JXA_APPINFO='ObjC.import("Foundation");
function clean(v) { return String(v === undefined || v === null ? "" : v).replace(/[\t\n\r]/g, " "); }
function run(argv) {
  var fm = $.NSFileManager.defaultManager;
  var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  var s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
  var out = [];
  s.split("\n").forEach(function (p) {
    if (!p) return;
    var receipt = 0, plist = p + "/Contents/Info.plist";
    if (fm.fileExistsAtPath(p + "/Contents/_MASReceipt/receipt")) receipt = 1;
    else if (fm.fileExistsAtPath(p + "/Wrapper")) { receipt = 2; plist = p + "/WrappedBundle/Info.plist"; }
    var x = $.NSDictionary.dictionaryWithContentsOfFile(plist);
    var o = x.isNil() ? {} : ObjC.deepUnwrap(x);
    out.push([p, clean(o.CFBundleIdentifier), clean(o.CFBundleShortVersionString || o.CFBundleVersion), receipt].join("\t"));
  });
  return out.join("\n");
}'
jxa_json()  { osascript -l JavaScript -e "$JXA_JSON" "$1" 2>/dev/null | sed '/^$/d'; }
jxa_plist() { [ -r "$1" ] || return 0; osascript -l JavaScript -e "$JXA_PLIST" "$1" "$2" 2>/dev/null | sed '/^$/d'; }

# ── shared config-service resolver ─────────────────────────────────────────
# Third verbatim copy of the block in audit-device.sh / collector-runner.sh;
# this script is fetched standalone over HTTP too, so it cannot source it.
# scripts/tests/find-config-service.test.sh fails if the copies drift.
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

# ── collected state ────────────────────────────────────────────────────────
HOST=""; CFG_URL=""
ICLOUD_SIGNED_IN=0; ICLOUD_SERVICES=""   # "\nNAME\tenabled(0|1)\tstatus"
DD_SYNCED=0; DD_SOURCE="not reported"
GIT_OK=0
REPOS=""          # newline list of repo roots
ENV_FILES=""      # newline list of .env* files found by the walk
HOME_ROWS=""      # "KB\tDENIED\tNAME" per top-level home entry
APPSUP_ROWS=""    # "KB\tDENIED\tNAME"
CONT_ROWS=""      # "KB\tDENIED\tNAME" (Containers + Group Containers)
PHOTO_ROWS=""     # "KB\tDENIED\tPATH"
CLOUD_ROOTS=""    # newline list of cloud-provider roots seen
MAIL_KB=""; MAIL_DENIED=0; MSG_KB=""; MSG_DENIED=0
ICLOUD_ROOT_EXISTS=""
PROTECTED_DONE=0
MANUAL_COUNT=0; SETAPP_COUNT=0

icloud_service() { # icloud_service NAME → 0 when the account reports it enabled
  local v; v="$(table_get "$ICLOUD_SERVICES" "$1")" || return 1
  [ "${v%%$'\t'*}" = 1 ]
}

# ── section: header + iCloud account state (non-protected) ─────────────────

collect_icloud_account() {
  local rows
  # MobileMeAccounts lists the signed-in account's iCloud services. Only the
  # service names and switches are read — never the account id or e-mail.
  rows="$(jxa_plist "$HOME/Library/Preferences/MobileMeAccounts.plist" '
    var a = (d.Accounts || [])[0]; if (!a) return "";
    var o = ["__signed_in__\t1\t"];
    (a.Services || []).forEach(function (s) {
      o.push(s.Name + "\t" + (s.Enabled ? 1 : 0) + "\t" + (s.status || ""));
    });
    return o.join("\n");')"
  ICLOUD_SERVICES=$'\n'"$rows"$'\n'
  table_get "$ICLOUD_SERVICES" __signed_in__ >/dev/null && ICLOUD_SIGNED_IN=1
  local cd; cd="$(table_get "$ICLOUD_SERVICES" CLOUDDESKTOP)" || cd=""
  case "$cd" in
    *$'\t'active) DD_SYNCED=1; DD_SOURCE="iCloud account reports Desktop & Documents active" ;;
  esac
}

# ── section 2: control plane ───────────────────────────────────────────────

section_control_plane() {
  emit "## 2. Control-plane verdict"
  blank
  if [ "$OFFLINE" = 1 ]; then
    finding AMBER "Control plane not consulted (--offline)."
    blank; return
  fi
  progress "resolving the fleet config service…"
  CFG_URL="$(find_config_service)"
  if [ -z "$CFG_URL" ]; then
    finding AMBER "Fleet config service not reachable (needs Tailscale; pin or CONFIG_SERVICE_URL). Retirement verdict not consulted."
    blank; return
  fi
  local resp code body parsed
  local -a hdr=()
  [ -n "${CONFIG_SERVICE_ADMIN_TOKEN:-}" ] && hdr=(-H "X-Admin-Token: $CONFIG_SERVICE_ADMIN_TOKEN")
  resp="$(curl -s --max-time 15 ${hdr[@]+"${hdr[@]}"} -w $'\n%{http_code}' "$CFG_URL/api/fleet/retirement/$HOST" 2>/dev/null)"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  emit "Service: \`$CFG_URL\` · host key: \`$HOST\`"
  blank
  case "$code" in
    200)
      parsed="$(printf '%s' "$body" | jxa_json '
        var o = ["status\t" + d.status, "ready\t" + d.ready,
                 "audit_age\t" + (d.audit_age_hours === null || d.audit_age_hours === undefined ? "" : d.audit_age_hours),
                 "summary\t" + (d.summary || "")];
        (d.blockers || []).forEach(function (b) { o.push("blocker\t" + b.severity + "\t" + String(b.detail).replace(/\s+/g, " ")); });
        (d.warnings || []).forEach(function (w) { o.push("warning\t" + w.severity + "\t" + String(w.detail).replace(/\s+/g, " ")); });
        return o.join("\n");')"
      local status ready age summary
      status="$(table_get $'\n'"$parsed"$'\n' status)"
      ready="$(table_get $'\n'"$parsed"$'\n' ready)"
      age="$(table_get $'\n'"$parsed"$'\n' audit_age)"
      summary="$(table_get $'\n'"$parsed"$'\n' summary)"
      if [ -z "$status" ]; then
        finding AMBER "Retirement verdict returned an unparseable body."
      elif [ "$ready" = true ]; then
        finding GREEN "Control plane: **$status** — $summary"
      elif [ "$status" = not-ready ]; then
        finding RED "Control plane: **not-ready** — $summary"
      else
        finding AMBER "Control plane: **$status** — $summary"
      fi
      [ -n "$age" ] && emit "  - based on the last uploaded audit, ${age}h old$( [ "${age%%.*}" -ge 24 ] 2>/dev/null && printf ' — refresh it first: `curl -fsSL config.rh7labs.com/audit | bash -s -- --run`')"
      local kind sev detail
      while IFS=$'\t' read -r kind sev detail; do
        case "$kind" in
          blocker) emit "  - blocker ($sev): $(md_cell "$detail")" ;;
          warning) emit "  - warning: $(md_cell "$detail")" ;;
        esac
      done < <(printf '%s\n' "$parsed")
      ;;
    401|403)
      finding AMBER "Retirement verdict is admin-gated and this caller is not an admin (HTTP $code). Run from an admin tailnet identity, or set CONFIG_SERVICE_ADMIN_TOKEN." ;;
    404)
      finding AMBER "\`$HOST\` is not registered with the control plane (HTTP 404) — nothing to retire there, but no server-side secret/backup check either." ;;
    *)
      finding AMBER "Retirement verdict unavailable (HTTP ${code:-none})." ;;
  esac
  blank
}

# ── section 3: apps ────────────────────────────────────────────────────────

section_apps() {
  # --all-users: the system part inventories /Applications once; each account
  # part covers what is per account (~/Applications, App Store, npm/pipx/uv).
  if [ "$PART" = user ]; then emit "## 3. Apps and tools for this account"
  else emit "## 3. Apps to reinstall"; fi
  blank
  progress "inventorying /Applications and ~/Applications…"
  local have_brew=0 have_mas=0 cask_map="" cask_list="" mas_map="" cask_names=""
  [ "$PART" != user ] && command -v brew >/dev/null 2>&1 && have_brew=1
  command -v mas  >/dev/null 2>&1 && have_mas=1

  if [ "$have_brew" = 1 ]; then
    cask_list="$(brew_q list --cask -1)"
    # app artifact → cask token. An artifact may be ["Src.app", {"target": "Dst.app"}].
    cask_map="$(brew_q info --json=v2 --cask --installed | jxa_json '
      var o = [];
      (d.casks || []).forEach(function (c) {
        (c.artifacts || []).forEach(function (a) {
          if (!a || !a.app) return;
          for (var i = 0; i < a.app.length; i++) {
            var x = a.app[i], n = null;
            if (typeof x === "string") {
              n = x;
              var nx = a.app[i + 1];
              if (nx && typeof nx === "object" && nx.target) { n = nx.target; i++; }
            } else if (x && x.target) n = x.target;
            if (n) o.push(n.split("/").pop() + "\t" + c.token);
          }
        });
      });
      return o.join("\n");')"
    cask_map=$'\n'"$cask_map"$'\n'
    cask_list=$'\n'"$cask_list"$'\n'
    local cn="${HOMEBREW_CACHE:-$HOME/Library/Caches/Homebrew}/api/cask_names.txt"
    [ -r "$cn" ] && cask_names=$'\n'"$(cat "$cn")"$'\n'
  fi
  if [ "$have_mas" = 1 ]; then
    local id name
    while IFS=$'\t' read -r id name; do
      [ -n "$id" ] && mas_map+=$'\n'"$name"$'\t'"$id"
    done < <(run_timeout 30 mas list 2>/dev/null | parse_mas_list)
    mas_map+=$'\n'
  fi

  # --all-users: ~/Applications is per account, reported in each account's part.
  local paths info where="/Applications and ~/Applications"
  local -a roots=(/Applications "$HOME/Applications")
  [ "$PART" = system ] && { roots=(/Applications); where="/Applications (per-account ~/Applications: under each account)"; }
  [ "$PART" = user ] && { roots=("$HOME/Applications"); where="~/Applications (this account only; /Applications is under \"this Mac\")"; }
  paths="$(find "${roots[@]}" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null | LC_ALL=C sort -f)"
  info="$(printf '%s\n' "$paths" | osascript -l JavaScript -e "$JXA_APPINFO" 2>/dev/null)"

  local t_mas="" t_brew="" t_nix="" t_setapp="" t_manual="" mas_lines="" n_apple=0 n_mas=0 n_brew=0 n_nix=0
  local p bid ver rc app base tok in_cask src masid guess hint
  while IFS=$'\t' read -r p bid ver rc; do
    [ -n "$p" ] || continue
    app="${p##*/}"; base="${app%.app}"
    in_cask=0; tok=""
    if tok="$(table_get "$cask_map" "$app")"; then in_cask=1
    else
      guess="$(cask_token_guess "$app")"
      case "$cask_list" in *$'\n'"$guess"$'\n'*) in_cask=1; tok="$guess" ;; esac
    fi
    src="$(classify_app "$p" "$bid" "$rc" "$in_cask")"
    case "$src" in
      apple) n_apple=$((n_apple + 1)) ;;
      nix) n_nix=$((n_nix + 1)); t_nix+="| $(md_cell "$base") | $(md_cell "$ver") |"$'\n' ;;
      mas)
        n_mas=$((n_mas + 1))
        masid="$(table_get "$mas_map" "$base")" || masid=""
        if [ -z "$masid" ] && [ "$rc" = 1 ]; then
          masid="$(mdls -raw -name kMDItemAppStoreAdamID "$p" 2>/dev/null)"
          case "$masid" in ''|'(null)') masid="" ;; esac
        fi
        [ "$rc" = 2 ] && base="$base (iPhone/iPad app)"
        t_mas+="| $(md_cell "$base") | ${masid:-?} | $(md_cell "$ver") |"$'\n'
        if [ -n "$masid" ]; then mas_lines+="mas install $masid  # $base"$'\n'
        else mas_lines+="# $base — id unknown (install mas, or search the App Store)"$'\n'; fi ;;
      brew) n_brew=$((n_brew + 1)); t_brew+="| $(md_cell "$base") | \`$tok\` | $(md_cell "$ver") |"$'\n' ;;
      setapp) SETAPP_COUNT=$((SETAPP_COUNT + 1)); t_setapp+="| $(md_cell "$base") | $(md_cell "$ver") |"$'\n' ;;
      manual)
        MANUAL_COUNT=$((MANUAL_COUNT + 1))
        guess="$(cask_token_guess "$app")"; hint=""
        if [ -n "$cask_names" ]; then
          case "$cask_names" in
            *$'\n'"$guess"$'\n'*) hint="\`brew install --cask $guess\`" ;;
            *) hint="no exact cask" ;;
          esac
        fi
        if [ -z "$hint" ] || [ "$hint" = "no exact cask" ]; then
          if [ "$SUGGEST_CASKS" = 1 ] && [ "$have_brew" = 1 ]; then
            local s; s="$(brew_q search --cask "$base" | grep -v '^==>' | head -3 | tr '\n' ' ')"
            [ -n "$s" ] && hint="search: ${s% }"
          fi
        fi
        if [ -z "$hint" ]; then
          if [ "$PART" = user ]; then hint="per-account install (no cask lookup here)"; else hint="(brew not installed)"; fi
        fi
        t_manual+="| $(md_cell "$base") | $(md_cell "$ver") | $(md_cell "$bid") | $(md_cell "$hint") |"$'\n' ;;
    esac
  done < <(printf '%s\n' "$info")

  emit "Apple system apps skipped: $n_apple. Every other \`.app\` in $where:"
  blank
  if [ "$n_mas" -gt 0 ]; then
    finding GREEN "$n_mas App Store app(s) — reinstall from the App Store (\`mas install <id>\`)."
    blank; emit "| App | MAS id | Version |"; emit "|---|---|---|"; BODY+="$t_mas"; blank
  fi
  if [ "$n_brew" -gt 0 ]; then
    finding GREEN "$n_brew Homebrew cask app(s) — reinstall via the Brewfile below or the dotfiles flake."
    blank; emit "| App | Cask | Version |"; emit "|---|---|---|"; BODY+="$t_brew"; blank
  fi
  if [ "$n_nix" -gt 0 ]; then
    finding GREEN "$n_nix Nix-managed app(s) — come back with \`nrs\` if declared in the dotfiles flake."
    blank; emit "| App | Version |"; emit "|---|---|"; BODY+="$t_nix"; blank
  fi
  if [ "$SETAPP_COUNT" -gt 0 ]; then
    finding AMBER "$SETAPP_COUNT Setapp app(s) — reinstall from Setapp after signing in."
    blank; emit "| App | Version |"; emit "|---|---|"; BODY+="$t_setapp"; blank
  fi
  if [ "$MANUAL_COUNT" -gt 0 ]; then
    finding AMBER "$MANUAL_COUNT manually installed app(s) — note the download source and licence key for each (or adopt a cask)."
    blank; emit "| App | Version | Bundle id | Reinstall hint |"; emit "|---|---|---|---|"; BODY+="$t_manual"; blank
  fi

  emit "### CLI packages"
  blank
  if [ "$have_brew" = 1 ]; then
    local leaves; leaves="$(brew_q leaves --installed-on-request | tr '\n' ' ')"
    emit "- Homebrew formulae installed on request: ${leaves:-none}"
  elif [ "$PART" != user ]; then
    emit "- Homebrew: not installed"
  fi
  if command -v npm >/dev/null 2>&1; then
    local npmg
    npmg="$(NPM_CONFIG_LOGS_MAX=0 NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false run_timeout 30 npm ls -g --depth=0 2>/dev/null \
      | sed -n -E 's/^.*── (.*)$/\1/p' | tr '\n' ' ')"
    emit "- npm globals: ${npmg:-none}"
  fi
  if command -v pipx >/dev/null 2>&1; then
    emit "- pipx: $(run_timeout 30 pipx list --short 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  fi
  if command -v uv >/dev/null 2>&1; then
    emit "- uv tools: $(run_timeout 30 uv tool list 2>/dev/null | awk '!/^-/ && NF {print $1}' | tr '\n' ' ')"
  fi
  blank

  if [ "$have_brew" = 1 ]; then
    local bf; bf="$(brew_q bundle dump --file=-)"
    emit "### Brewfile (\`brew bundle dump\`)"
    blank
    emit '```ruby'
    emit "${bf:-# brew bundle dump failed}"
    emit '```'
    blank
  fi
  if [ -n "$t_mas" ]; then
    emit "### App Store ids"
    blank
    emit '```sh'
    BODY+="$mas_lines"
    emit '```'
    blank
  fi
}

# ── data collection (non-protected) ────────────────────────────────────────

# The walk reports what it could NOT see, so a timeout or an unreadable
# subtree can never read as "no repos here".
WALK_TIMED_OUT=0; WALK_UNREADABLE=""
collect_git_walk() { # collect_git_walk ROOT MAXDEPTH — appends to REPOS / ENV_FILES
  local root="$1" depth="$2" out line rc p
  local -a top=()
  # Home-level prunes apply only to the $HOME walk; the protected step walks
  # Desktop/Documents/Downloads as roots of their own.
  if [ "$root" = "$HOME" ]; then
    top=(-path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "$HOME/Desktop" -o -path "$HOME/Documents"
         -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" -o -path "$HOME/Music" -o -path "$HOME/Movies"
         -o -path "$HOME/Applications" -o)
  fi
  out="$(run_timeout "$FIND_TIMEOUT" find "$root" -xdev -maxdepth "$depth" \
    \( ${top[@]+"${top[@]}"} \
       -name node_modules -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup -o -name .gradle \
       -o -name .m2 -o -name .pnpm-store -o -name .bun -o -name .nvm -o -name .pyenv -o -name .rbenv \
       -o -name .ollama -o -name .lmstudio -o -name .vscode -o -name .cursor -o -name .orbstack -o -name .docker \
       -o -name .colima -o -name .lima -o -name .venv -o -name venv -o -name Pods -o -name DerivedData \
       -o -name 'Dropbox' -o -name 'Dropbox (*' -o -name 'OneDrive*' -o -name 'Google Drive*' \
       -o -name 'Creative Cloud Files*' -o -name '*.photoslibrary' -o -name '*.app' \) -prune \
    -o -name .git -print -prune \
    -o -type f \( -name .env -o -name '.env.*' \) ! -name '*.example' ! -name '*.sample' ! -name '*.template' ! -name '*.dist' -print \
    2>&1)"
  rc=$?
  [ "$rc" = 124 ] && WALK_TIMED_OUT=1
  while IFS= read -r line; do
    case "$line" in
      "find: "*)
        p="${line#find: }"; p="${p%: *}"
        WALK_UNREADABLE+="$p"$'\n' ;;
      */.git) REPOS+="${line%/.git}"$'\n' ;;
      /*) ENV_FILES+="$line"$'\n' ;;
    esac
  done < <(printf '%s\n' "$out")
}

collect_home_sizes() {
  local e name kind
  progress "sizing top-level home folders (du, ${DU_TIMEOUT}s cap each)…"
  for e in "$HOME"/* "$HOME"/.[!.]* "$HOME"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    name="${e##*/}"
    kind="$(home_entry_kind "$name")"
    case "$kind" in skip|cloud) continue ;; esac
    case "$name" in Desktop|Documents|Downloads|Pictures) continue ;; esac   # protected step
    if [ -L "$e" ]; then
      HOME_ROWS+="L"$'\t'"0"$'\t'"$name"$'\n'; continue
    fi
    if is_mount_point "$e"; then
      HOME_ROWS+="M"$'\t'"0"$'\t'"$name"$'\n'; continue
    fi
    du_size "$e"
    HOME_ROWS+="$DU_KB"$'\t'"$DU_DENIED"$'\t'"$name"$'\n'
  done
}

collect_appsupport_sizes() {
  local e
  progress "sizing ~/Library/Application Support…"
  for e in "$HOME/Library/Application Support"/*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    du_size "$e"
    APPSUP_ROWS+="$DU_KB"$'\t'"$DU_DENIED"$'\t'"${e##*/}"$'\n'
  done
}

# ── the ONE protected step ─────────────────────────────────────────────────

collect_protected() {
  local e name
  progress "──────────────────────────────────────────────────────────────"
  progress "PROTECTED STEP: reading Desktop, Documents, Downloads, Pictures,"
  progress "iCloud Drive, ~/Library/CloudStorage, app containers, Mail, Messages."
  progress "macOS may ask for permission for each; Deny is safe (those items"
  progress "become AMBER). Re-run with --skip-protected to avoid this step."
  progress "──────────────────────────────────────────────────────────────"

  # iCloud Drive / Desktop & Documents — same signals as audit-device.sh
  # collect_backup_posture (#78): Desktop/Documents resolving into Mobile
  # Documents, or BOTH Desktop and Documents present in the CloudDocs root.
  local icr="$HOME/Library/Mobile Documents/com~apple~CloudDocs" desk docs
  if [ -d "$icr" ]; then ICLOUD_ROOT_EXISTS=1; else ICLOUD_ROOT_EXISTS=0; fi
  desk="$(cd "$HOME/Desktop" 2>/dev/null && pwd -P)"
  docs="$(cd "$HOME/Documents" 2>/dev/null && pwd -P)"
  case "$desk$docs" in
    *"Mobile Documents"*) DD_SYNCED=1; DD_SOURCE="Desktop/Documents resolve into iCloud Drive" ;;
    *) if [ -e "$icr/Desktop" ] && [ -e "$icr/Documents" ]; then
         DD_SYNCED=1; DD_SOURCE="Desktop and Documents present in iCloud Drive"
       fi ;;
  esac

  for e in "$HOME/Library/CloudStorage"/* "$HOME/Dropbox" "$HOME"/Dropbox\ \(* "$HOME/OneDrive"; do
    [ -e "$e" ] && CLOUD_ROOTS+="$e"$'\n'
  done

  progress "sizing Desktop, Documents, Downloads, Pictures…"
  for name in Desktop Documents Downloads Pictures; do
    [ -e "$HOME/$name" ] || continue
    if [ -L "$HOME/$name" ]; then HOME_ROWS+="L"$'\t'"0"$'\t'"$name"$'\n'; continue; fi
    du_size "$HOME/$name"
    HOME_ROWS+="$DU_KB"$'\t'"$DU_DENIED"$'\t'"$name"$'\n'
  done

  while IFS= read -r e; do
    [ -n "$e" ] || continue
    du_size "$e"
    PHOTO_ROWS+="$DU_KB"$'\t'"$DU_DENIED"$'\t'"$e"$'\n'
  done < <(find "$HOME/Pictures" -maxdepth 2 -name '*.photoslibrary' -prune -print 2>/dev/null)

  progress "sizing app containers, Mail, Messages…"
  for e in "$HOME/Library/Containers"/* "$HOME/Library/Group Containers"/*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    du_size "$e"
    CONT_ROWS+="$DU_KB"$'\t'"$DU_DENIED"$'\t'"${e##*/}"$'\n'
  done
  if [ -d "$HOME/Library/Mail" ]; then du_size "$HOME/Library/Mail"; MAIL_KB="$DU_KB"; MAIL_DENIED="$DU_DENIED"; fi
  if [ -d "$HOME/Library/Messages" ]; then du_size "$HOME/Library/Messages"; MSG_KB="$DU_KB"; MSG_DENIED="$DU_DENIED"; fi

  progress "looking for git repos in Desktop, Documents, Downloads…"
  for name in Desktop Documents Downloads; do
    [ -d "$HOME/$name" ] && collect_git_walk "$HOME/$name" 4
  done
  PROTECTED_DONE=1
  progress "protected step done."
}

# ── section 4: local-only data ─────────────────────────────────────────────

repo_has_under() { # repo_has_under DIR → 0 if any discovered repo lives at/below DIR
  case $'\n'"$REPOS" in *$'\n'"$1"$'\n'*|*$'\n'"$1"/*) return 0 ;; esac
  return 1
}

section_local_data() {
  emit "## 4. Data that exists only on this Mac"
  blank

  # 4a iCloud
  emit "### iCloud"
  blank
  if [ "$ICLOUD_SIGNED_IN" = 1 ]; then
    if icloud_service MOBILE_DOCUMENTS || [ "$ICLOUD_ROOT_EXISTS" = 1 ]; then finding GREEN "iCloud Drive is on."
    else finding AMBER "Signed in to iCloud, but iCloud Drive is not reported as on."; fi
  else
    finding AMBER "Not signed in to iCloud (or the account state is unreadable) — nothing on this Mac is synced by iCloud."
  fi
  if [ "$DD_SYNCED" = 1 ]; then
    finding GREEN "Desktop & Documents sync to iCloud ($DD_SOURCE). Upload currency is not verifiable from the CLI — let the Finder sidebar finish uploading."
  elif [ "$PROTECTED_DONE" = 1 ]; then
    emit "- Desktop & Documents are **not** iCloud-synced — their sizes below are RED."
  else
    emit "- Desktop & Documents iCloud sync not confirmed from account state; deeper check skipped (--skip-protected)."
  fi
  blank

  # 4b cloud roots
  emit "### Cloud-synced folders (excluded from local sizing)"
  blank
  local e any=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue; any=1
    finding GREEN "Cloud-backed: \`$(tilde_path "$e")\` (sync currency not verified — check the provider's status menu)."
  done < <(printf '%s' "$CLOUD_ROOTS")
  if [ "$PROTECTED_DONE" = 0 ]; then
    local app
    for app in Dropbox "Google Drive" OneDrive "Box" ; do
      [ -d "/Applications/$app.app" ] && { any=1; emit "- $app is installed (roots not listed: --skip-protected)."; }
    done
  fi
  [ "$any" = 1 ] || emit "- none found"
  blank

  # 4c home folders
  emit "### Home folders (top 25 by size; Library, .Trash and cloud roots excluded)"
  blank
  emit "~/Downloads is never synced by any provider."
  blank
  local rows kb den name kind lvl note has dlabel shown=0 small_other="" repo_dirs="" n_repo_dirs=0
  # Pictures: the Photos libraries are judged separately, so judge the rest.
  local pic_lib_kb=0
  while IFS=$'\t' read -r kb den e; do
    [ -n "$kb" ] && [ "$kb" != "?" ] && pic_lib_kb=$((pic_lib_kb + kb))
  done < <(printf '%s' "$PHOTO_ROWS")
  rows="$(printf '%s' "$HOME_ROWS" | awk -F'\t' 'BEGIN{OFS="\t"} { k=$1; s=(k ~ /^[0-9]+$/) ? k : -1; print s, $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)"
  emit "| Folder | Size | Status |"
  emit "|---|---|---|"
  while IFS=$'\t' read -r kb den name; do
    [ -n "$name" ] || continue
    kind="$(home_entry_kind "$name")"
    case "$kb" in
      L|M)
        shown=$((shown + 1))
        [ "$shown" -le 25 ] && emit "| ~/$(md_cell "$name") | $( [ "$kb" = L ] && printf 'symlink' || printf 'mount point') | not followed |"
        continue ;;
    esac
    has=0; repo_has_under "$HOME/$name" && has=1
    local judge_kb="$kb"
    if [ "$name" = Pictures ] && [ "$kb" != "?" ]; then
      judge_kb=$((kb - pic_lib_kb)); [ "$judge_kb" -lt 0 ] && judge_kb=0
    fi
    lvl="$(home_entry_level "$kind" "$judge_kb" "$DD_SYNCED" "$has" "$name" "$den")"
    note="${lvl#*$'\t'}"; lvl="${lvl%%$'\t'*}"
    [ "$name" = Pictures ] && [ "$pic_lib_kb" -gt 0 ] && note="$note (excl. Photos libraries)"
    dlabel="$(size_label "$kb" "$den")"
    shown=$((shown + 1))
    if [ "$shown" -le 25 ]; then
      case "$lvl" in
        NONE|REPO) emit "| ~/$(md_cell "$name") | $dlabel | – $(md_cell "$note") |" ;;
        *) emit "| ~/$(md_cell "$name") | $dlabel | $lvl $(md_cell "$note") |" ;;
      esac
    fi
    case "$lvl" in
      RED|AMBER)
        FINDINGS_DEFERRED+="$lvl"$'\t'"\`~/$name\` — $dlabel — $note"$'\n'
        plan_path "$lvl" "$kb" "$HOME/$name" "~/$name" ;;
      REPO)
        n_repo_dirs=$((n_repo_dirs + 1))
        if [ "$n_repo_dirs" -le 8 ]; then repo_dirs+="~/$name ($dlabel), "
        elif [ "$n_repo_dirs" = 9 ]; then repo_dirs+="…, "; fi ;;
    esac
    [ "$kind" = other ] && [ "$lvl" = NONE ] && [ "$kb" -ge "$SMALL_KB" ] && small_other+="$name "
  done < <(printf '%s\n' "$rows")
  blank
  flush_deferred
  if [ "$n_repo_dirs" -gt 0 ]; then
    finding AMBER "$n_repo_dirs home folder(s) hold git repos; untracked and ignored files there (.env, local data, build output) are not in git: ${repo_dirs%, }."
  fi
  if [ "$PROTECTED_DONE" = 0 ]; then
    finding AMBER "Desktop, Documents, Downloads and Pictures were not measured (--skip-protected)$( [ "$DD_SYNCED" = 1 ] && printf ' — Desktop & Documents are iCloud-synced; Downloads and Pictures are not')."
  fi
  [ -n "$small_other" ] && emit "- Smaller local-only folders (1–100 MB, not individually flagged): ${small_other% }"
  blank

  # 4d Photos
  emit "### Photos"
  blank
  if [ "$PROTECTED_DONE" = 1 ]; then
    local any_lib=0
    while IFS=$'\t' read -r kb den e; do
      [ -n "$e" ] || continue; any_lib=1
      emit "- \`$(tilde_path "$e")\`: $(size_label "$kb" "$den")"
    done < <(printf '%s' "$PHOTO_ROWS")
    [ "$any_lib" = 1 ] || emit "- no *.photoslibrary under ~/Pictures"
    if [ "$any_lib" = 1 ]; then
      if icloud_service PHOTO_STREAM || icloud_service PHOTOS; then
        finding GREEN "iCloud Photos reported on by the iCloud account (best effort). With \"Optimize Mac Storage\" the originals are in iCloud; check Photos → Settings → iCloud shows no pending uploads."
      else
        finding AMBER "Photos library present, iCloud Photos not confirmed — check Photos → Settings → iCloud, or copy the library."
        while IFS=$'\t' read -r kb den e; do
          [ -n "$e" ] && plan_path AMBER "$kb" "$e" "Photos library"
        done < <(printf '%s' "$PHOTO_ROWS")
      fi
    fi
  else
    if icloud_service PHOTO_STREAM || icloud_service PHOTOS; then
      finding GREEN "iCloud Photos reported on by the iCloud account (best effort); library not sized (--skip-protected)."
    else
      finding AMBER "iCloud Photos not confirmed and the library was not sized (--skip-protected)."
    fi
  fi
  blank

  # 4e Messages + Mail
  emit "### Messages & Mail"
  blank
  local msz="not measured (--skip-protected)"
  [ "$PROTECTED_DONE" = 1 ] && msz="$( [ -n "$MSG_KB" ] && size_label "$MSG_KB" "$MSG_DENIED" || printf 'absent')"
  if icloud_service MESSAGES; then
    finding GREEN "Messages in iCloud reported on (best effort). ~/Library/Messages: $msz."
  else
    finding AMBER "Messages in iCloud not confirmed (Messages → Settings → iMessage). ~/Library/Messages: $msz."
    [ "$PROTECTED_DONE" = 1 ] && [ -n "$MSG_KB" ] && plan_path AMBER "$MSG_KB" "$HOME/Library/Messages" "Messages history"
  fi
  if [ "$PROTECTED_DONE" = 1 ] && [ -n "$MAIL_KB" ]; then
    if [ "$MAIL_KB" = "?" ] || [ "$MAIL_DENIED" = 1 ]; then
      finding AMBER "Local Mail store $(size_label "$MAIL_KB" "$MAIL_DENIED") — give the terminal Full Disk Access, or check Mail for \"On My Mac\" mailboxes by hand."
    elif [ "$MAIL_KB" -ge "$BIG_KB" ]; then
      finding AMBER "Local Mail store $(size_label "$MAIL_KB" "$MAIL_DENIED") — IMAP/iCloud mail re-downloads, \"On My Mac\" mailboxes do not."
      plan_path AMBER "$MAIL_KB" "$HOME/Library/Mail" "Mail store"
    else
      emit "- ~/Library/Mail: $(size_label "$MAIL_KB" "$MAIL_DENIED")"
    fi
  fi
  if [ "$PROTECTED_DONE" = 1 ] && [ -n "$MSG_KB" ] && icloud_service MESSAGES && { [ "$MSG_KB" = "?" ] || [ "$MSG_DENIED" = 1 ]; }; then
    emit "- ~/Library/Messages could not be fully read; Messages in iCloud covers it once it has finished syncing."
  fi
  if [ "$PROTECTED_DONE" = 0 ]; then
    finding AMBER "Mail and app containers were not inspected (--skip-protected)."
  fi
  blank

  section_app_data
  section_git
  section_secrets
}

FINDINGS_DEFERRED=""
flush_deferred() {
  local lvl txt
  while IFS=$'\t' read -r lvl txt; do
    [ -n "$lvl" ] && finding "$lvl" "$txt"
  done < <(printf '%s' "$FINDINGS_DEFERRED")
  FINDINGS_DEFERRED=""
}

appdata_table() { # appdata_table ROWS TITLE
  local rows="$1" kb den name flag lvl note n=0
  emit "| $2 | Size | Note |"
  emit "|---|---|---|"
  while IFS=$'\t' read -r kb den name; do
    [ -n "$name" ] || continue
    n=$((n + 1)); [ "$n" -le 20 ] || break
    flag="$(appdata_flag "$name")"; note="${flag#*$'\t'}"; [ -n "$flag" ] || note=""
    emit "| $(md_cell "$name") | $(size_label "$kb" "$den") | $(md_cell "$note") |"
  done < <(printf '%s' "$rows" | awk -F'\t' 'BEGIN{OFS="\t"} { s=($1 ~ /^[0-9]+$/) ? $1 : -1; print s, $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)
  blank
  # Findings for every flagged entry, not just the top 20. Unrecognised data
  # is never silently fine either: big third-party folders and folders that
  # could not be (fully) read are each folded into one AMBER.
  local unread=0 unread_names="" big=0 big_names=""
  while IFS=$'\t' read -r kb den name; do
    [ -n "$name" ] || continue
    flag="$(appdata_flag "$name")"
    if [ -z "$flag" ]; then
      if [ "$kb" = "?" ] || [ "$den" = 1 ]; then
        unread=$((unread + 1)); [ "$unread" -le 5 ] && unread_names+="$name, "
      elif [ "$kb" -ge "$BIG_KB" ]; then
        # macOS's own folders are system state, not something to carry over.
        case "$name" in com.apple.*|group.com.apple.*) ;;
          *) big=$((big + 1)); [ "$big" -le 8 ] && big_names+="$name ($(human_kb "$kb")), " ;;
        esac
      fi
      continue
    fi
    lvl="${flag%%$'\t'*}"; note="${flag#*$'\t'}"
    if [ "$lvl" = VM ]; then
      if [ "$kb" != "?" ] && [ "$kb" -ge "$BIG_KB" ]; then lvl=RED
      elif [ "$kb" = "?" ] || [ "$den" = 1 ]; then lvl=AMBER
      else lvl=NONE; fi
    fi
    [ "$lvl" = NONE ] || finding "$lvl" "$name: $note ($(size_label "$kb" "$den"))."
    if [ "$lvl" = RED ]; then
      local src="$HOME/Library/Application Support/$name"
      case "$2" in *Containers*)
        src="$HOME/Library/Containers/$name"
        [ -e "$src" ] || src="$HOME/Library/Group Containers/$name" ;;
      esac
      plan_path RED "$kb" "$src" "$name app data"
    fi
  done < <(printf '%s' "$rows" | awk -F'\t' 'BEGIN{OFS="\t"} { s=($1 ~ /^[0-9]+$/) ? $1 : -1; print s, $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)
  if [ "$big" -gt 0 ]; then
    finding AMBER "$big app-data folder(s) of 100 MB+ under $2 that a reinstall will not restore — confirm each app syncs or is disposable: ${big_names%, }$( [ "$big" -gt 8 ] && printf ', …')."
  fi
  if [ "$unread" -gt 0 ]; then
    finding AMBER "$unread folder(s) under $2 could not be fully read (Full Disk Access / timeout), e.g. ${unread_names%, }$( [ "$unread" -gt 5 ] && printf ', …')."
  fi
}

section_app_data() {
  emit "### App data a reinstall does not restore"
  blank
  emit "Most apps sync or are disposable; check anything large you care about."
  blank
  appdata_table "$APPSUP_ROWS" "~/Library/Application Support"
  if [ "$PROTECTED_DONE" = 1 ]; then
    appdata_table "$CONT_ROWS" "~/Library/(Group) Containers"
  else
    local app
    for app in UTM WhatsApp "Docker" OrbStack "Parallels Desktop" "VMware Fusion"; do
      [ -d "/Applications/$app.app" ] || continue
      case "$app" in
        UTM|"Parallels Desktop"|"VMware Fusion") finding AMBER "$app installed — its VMs live in app containers, not measured (--skip-protected)." ;;
        Docker|OrbStack) finding AMBER "$app installed — container volumes are local only, not measured (--skip-protected)." ;;
        WhatsApp) finding AMBER "WhatsApp Desktop installed — history lives on the phone; re-link after the wipe." ;;
      esac
    done
  fi

  # Obsidian vaults: judged from the path string only (no stat), so a vault
  # inside a protected folder is not touched outside the protected step.
  local oj="$HOME/Library/Application Support/obsidian/obsidian.json" vp
  if [ -r "$oj" ]; then
    while IFS= read -r vp; do
      [ -n "$vp" ] || continue
      if is_cloud_path "$vp" "$DD_SYNCED"; then
        finding GREEN "Obsidian vault in a synced location: \`$(tilde_path "$vp")\`."
      elif repo_has_under "$vp"; then
        finding AMBER "Obsidian vault is a git repo (see Git): \`$(tilde_path "$vp")\`."
      else
        finding RED "Obsidian vault outside any cloud root: \`$(tilde_path "$vp")\` (unless you pay for Obsidian Sync)."
        plan_path RED "?" "$vp" "Obsidian vault"
      fi
    done < <(jxa_json 'var v = d.vaults || {}; return Object.keys(v).map(function (k) { return v[k].path; }).join("\n");' < "$oj")
  fi
  blank
}

section_git() {
  emit "### Git repositories"
  blank
  local nrepos at=0 r out dirty unpushed noremote stashes common shared pass rows="" seen=$'\n'
  nrepos="$(printf '%s' "$REPOS" | grep -c . )"
  if [ "$WALK_TIMED_OUT" = 1 ]; then
    finding AMBER "Repo discovery hit its ${FIND_TIMEOUT}s limit — repositories may be missing from this list; check your code folders by hand."
  fi
  if [ -n "$WALK_UNREADABLE" ]; then
    local nun shown_un="" u i=0
    nun="$(printf '%s' "$WALK_UNREADABLE" | grep -c .)"
    while IFS= read -r u; do
      [ -n "$u" ] || continue; i=$((i + 1)); [ "$i" -le 5 ] || break
      shown_un+="\`$(tilde_path "$u")\` "
    done < <(printf '%s' "$WALK_UNREADABLE")
    finding AMBER "Repo discovery could not read $nun folder(s), so repos inside them were not checked: ${shown_un% }$( [ "$nun" -gt 5 ] && printf ' …')"
  fi
  if [ "$nrepos" -eq 0 ]; then
    emit "- no repositories found under ~ (depth 5; Library, caches, node_modules, cloud roots pruned)"; blank; return
  fi
  if [ "$GIT_OK" = 0 ]; then
    finding AMBER "$nrepos repo(s) found but git is not usable here (no developer tools) — their state is unknown."
    blank; return
  fi
  progress "checking $nrepos git repos…"
  # Branches, remotes and stashes belong to the repository, not to a worktree,
  # so they are counted once — at the main checkout (pass 1: .git is a dir) —
  # and linked worktrees (pass 2: .git is a file) are judged on dirt only.
  for pass in dir file; do
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      if [ -d "$r/.git" ]; then [ "$pass" = dir ] || continue
      else [ "$pass" = file ] || continue; fi
      if out="$(g "$r" status --porcelain --untracked-files=normal)"; then
        dirty="$(printf '%s' "$out" | grep -c .)"
      else
        dirty="?"
      fi
      common="$(g "$r" rev-parse --path-format=absolute --git-common-dir)"
      shared=0
      if [ -n "$common" ]; then
        case "$seen" in *$'\n'"$common"$'\n'*) shared=1 ;; *) seen+="$common"$'\n' ;; esac
      fi
      if [ "$shared" = 1 ]; then
        # Branches/tags were counted at the main checkout; only a detached
        # HEAD in this worktree can hold commits that nothing else reaches.
        noremote=0; stashes=0
        unpushed="$(g "$r" rev-list HEAD --not --branches --tags --remotes --count)"
        [ -n "$unpushed" ] || unpushed=0
      else
        # HEAD covers a detached checkout; tags cover tag-only commits.
        local refs="--branches --tags"
        [ -n "$(g "$r" rev-parse -q --verify HEAD)" ] && refs="HEAD $refs"
        # shellcheck disable=SC2086  # $refs is a list of rev-list arguments
        if [ -n "$(g "$r" remote)" ]; then
          noremote=0
          unpushed="$(g "$r" rev-list $refs --not --remotes --count)"
        else
          noremote=1; unpushed="$(g "$r" rev-list $refs --count)"
        fi
        stashes="$(g "$r" rev-list --walk-reflogs --count refs/stash)"
        [ -n "$unpushed" ] || unpushed="?"
        [ -n "$stashes" ] || stashes=0
      fi
      if git_at_risk "$dirty" "$unpushed" "$noremote" "$stashes"; then
        at=$((at + 1))
        plan_path RED "?" "$r" "git repo with unpushed/uncommitted work"
        if [ "$shared" = 1 ]; then
          rows+="| \`$(md_cell "$(tilde_path "$r")")\` | $dirty | $unpushed (worktree; branches counted at main checkout) | – | – |"$'\n'
        else
          rows+="| \`$(md_cell "$(tilde_path "$r")")\` | $dirty | $unpushed | $( [ "$noremote" = 1 ] && printf 'yes' || printf 'no') | $stashes |"$'\n'
        fi
      fi
    done < <(printf '%s' "$REPOS")
  done
  if [ "$at" -gt 0 ]; then
    finding RED "$at of $nrepos git repo(s) hold work that exists only here (dirty, unpushed, no remote, stashed, or unreadable)."
    blank
    emit "| Repo | Dirty files | Unpushed commits | No remote | Stashes |"
    emit "|---|---|---|---|---|"
    BODY+="$rows"
  else
    finding GREEN "All $nrepos git repo(s) are clean and pushed."
  fi
  blank
  emit "Ignored files (\`.env\`, local databases, build outputs) are never in git — copy anything you need."
  blank
}

section_secrets() {
  emit "### Secrets (names and counts only)"
  blank
  local f first keys="" nkeys=0
  for f in "$HOME/.ssh"/*; do
    [ -f "$f" ] || continue
    first=""; IFS= read -r first < "$f" 2>/dev/null
    case "$first" in *"PRIVATE KEY"*) keys+="${f##*/} "; nkeys=$((nkeys + 1)) ;; esac
  done
  if [ "$nkeys" -gt 0 ]; then
    finding AMBER "$nkeys SSH private key(s) in ~/.ssh: ${keys% } — escrow or re-key before the wipe."
  else
    emit "- no SSH private keys in ~/.ssh"
  fi

  if command -v gpg >/dev/null 2>&1 && [ -d "$HOME/.gnupg" ]; then
    local fprs
    fprs="$(run_timeout 15 gpg --batch --no-auto-check-trustdb --list-secret-keys --with-colons 2>/dev/null | parse_gpg_fprs | tr '\n' ' ')"
    if [ -n "$fprs" ]; then
      finding AMBER "GPG secret key(s), fingerprints: ${fprs% } — escrow secret keys + ownertrust."
    else
      emit "- no GPG secret keys"
    fi
  elif [ -d "$HOME/.gnupg/private-keys-v1.d" ]; then
    local n; n="$(find "$HOME/.gnupg/private-keys-v1.d" -name '*.key' 2>/dev/null | grep -c .)"
    [ "$n" -gt 0 ] && finding AMBER "$n GPG private key file(s) in ~/.gnupg (gpg not on PATH to list fingerprints)."
  fi

  local age="$HOME/.config/sops/age/keys.txt"
  if [ -f "$age" ]; then
    local nk pubs
    nk="$(grep -c '^AGE-SECRET-KEY-' "$age" 2>/dev/null)"
    pubs="$(sed -n 's/^# public key: //p' "$age" 2>/dev/null | tr '\n' ' ')"
    finding AMBER "sops age key file present (${nk:-?} key(s); public: ${pubs% }) — if this is the only copy, sops files encrypted to it become undecryptable."
  fi

  local cred found=""
  for cred in .aws/credentials .config/gh/hosts.yml .kube/config .netrc .git-credentials .npmrc .docker/config.json \
              .pypirc .cargo/credentials.toml .terraform.d/credentials.tfrc.json .config/gcloud .azure; do
    [ -e "$HOME/$cred" ] && found+="~/$cred "
  done
  [ -n "$found" ] && finding AMBER "Credential files present (re-auth after the wipe, or escrow): ${found% }"

  local nenv=0 inrepo=0 envf r
  while IFS= read -r envf; do
    [ -n "$envf" ] || continue
    nenv=$((nenv + 1))
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$envf" in "$r"/*) inrepo=$((inrepo + 1)); break ;; esac
    done < <(printf '%s' "$REPOS")
  done < <(printf '%s' "$ENV_FILES")
  if [ "$nenv" -gt 0 ]; then
    finding AMBER "$nenv .env file(s) found ($inrepo inside git repos) — values are never in git; escrow with \`escrow-secrets-1password.sh --env\`."
  fi
  blank
  emit "Remediation: \`scripts/escrow-secrets-1password.sh\` in rh7/rh-device-management (dry-run by default; needs an interactive \`op\` session)."
  blank
}

# ── section 5: backups & pre-erase ─────────────────────────────────────────

section_backups() {
  if [ "$PART" = user ]; then emit "## 8. Before you erase (this account)"
  else emit "## 8. Backups & before you erase"; fi
  blank
  progress "checking Time Machine, FileVault, Find My, browsers…"
  if [ "$PART" != user ]; then
  local di names latest
  di="$(run_timeout 10 tmutil destinationinfo 2>/dev/null)"
  names="$(printf '%s\n' "$di" | sed -n -E 's/^Name[[:space:]]*:[[:space:]]*//p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "$names" ]; then
    latest="$(jxa_plist /Library/Preferences/com.apple.TimeMachine.plist '
      var m = 0;
      (d.Destinations || []).forEach(function (x) {
        (x.SnapshotDates || []).forEach(function (t) { if (t && t.getTime() > m) m = t.getTime(); });
      });
      return m ? new Date(m).toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC") : "";')"
    if [ -z "$latest" ]; then
      latest="$(run_timeout 15 tmutil latestbackup 2>/dev/null | sed -n -E 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}).*/\1/p' | tail -1)"
    fi
    if [ -n "$latest" ]; then
      finding GREEN "Time Machine → $names; latest backup: $latest. Run one more right before erasing."
    else
      finding AMBER "Time Machine → $names; latest backup date unknown (\`tmutil latestbackup\` needs the disk attached and/or Full Disk Access)."
    fi
  else
    finding AMBER "No Time Machine destination. A one-off backup to an external disk is cheap insurance before erasing."
  fi

  local fv; fv="$(fdesetup status 2>/dev/null | head -1)"; fv="${fv%.}"
  emit "- FileVault: ${fv:-status unknown}. (Personal recovery-key status needs root: \`sudo fdesetup haspersonalrecoverykey\` — irrelevant once you erase.)"
  fi

  if [ "$PART" != system ]; then
  if icloud_service FIND_MY_MAC; then
    finding AMBER "Find My Mac is ON — sign out of iCloud (System Settings → Apple Account → Sign Out) before \"Erase All Content and Settings\", or the Mac stays Activation-Locked to your Apple Account."
  elif [ "$ICLOUD_SIGNED_IN" = 1 ]; then
    emit "- Find My Mac: not reported on (best effort). Still sign out of iCloud before erasing."
  fi
  if icloud_service KEYCHAIN_SYNC; then
    finding GREEN "iCloud Keychain is on — passwords/passkeys sync."
  elif [ "$ICLOUD_SIGNED_IN" = 1 ]; then
    finding AMBER "iCloud Keychain not reported on — passwords saved only in the local login keychain will be lost."
  fi
  fi
  blank

  if [ "$PART" != system ]; then
  emit "### Browsers"
  blank
  local as="$HOME/Library/Application Support" b dir prof signed total
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    dir="$as/${b#*:}"
    [ -d "$dir" ] || continue
    total=0; signed=0
    for prof in "$dir/Default" "$dir"/Profile\ *; do
      [ -f "$prof/Preferences" ] || continue
      total=$((total + 1))
      grep -q '"account_info":\[{' "$prof/Preferences" 2>/dev/null && signed=$((signed + 1))
    done
    [ "$total" -gt 0 ] || continue
    if [ "$signed" -eq "$total" ]; then
      finding AMBER "${b%%:*}: $total profile(s) signed in to an account — confirm Sync is actually on in each (signed in ≠ syncing)."
    else
      finding AMBER "${b%%:*}: $((total - signed)) of $total profile(s) not signed in — bookmarks/passwords/extensions there are local only."
    fi
  done < <(printf '%s\n' "$CHROMIUM_BROWSERS")
  if [ -d "$as/Firefox/Profiles" ]; then
    total=0; signed=0
    for prof in "$as/Firefox/Profiles"/*; do
      [ -d "$prof" ] || continue
      total=$((total + 1)); [ -f "$prof/signedInUser.json" ] && signed=$((signed + 1))
    done
    if [ "$total" -gt 0 ] && [ "$signed" -lt "$total" ]; then
      finding AMBER "Firefox: $((total - signed)) of $total profile(s) not signed in to a Firefox account."
    elif [ "$total" -gt 0 ]; then
      finding AMBER "Firefox: $total profile(s) signed in — confirm Sync is on in each (signed in ≠ syncing)."
    fi
  fi
  if [ -d "$HOME/Library/Safari" ]; then
    if icloud_service BOOKMARKS; then emit "- Safari: syncs via iCloud (Safari is on in the iCloud account)."
    else finding AMBER "Safari: iCloud Safari sync not reported on — bookmarks/reading list may be local only."; fi
  fi
  blank
  fi

  emit "### Commonly forgotten"
  blank
  local nf nla cron hist
  if [ "$PART" != system ]; then
  nf="$(find "$HOME/Library/Fonts" -maxdepth 1 -type f 2>/dev/null | grep -c .)"
  [ "$nf" -gt 0 ] && finding AMBER "$nf user-installed font file(s) in ~/Library/Fonts."
  nla="$(find "$HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' ! -name 'com.apple.*' 2>/dev/null | grep -c .)"
  [ "$nla" -gt 0 ] && emit "- $nla user LaunchAgent(s) in ~/Library/LaunchAgents (scheduled jobs; recreate or declare in the flake)."
  cron="$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -c .)"
  [ "$cron" -gt 0 ] && finding AMBER "$cron crontab line(s) — \`crontab -l\` and save them."
  hist=""
  for f in .zsh_history .bash_history .local/share/fish/fish_history .local/share/atuin; do
    [ -e "$HOME/$f" ] && hist+="~/$f "
  done
  [ -n "$hist" ] && emit "- Shell history: ${hist% } (copy if you rely on it)."
  emit "- Music/TV: Account → Authorizations → Deauthorize This Computer (5-computer limit)."
  fi
  if [ "$PART" != user ]; then
  if [ -r /etc/hosts ] && [ "$(grep -v -E '^[[:space:]]*(#|$)' /etc/hosts | grep -v -E '[[:space:]](localhost|broadcasthost)$' | grep -c .)" -gt 0 ]; then
    emit "- /etc/hosts has custom entries."
  fi
  if [ "$MANUAL_COUNT" -gt 0 ] || [ "$SETAPP_COUNT" -gt 0 ]; then
    emit "- Licences: collect keys for the manual/Setapp apps above and deactivate seat-limited ones (Adobe, JetBrains, …)."
  fi
  fi
  blank
}

# ── section 5: crypto wallets ──────────────────────────────────────────────

WALLET_ROWS=""      # "NAME\tKEYS\tAPP(0|1)\tKB\tDENIED\tPATH" (KB "-" = not sized)
WALLET_EXT_ROWS=""  # "NAME\tBROWSER\tPROFILE\tKB\tDENIED\tPATH" (KB "-" = not sized)
collect_wallets() {
  local name keys apps dirs rest a d app path
  WALLET_ROWS=""; WALLET_EXT_ROWS=""
  while IFS='|' read -r name keys apps dirs; do
    [ -n "$name" ] || continue
    app=0; rest="$apps;"
    while [ -n "$rest" ]; do
      a="${rest%%;*}"; rest="${rest#*;}"
      [ -n "$a" ] || continue
      if [ -d "$APPS_DIR/$a" ] || [ -d "$HOME/Applications/$a" ]; then app=1; break; fi
    done
    # Every existing data dir is its own row (e.g. ~/.electrum AND an older
    # Application Support copy): each may hold keys and must reach the plan.
    path=""; rest="$dirs;"
    while [ -n "$rest" ]; do
      d="${rest%%;*}"; rest="${rest#*;}"
      [ -n "$d" ] && [ -d "$HOME/$d" ] && [ ! -L "$HOME/$d" ] || continue
      path="$HOME/$d"
      du_size "$path"
      WALLET_ROWS+="$name"$'\t'"$keys"$'\t'"$app"$'\t'"$DU_KB"$'\t'"$DU_DENIED"$'\t'"$path"$'\n'
    done
    # App installed, no data here: "-" = not sized (an empty field would
    # collapse in a tab read).
    [ "$app" = 1 ] && [ -z "$path" ] && WALLET_ROWS+="$name"$'\t'"$keys"$'\t'"1"$'\t'"-"$'\t'"0"$'\t'$'\n'
  done < <(printf '%s\n' "$WALLET_APPS")

  local as="$HOME/Library/Application Support" b dir prof id ename les
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    dir="$as/${b#*:}"
    [ -d "$dir" ] || continue
    for prof in "$dir/Default" "$dir"/Profile\ *; do
      [ -d "$prof" ] || continue
      while IFS='|' read -r id ename; do
        [ -n "$id" ] || continue
        les="$prof/Local Extension Settings/$id"
        if [ -d "$prof/Extensions/$id" ] || [ -d "$les" ]; then
          DU_KB="-"; DU_DENIED=0
          [ -d "$les" ] && du_size "$les"
          WALLET_EXT_ROWS+="$ename"$'\t'"${b%%:*}"$'\t'"${prof##*/}"$'\t'"$DU_KB"$'\t'"$DU_DENIED"$'\t'"$les"$'\n'
        fi
      done < <(printf '%s\n' "$WALLET_EXTENSIONS")
    done
  done < <(printf '%s\n' "$CHROMIUM_BROWSERS")
  for prof in "$as/Firefox/Profiles"/*; do
    [ -e "$prof/extensions/webextension@metamask.io.xpi" ] || continue
    WALLET_EXT_ROWS+="MetaMask"$'\t'"Firefox"$'\t'"${prof##*/}"$'\t'"-"$'\t'"0"$'\t'"$prof"$'\n'
  done
}

section_wallets() {
  emit "## 5. Crypto wallets"
  blank
  progress "looking for crypto wallets (presence and folder size only)…"
  SIZE_DEADLINE=$((SECONDS + CLEANUP_BUDGET))
  collect_wallets
  if [ -z "$WALLET_ROWS$WALLET_EXT_ROWS" ]; then
    emit "- No known wallet app, wallet data folder or wallet browser extension (checked: Exodus, Electrum, Ledger Live, MyCrypto, KeepKey, Cypherock, Atomic Wallet; MetaMask, Phantom, Coinbase Wallet and Rabby in Chromium browsers; MetaMask in Firefox)."
    blank; return
  fi
  emit "Wallet files are never opened — only whether they exist and how big the folder is."
  blank
  emit "| Wallet | App installed | Data in this account | Size | Keys |"
  emit "|---|---|---|---|---|"
  local name keys app kb den path here="" apponly="" kdesc browser profile
  while IFS=$'\t' read -r name keys app kb den path; do
    [ -n "$name" ] || continue
    if [ "$keys" = local ]; then kdesc="may be stored in these files (encrypted wallet)"
    else kdesc="on the hardware device; this data is a cache"; fi
    if [ -n "$path" ]; then
      case ", $here" in *", $name, "*) ;; *) here+="$name, " ;; esac
      emit "| $name | $( [ "$app" = 1 ] && printf yes || printf no) | \`$(md_cell "$(tilde_path "$path")")\` | $(size_label "$kb" "$den") | $kdesc |"
      [ "$keys" = local ] && plan_path RED "$kb" "$path" "$name wallet data"
    else
      apponly+="$name, "
      emit "| $name | yes | – | – | $kdesc |"
    fi
  done < <(printf '%s' "$WALLET_ROWS")
  while IFS=$'\t' read -r name browser profile kb den path; do
    [ -n "$name" ] || continue
    here+="$name ($browser · $profile), "
    emit "| $name extension | $browser | profile \`$(md_cell "$profile")\` | $( [ "$kb" != - ] && size_label "$kb" "$den" || printf '–') | in the browser profile (encrypted vault) |"
    [ "$kb" = - ] && kb="?"
    [ -d "$path" ] && plan_path RED "$kb" "$path" "$name extension data ($browser $profile)"
  done < <(printf '%s' "$WALLET_EXT_ROWS")
  blank
  if [ -n "$here" ]; then
    finding RED "Crypto wallets in this account (${here%, }): confirm the seed phrase / recovery for each wallet is stored offline before any change; local wallet files may hold keys."
  fi
  if [ -n "$apponly" ]; then
    if [ "$PART" = all ]; then
      finding AMBER "Wallet app(s) installed with no data in this account: ${apponly%, } — another account may use them; run with --all-users (sudo) to check every account."
    else
      emit "- Installed, but no data in this account: ${apponly%, }."
    fi
  fi
  blank
}

# ── section 6: data cleanup candidates ─────────────────────────────────────

CLEAN_ROWS=""   # "CLASS\tKB\tDENIED\tLABEL\tPATH\tNOTE"
clean_add() { # clean_add KIND LABEL PATH [KB DENIED [NOTE-PREFIX]]
  local c note kb den
  if [ $# -ge 5 ]; then kb="$4"; den="$5"; else du_size "$3"; kb="$DU_KB"; den="$DU_DENIED"; fi
  c="$(cleanup_class "$1")"; note="${c#*$'\t'}"; c="${c%%$'\t'*}"
  [ -n "${6:-}" ] && note="$6 — $note"
  CLEAN_ROWS+="$c"$'\t'"$kb"$'\t'"$den"$'\t'"$2"$'\t'"$3"$'\t'"$note"$'\n'
}

home_row() { # home_row NAME → "KB<TAB>DENIED" from HOME_ROWS, or nothing
  printf '%s' "$HOME_ROWS" | awk -F'\t' -v n="$1" '$3 == n { print $1 "\t" $2; exit }'
}

dir_stats() { # dir_stats DIR → "COUNT<TAB>OLDEST<TAB>NEWEST" over top-level entries (epoch mtimes)
  find "$1" -mindepth 1 -maxdepth 1 ! -name .DS_Store ! -name .localized -exec stat -f '%m' {} + 2>/dev/null \
    | awk 'NR == 1 { mn = $1; mx = $1 } { if ($1 < mn) mn = $1; if ($1 > mx) mx = $1; n++ } END { printf "%d\t%s\t%s\n", n, mn, mx }'
}

node_modules_total() { # → "COUNT<TAB>KB<TAB>TIMED_OUT(0|1)"
  local out rc line total=0 n=0 to=0
  local -a dirs=() prot=()
  [ "$SKIP_PROTECTED" = 1 ] && prot=(-o -path "$HOME/Desktop" -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures")
  out="$(run_timeout "$FIND_TIMEOUT" find "$HOME" -xdev -maxdepth 8 \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" ${prot[@]+"${prot[@]}"} -o -name '*.photoslibrary' -o -name '*.app' \
       -o -name Dropbox -o -name 'Dropbox (*' -o -name 'OneDrive*' -o -name 'Google Drive*' -o -name 'Creative Cloud Files*' \) -prune \
    -o -type d -name node_modules -print -prune 2>/dev/null)"
  rc=$?; [ "$rc" = 124 ] && to=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    dirs+=("$line"); n=$((n + 1))
  done < <(printf '%s\n' "$out")
  if [ "$n" -gt 0 ]; then
    total="$(run_timeout 60 du -skc "${dirs[@]}" 2>/dev/null | tail -1)"; total="${total%%[!0-9]*}"
    [ -n "$total" ] || total="?"
  fi
  printf '%s\t%s\t%s\n' "$n" "$total" "$to"
}

# iPhone/iPad backups: AMBER, never "cleanup" — the only copy of an old phone.
device_backups() {
  local mb="$HOME/Library/Application Support/MobileSync/Backup" n=0 newest="" m e
  [ -d "$mb" ] || return 0
  if ! ls -A "$mb" >/dev/null 2>&1; then
    finding AMBER "iPhone/iPad backup folder exists but could not be read (Full Disk Access) — check Finder → your device → Manage Backups; a local backup may be the ONLY copy of an old phone."
    plan_path AMBER "?" "$mb" "iPhone/iPad backups"
    return 0
  fi
  for e in "$mb"/*; do
    [ -d "$e" ] || continue
    n=$((n + 1))
    m="$(stat -f %m "$e" 2>/dev/null)"
    [ -n "$m" ] && { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; } && newest="$m"
  done
  [ "$n" -gt 0 ] || return 0
  du_size "$mb"
  clean_add mobilesync "iPhone/iPad backups ($n)" "$mb" "$DU_KB" "$DU_DENIED" "newest $(fmt_epoch "$newest")"
  finding AMBER "$n iPhone/iPad backup(s) in ~/Library/Application Support/MobileSync/Backup — $(size_label "$DU_KB" "$DU_DENIED"), newest $(fmt_epoch "$newest"). This may be the ONLY copy of an old phone: copy it off before erasing unless every device it came from still exists and backs up to iCloud."
  plan_path AMBER "$DU_KB" "$mb" "iPhone/iPad backups"
}

collect_cleanup() {
  local d e x r kb den st n old new sz mt p apps_norm="" lib libs nlib
  CLEAN_ROWS=""
  SIZE_DEADLINE=$((SECONDS + CLEANUP_BUDGET))
  [ -d "$HOME/Library/Caches" ] && clean_add caches "App caches" "$HOME/Library/Caches"
  x="$HOME/Library/Developer/Xcode"
  [ -d "$x/DerivedData" ] && clean_add deriveddata "Xcode DerivedData" "$x/DerivedData"
  [ -d "$x/Archives" ] && clean_add xcarchives "Xcode Archives" "$x/Archives"
  for d in "$x"/*DeviceSupport; do [ -d "$d" ] && clean_add devicesupport "Xcode ${d##*/}" "$d"; done
  # Simulator caches rebuild; simulator devices can hold the only copy of
  # test-app data, so they are REVIEW (runtimes live outside ~).
  d="$HOME/Library/Developer/CoreSimulator"
  [ -d "$d/Caches" ] && clean_add sim-caches "Simulator caches" "$d/Caches"
  [ -d "$d/Devices" ] && clean_add sim-devices "Simulator devices" "$d/Devices"
  for d in "$HOME"/miniconda* "$HOME"/anaconda* "$HOME"/miniforge* "$HOME"/mambaforge* "$HOME/.conda" \
           /opt/homebrew/Caskroom/miniconda/base /opt/miniconda3 /opt/anaconda3; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    case "$d" in "$HOME"/*) ;; *) [ -O "$d" ] || continue ;; esac   # a shared install: its owner's report
    for e in "$d/envs"/*; do [ -d "$e" ] && clean_add conda-env "conda env \`${e##*/}\`" "$e"; done
    [ -d "$d/pkgs" ] && clean_add conda-pkgs "conda package cache" "$d/pkgs"
  done
  # Only cargo's download caches are disposable; ~/.cargo also holds config,
  # credentials and installed binaries.
  for d in registry git; do
    [ -d "$HOME/.cargo/$d" ] && clean_add cargo-cache "Rust cargo $d cache" "$HOME/.cargo/$d"
  done
  [ -d "$HOME/.cargo/bin" ] && clean_add cargo-bin "Rust cargo-installed binaries" "$HOME/.cargo/bin"
  [ -d "$HOME/.rustup" ] && [ ! -L "$HOME/.rustup" ] && clean_add rustup "Rust toolchains (rustup)" "$HOME/.rustup"
  [ -d "$HOME/.orbstack" ] && [ ! -L "$HOME/.orbstack" ] && clean_add orbstack "OrbStack" "$HOME/.orbstack"
  progress "looking for node_modules under ~…"
  st="$(node_modules_total)"
  n="${st%%$'\t'*}"; r="${st#*$'\t'}"; kb="${r%%$'\t'*}"
  if [ "${n:-0}" -gt 0 ]; then
    # The path is a pattern, not a folder: the aggregate must never read as "delete ~".
    clean_add node_modules "node_modules ($n folders$( [ "${r##*$'\t'}" = 1 ] && printf ', search timed out: lower bound'))" "~/**/node_modules" "$kb" 0
  fi

  [ "$PROTECTED_DONE" = 1 ] || return 0
  d="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  [ -d "$d" ] && clean_add maildownloads "Mail downloads" "$d"
  [ -d "$HOME/.Trash" ] && clean_add trash "Trash" "$HOME/.Trash"
  d="$HOME/Library/Containers/com.docker.docker"
  [ -d "$d" ] && clean_add docker "Docker Desktop" "$d"
  d="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack"
  [ -d "$d" ] && clean_add orbstack "OrbStack (group container)" "$d"

  if [ -d "$HOME/Downloads" ] && [ ! -L "$HOME/Downloads" ]; then
    r="$(home_row Downloads)"
    if [ -n "$r" ]; then kb="${r%%$'\t'*}"; den="${r#*$'\t'}"; else kb="?"; den=0; fi
    st="$(dir_stats "$HOME/Downloads")"
    n="${st%%$'\t'*}"; r="${st#*$'\t'}"; old="${r%%$'\t'*}"; new="${r#*$'\t'}"
    clean_add downloads "Downloads" "$HOME/Downloads" "$kb" "$den" \
      "${n:-0} item(s)$( [ -n "$old" ] && printf ', oldest %s, newest %s' "$(fmt_epoch "$old")" "$(fmt_epoch "$new")")"
  fi

  # Old installers: an installer whose app is installed is SAFE; zips may be data.
  for p in "$APPS_DIR"/*.app "$APPS_DIR"/*/*.app "$HOME/Applications"/*.app; do
    [ -d "$p" ] && apps_norm+="$(letters_only "${p##*/}")"$'\n'
  done
  while IFS=$'\t' read -r sz mt p; do
    case "$sz" in ''|*[!0-9]*) continue ;; esac
    clean_add "$(installer_kind "${p##*/}" "$apps_norm")" "Installer \`${p##*/}\`" "$p" "$((sz / 1024))" 0 "modified $(fmt_epoch "$mt")"
  done < <(run_timeout 30 find "$HOME/Downloads" "$HOME/Desktop" -maxdepth 3 -type f \
             \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.zip' \) -size +"${INSTALLER_MIN_MB}"M \
             -exec stat -f '%z%t%m%t%N' {} + 2>/dev/null)

  # Photos libraries anywhere shallow in ~: more than one is a duplicate risk.
  libs="$( { printf '%s' "$PHOTO_ROWS" | cut -f3
             run_timeout 30 find "$HOME" -xdev -maxdepth 3 \( -path "$HOME/Library" -o -path "$HOME/.Trash" \
               -o -name Dropbox -o -name 'Dropbox (*' -o -name 'OneDrive*' -o -name 'Google Drive*' \) -prune \
               -o -name '*.photoslibrary' -print -prune 2>/dev/null; } | sed '/^$/d' | LC_ALL=C sort -u)"
  nlib="$(printf '%s' "$libs" | grep -c .)"
  while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    r="$(printf '%s' "$PHOTO_ROWS" | awk -F'\t' -v p="$lib" '$3 == p { print $1 "\t" $2; exit }')"
    if [ -n "$r" ]; then kb="${r%%$'\t'*}"; den="${r#*$'\t'}"; else du_size "$lib"; kb="$DU_KB"; den="$DU_DENIED"; fi
    if [ "$nlib" -gt 1 ]; then clean_add photos-dup "Photos library" "$lib" "$kb" "$den"
    else clean_add photos "Photos library" "$lib" "$kb" "$den"; fi
  done < <(printf '%s\n' "$libs")
}

section_cleanup() {
  emit "## 6. Data cleanup candidates (sizes only — nothing is deleted)"
  blank
  progress "sizing cleanup candidates (caches, Xcode, conda, Rust, node_modules, installers…)…"
  collect_cleanup
  device_backups
  if [ -z "$CLEAN_ROWS" ]; then
    emit "- nothing found"; blank; return
  fi
  emit "SAFE-TO-DELETE: regenerated or re-downloadable · REVIEW: look first, may be the only copy · KEEP: not cleanup."
  blank
  emit "| Item | Path | Size | Class | Note |"
  emit "|---|---|---|---|---|"
  local cls c kb den label path note safe_kb=0 nsafe=0 rev_kb=0 nrev=0
  for cls in SAFE-TO-DELETE REVIEW KEEP; do
    while IFS=$'\t' read -r c kb den label path note; do
      [ "$c" = "$cls" ] || continue
      case "$kb" in
        ''|*[!0-9]*) ;;
        *) [ "$c" = SAFE-TO-DELETE ] && [ "$kb" -lt "$SMALL_KB" ] && continue
           case "$c" in
             SAFE-TO-DELETE) safe_kb=$((safe_kb + kb)); nsafe=$((nsafe + 1)) ;;
             REVIEW) rev_kb=$((rev_kb + kb)); nrev=$((nrev + 1)) ;;
           esac ;;
      esac
      emit "| $(md_cell "$label") | \`$(md_cell "$(tilde_path "$path")")\` | $(size_label "$kb" "$den") | $c | $(md_cell "$note") |"
    done < <(printf '%s' "$CLEAN_ROWS" | awk -F'\t' 'BEGIN{OFS="\t"} { s=($2 ~ /^[0-9]+$/) ? $2 : -1; print s, $0 }' | sort -t$'\t' -k1,1nr | cut -f2-)
  done
  blank
  emit "- SAFE-TO-DELETE: $(human_kb "$safe_kb") across $nsafe item(s) · REVIEW: $(human_kb "$rev_kb") across $nrev item(s). Nothing was deleted; an erase removes all of it anyway — this is for slimming the backup and the next setup."
  [ "$PROTECTED_DONE" = 1 ] || emit "- Not measured (--skip-protected): Downloads, Trash, Mail downloads, Docker data, installers, Photos libraries."
  blank
}

# ── section 7: largest files ───────────────────────────────────────────────

section_largest() {
  emit "## 7. Largest files and folders"
  blank
  emit "Largest folders: the **Home folders** table in section 4 (top 25 by size); app data and cleanup candidates are sized in sections 4 and 6."
  blank
  progress "finding files over ${LARGE_MIN_MB} MB under ~ (${LARGE_FIND_TIMEOUT}s cap)…"
  local out rc rows n total=0 sz mt p shown=0
  local -a prune=(-path "$HOME/Library/Caches" -o -path "$HOME/Library/CloudStorage" -o -path "$HOME/Library/Mobile Documents"
    -o -path "$HOME/Dropbox" -o -path "$HOME/Dropbox (*" -o -path "$HOME/OneDrive*" -o -path "$HOME/Google Drive*"
    -o -path "$HOME/Creative Cloud Files*" -o -path "$HOME/Box" -o -path "$HOME/Box Sync" -o -path "$HOME/iCloud Drive"
    -o -name '*.photoslibrary')
  [ "$SKIP_PROTECTED" = 1 ] && prune+=(-o -path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "$HOME/Desktop"
    -o -path "$HOME/Documents" -o -path "$HOME/Downloads" -o -path "$HOME/Pictures")
  out="$(run_timeout "$LARGE_FIND_TIMEOUT" find "$HOME" -xdev \( "${prune[@]}" \) -prune \
    -o -type f -size +"${LARGE_MIN_MB}"M -exec stat -f '%z%t%m%t%N' {} + 2>/dev/null)"
  rc=$?
  rows="$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /^[0-9]+$/' | LC_ALL=C sort -t$'\t' -k1,1nr)"
  n="$(printf '%s' "$rows" | grep -c .)"
  if [ "$n" -eq 0 ]; then
    emit "- No files over $LARGE_MIN_MB MB under ~ (Library/Caches, cloud folders and Photos libraries skipped$( [ "$SKIP_PROTECTED" = 1 ] && printf '; protected folders and ~/Library skipped: --skip-protected'))."
  else
    emit "| File (under ~) | Size | Modified |"
    emit "|---|---|---|"
    while IFS=$'\t' read -r sz mt p; do
      [ -n "$p" ] || continue
      total=$((total + sz / 1024)); shown=$((shown + 1))
      [ "$shown" -le "$LARGE_TOP" ] || continue
      emit "| \`$(md_cell "${p#"$HOME"/}")\` | $(human_kb $((sz / 1024))) | $(fmt_epoch "$mt") |"
    done < <(printf '%s\n' "$rows")
    blank
    emit "- $n file(s) over $LARGE_MIN_MB MB, $(human_kb "$total") in total$( [ "$n" -gt "$LARGE_TOP" ] && printf ' (top %s shown)' "$LARGE_TOP"). Library/Caches, cloud folders and Photos libraries skipped$( [ "$SKIP_PROTECTED" = 1 ] && printf '; protected folders and ~/Library skipped (--skip-protected)')."
  fi
  [ "$rc" = 124 ] && emit "- The search hit its ${LARGE_FIND_TIMEOUT}s limit — the list may be incomplete."
  blank
}

# ── section 9: backup plan ─────────────────────────────────────────────────

section_backup_plan() { # section_backup_plan "USER …"
  emit "## 9. Backup plan"
  blank
  emit "What to copy off before erasing: RED = exists only on this Mac, AMBER = worth copying (device backups, unconfirmed Photos/Messages/Mail). Commands are printed, never run."
  blank
  local u s kb n unk total=0 any=0 cell lvl
  emit "| Account | RED (local-only) | AMBER (worth copying) |"
  emit "|---|---|---|"
  for u in $1; do
    cell=""
    for lvl in RED AMBER; do
      s="$(plan_summary "$u" "$lvl")"
      kb="${s%%$'\t'*}"; s="${s#*$'\t'}"; n="${s%%$'\t'*}"; unk="${s#*$'\t'}"
      [ "$lvl" = RED ] && total=$((total + kb))
      [ "$n" -gt 0 ] && any=1
      if [ "$n" -eq 0 ]; then cell+=" – |"
      else cell+=" $(human_kb "$kb") in $n path(s)$( [ "$unk" -gt 0 ] && printf ' + %s of unknown size' "$unk") |"; fi
    done
    emit "| \`$u\` |$cell"
  done
  blank
  if [ "$any" = 0 ]; then
    emit "- Nothing flagged to copy. A final Time Machine backup is still cheap insurance."
    blank; return
  fi

  local sudo_r="" sudo_c="" p args amb
  if [ "$ALL_USERS" = 1 ]; then
    sudo_r="sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_REST_PASSWORD,RESTIC_PASSWORD_FILE "
    sudo_c="sudo "
  fi
  emit "### Option A — encrypted one-off archive to the Studio (restic)"
  blank
  emit "The fleet restic REST server on \`$STUDIO_HOST:$RESTIC_PORT\` (append-only, one repo per host) — the same server and layout as \`scripts/restic-backup.sh\` (device-guide → *Restic backups*). Capacity: $STUDIO_FREE_NOTE; RED here totals $(human_kb "$total") — check \`df -h\` on the Studio first. If this Mac is on the dotfiles flake with \`resticBackup = true\`, \`rh7-restic-backup setup\` replaces steps 2–3.$( [ "$ALL_USERS" = 1 ] && printf ' Run from this admin terminal (it has Full Disk Access): `sudo` lets restic read every account.')"
  blank
  emit '```sh'
  emit "# 1. on the Studio (rh-device-management): this host's REST login — prints rh7-restic:$HOST:<password> once"
  emit "~/rh-device-management/scripts/restic-server-add-host.sh $HOST"
  emit "# 2. on this Mac (restic: brew install restic, or nix shell nixpkgs#restic)"
  [ "$ALL_USERS" = 1 ] && emit "RESTIC_BIN=\"\$(command -v restic)\"   # sudo's secure PATH has no Homebrew/Nix"
  emit "export RESTIC_REPOSITORY='rest:http://$HOST@$STUDIO_HOST:$RESTIC_PORT/$HOST/'"
  emit "read -rs RESTIC_REST_PASSWORD && export RESTIC_REST_PASSWORD   # paste the <password> part of the token"
  emit "# 3. the ENCRYPTION key — without it the archive is unreadable: escrow it in 1Password"
  emit "mkdir -p ~/.config/rh7-restic && ( umask 077; [ -s ~/.config/rh7-restic/repo-password ] || openssl rand -base64 32 > ~/.config/rh7-restic/repo-password )"
  emit "export RESTIC_PASSWORD_FILE=~/.config/rh7-restic/repo-password"
  emit "~/rh-device-management/scripts/escrow-secrets-1password.sh --env ~/.config/rh7-restic/repo-password   # dry-run; add --apply"
  emit "restic init   # once per repo; skip if rh7-restic-backup setup already did it"
  emit "# 4. the archive: RED paths per account (AMBER ones listed as comments — add those you want)"
  for u in $1; do
    args=""
    while IFS= read -r p; do [ -n "$p" ] && args+=" \\"$'\n'"    $(shq "$p")"; done < <(plan_paths "$u" RED)
    [ -n "$args" ] && emit "${sudo_r}$( [ "$ALL_USERS" = 1 ] && printf '"$RESTIC_BIN"' || printf restic) backup --tag pre-wipe --tag account:$u --exclude-caches$args"
    amb=""
    while IFS= read -r p; do [ -n "$p" ] && amb+="#   $(shq "$p")"$'\n'; done < <(plan_paths "$u" AMBER)
    [ -n "$amb" ] && BODY+="# AMBER for $u:"$'\n'"$amb"
  done
  emit "restic snapshots --tag pre-wipe   # verify before erasing"
  emit '```'
  blank
  emit "### Option B — copy to an external disk"
  blank
  emit "Format the disk APFS in Disk Utility and name it \`PreWipe\`. \`ditto\` keeps permissions, extended attributes and dates."
  blank
  emit '```sh'
  for u in $1; do
    while IFS= read -r p; do
      [ -n "$p" ] && emit "${sudo_c}mkdir -p $(shq "/Volumes/PreWipe/$HOST${p%/*}") && ${sudo_c}ditto $(shq "$p") $(shq "/Volumes/PreWipe/$HOST$p")"
    done < <(plan_paths "$u" RED)
  done
  emit "# or a full Time Machine backup of this Mac (Time Machine takes over its disk — use a separate one):"
  emit "sudo tmutil setdestination -a /Volumes/<TimeMachineDisk>"
  emit "tmutil startbackup --block"
  emit '```'
  blank
}

# ── section 10: checklist ──────────────────────────────────────────────────

section_checklist() {
  # The DELETE must go to the instance the fleet actually uses. Never put the
  # bootstrap fallback here: if resolution failed, use the configured pin
  # (even if it was unreachable just now) or leave a placeholder.
  local cfg="${CFG_URL:-${CONFIG_SERVICE_URL:-}}"
  [ -n "$cfg" ] || cfg="$(_config_service_pin "$CONFIG_SERVICE_PIN_SYSTEM" || _config_service_pin "$CONFIG_SERVICE_PIN_USER")"
  [ -n "$cfg" ] || cfg="<config-service-url>"
  cfg="${cfg%/}"
  local each=""
  [ "$ALL_USERS" = 1 ] && each=" — in **every** account"
  emit "## 10. Checklist (in this order)"
  blank
  emit "1. **Confirm every crypto wallet's seed phrase / recovery is stored offline** (section 5)$each. Do not touch wallet files before that."
  emit "2. **Escrow secrets** — SSH keys, GPG keys, age key, .env files: \`scripts/escrow-secrets-1password.sh\` (rh7/rh-device-management)."
  emit "3. **Commit and push every repo** flagged above (including stashes and branches without upstream)."
  emit "4. **Copy every RED folder / app data** — the commands are in section 9 (restic to the Studio, or an external disk)."
  emit "5. **Run a final Time Machine backup** (or a one-off copy) and confirm it completed."
  emit "6. **Confirm browser sync, licences, Music deauthorization**$each. Re-run this script — it should say \`safe to wipe: likely\` or only list AMBERs you accept."
  emit "7. **Sign out of iCloud**$each (System Settings → Apple Account → Sign Out) — this turns off Find My / Activation Lock."
  emit "8. **Erase**: System Settings → General → Transfer or Reset → Erase All Content and Settings."
  emit "9. **Afterwards, retire the registry row**: \`curl -X DELETE $cfg/api/devices/$HOST\` (admin-gated)."
  blank
}

# ── --all-users: accounts table + per-account re-invocation ────────────────

section_accounts() { # section_accounts USERS("NAME\tUID\tHOME\n…") INVOKER
  local name uid home adm out kb ll
  emit "## Accounts on this Mac"
  blank
  emit "Real local accounts (UID ≥ 501, not hidden, home under $USERS_ROOT). Each is checked below **as that account** (\`sudo -u\`), so its iCloud, browser and app settings are its own."
  blank
  emit "| Account | Admin | Home size | Last login |"
  emit "|---|---|---|---|"
  while IFS=$'\t' read -r name uid home; do
    [ -n "$name" ] || continue
    adm=no; user_is_admin "$name" && adm=yes
    progress "sizing $home (${ACCOUNT_DU_TIMEOUT}s cap)…"
    out="$(run_timeout "$ACCOUNT_DU_TIMEOUT" du -skx "$home" 2>/dev/null)"
    kb="${out%%[!0-9]*}"; [ -n "$kb" ] || kb="?"
    ll="$(last_login "$name")"
    emit "| \`$name\`$( [ "$name" = "$2" ] && printf ' (you)') | $adm | $(size_label "$kb" 0) | ${ll:-no record} |"
  done < <(printf '%s\n' "$1")
  blank
}

load_self_text() {
  if [ -n "$PWC_SELF" ] && [ -f "$PWC_SELF" ] && [ -r "$PWC_SELF" ]; then
    SELF_TEXT="$(cat "$PWC_SELF")"
  else
    progress "not run from a file (curl | bash): fetching $PWC_RAW_URL for the per-account runs"
    SELF_TEXT="$(curl -fsSL --max-time 30 "$PWC_RAW_URL" 2>/dev/null)"
  fi
  case "$SELF_TEXT" in '#!/usr/bin/env bash'*PRE_WIPE_CHECK_SOURCE_ONLY*) return 0 ;; esac
  return 1
}

run_child() { # run_child NAME HOME PART LABEL → folds the fragment in; 1 on failure
  local frag rc
  build_child_argv "$1" "$2" "$3"
  frag="$(printf '%s\n' "$SELF_TEXT" | (cd / && "${CHILD_ARGV[@]}"))"
  rc=$?
  if [ "$rc" != 0 ] || ! parse_fragment "$frag" "$4"; then
    finding RED "The $3 checks for account \`$1\` did not complete (exit $rc) — that account is NOT covered by this report; fix and re-run before wiping."
    FRAG_BODY=""
    return 1
  fi
  return 0
}

run_all_users() {
  if [ "$(id -u)" != 0 ]; then
    echo "pre-wipe-check: --all-users needs root: sudo ${PWC_SELF:-pre-wipe-check.sh} --all-users" >&2; exit 2
  fi
  local admin="${SUDO_USER:-}"
  if [ -z "$admin" ] || [ "$admin" = root ]; then
    echo "pre-wipe-check: run --all-users via sudo from your own admin account (SUDO_USER is unset), so the report has an owner." >&2; exit 2
  fi
  load_self_text || { echo "pre-wipe-check: cannot load this script's own text for the per-account runs; download it and run: sudo bash pre-wipe-check.sh --all-users" >&2; exit 2; }

  local users name uid home admin_home="" blocked rc names=""
  users="$(list_real_users)"
  [ -n "$users" ] || { echo "pre-wipe-check: no real local accounts found (dscl)" >&2; exit 2; }
  local -a probes=("/Library/Application Support/com.apple.TCC")
  while IFS=$'\t' read -r name uid home; do
    [ -n "$name" ] || continue
    names+="$name "
    [ "$name" = "$admin" ] && admin_home="$home"
    probes+=("$home/Library/Mail" "$home/Library/Safari" "$home/Library/Messages")
  done < <(printf '%s\n' "$users")
  if [ -z "$admin_home" ]; then
    admin_home="$(dscl . -read "/Users/$admin" NFSHomeDirectory 2>/dev/null | parse_dscl_user)"; admin_home="${admin_home%%$'\t'*}"
  fi
  [ -d "$admin_home" ] || { echo "pre-wipe-check: cannot find the home of $admin for the report" >&2; exit 2; }

  if [ "$SKIP_PROTECTED" = 1 ]; then
    rc=3   # nothing protected is read, so Full Disk Access is not needed
  else
    blocked="$(fda_probe "${probes[@]}")"; rc=$?
    if [ "$rc" = 1 ]; then fda_help "$blocked" "${PWC_SELF:-pre-wipe-check.sh}" >&2; exit 2; fi
  fi

  progress "all accounts: ${names% } — each checked as itself; report goes to $admin_home"
  emit "Host: \`$HOST\` · $(scutil --get ComputerName 2>/dev/null) · macOS $(sw_vers -productVersion 2>/dev/null) · $(sysctl -n hw.model 2>/dev/null)"
  emit "Generated $(date '+%Y-%m-%d %H:%M %Z') by pre-wipe-check v$PWC_VERSION --all-users (run by \`$admin\`) · protected locations: $( [ "$SKIP_PROTECTED" = 1 ] && printf 'SKIPPED (--skip-protected)' || printf 'read')"
  blank
  [ "$rc" = 2 ] && finding AMBER "Full Disk Access could not be verified (no Mail/Safari/Messages folder to probe) — anything macOS hid is marked \"partly unreadable\"."
  [ "$rc" = 3 ] && emit "Full Disk Access not checked: --skip-protected reads no protected location in any account."
  [ "$rc" = 3 ] && blank
  [ -n "${CONFIG_SERVICE_ADMIN_TOKEN:-}" ] && progress "note: CONFIG_SERVICE_ADMIN_TOKEN is not forwarded to the per-account runs (it would show in ps)"
  section_accounts "$users" "$admin"

  progress "── this Mac (apps, control plane, Time Machine) as $admin ──"
  run_child "$admin" "$admin_home" system "this Mac" && BODY+="$FRAG_BODY"
  while IFS=$'\t' read -r name uid home; do
    [ -n "$name" ] || continue
    progress "── account $name ($home) ──"
    emit "## Account \`$name\`$( [ "$name" = "$admin" ] && printf ' (you)')"
    blank
    if run_child "$name" "$home" user "$name"; then
      BODY+="$(printf '%s' "$FRAG_BODY" | demote_headings)"$'\n'
    else
      emit "- **Not checked** — see the RED item at the top."
      blank
    fi
  done < <(printf '%s\n' "$users")

  section_backup_plan "${names% }"
  section_checklist
  emit "---"
  emit "Read-only report. Every account above was checked as itself. Not inspected: hidden/system accounts, system folders outside the home folders, external volumes, and anything a missing Full Disk Access grant hid (marked \"partly unreadable\")."
  finish_report "$admin" "$admin_home"
}

# finish_report [OWNER OWNER_HOME] — verdict on top, print, save, exit.
# With an OWNER (--all-users, running as root) the file is written AS that
# account, so it is theirs and no root-owned file lands in their home.
finish_report() {
  local verdict head out file stamp safe_host home="${2:-$HOME}" rc=0 title="$HOST"
  [ -n "${1:-}" ] && title="$HOST (all accounts)"
  verdict="$(verdict_word "$N_RED" "$N_AMBER")"
  head="# Pre-wipe check: $title"$'\n\n'
  head+="## 1. Verdict"$'\n\n'
  head+="**Safe to wipe: ${verdict}** — $N_RED RED (will be lost) · $N_AMBER AMBER (check) · $N_GREEN GREEN"$'\n\n'
  [ -n "$RED_ITEMS" ] && head+="RED:"$'\n'"$RED_ITEMS"$'\n'
  [ -n "$AMBER_ITEMS" ] && head+="AMBER:"$'\n'"$AMBER_ITEMS"$'\n'
  out="$head$BODY"

  stamp="$(date '+%Y%m%d-%H%M')"
  safe_host="$(printf '%s' "$HOST" | tr -c 'a-z0-9.-' '_')"
  file="$home/pre-wipe-$safe_host-$stamp.md"
  [ -e "$file" ] && file="$home/pre-wipe-$safe_host-$stamp$(date '+%S').md"

  printf '%s' "$out"
  if [ -n "${1:-}" ]; then
    printf '%s' "$out" | sudo -n -u "$1" /bin/sh -c 'umask 077; set -C; cat > "$1"' sh "$file" 2>/dev/null || rc=2
  else
    ( umask 077; printf '%s' "$out" > "$file" ) 2>/dev/null || rc=2
  fi
  if [ "$rc" = 0 ]; then
    printf '\nReport saved: %s\n' "$file"
    progress "report saved: $file"
  else
    echo "pre-wipe-check: could not write $file" >&2
  fi
  [ "$rc" = 0 ] && [ "$N_RED" -gt 0 ] && rc=1
  FINISHED=1
  exit "$rc"
}

# ── main ───────────────────────────────────────────────────────────────────

usage() {
  awk 'NR == 1 { next } /^# What it guarantees/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true
  echo "See $PWC_RAW_URL"
}

FINISHED=0
on_exit() { local rc=$?; [ "$FINISHED" = 1 ] || exit 2; exit "$rc"; }

main() {
  # Under `curl … | bash` stdin IS this script; nothing below may read it.
  exec </dev/null
  trap on_exit EXIT

  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-protected) SKIP_PROTECTED=1 ;;
      --suggest-casks) SUGGEST_CASKS=1 ;;
      --offline) OFFLINE=1 ;;
      --host) shift; HOST_OVERRIDE="${1:-}" ;;
      --host=*) HOST_OVERRIDE="${1#--host=}" ;;
      --all-users) ALL_USERS=1 ;;
      --as-user) shift; AS_USER="${1:-}" ;;   # internal (--all-users children)
      --part) shift; PART="${1:-}" ;;         # internal (--all-users children)
      -h|--help) usage; FINISHED=1; exit 0 ;;
      *) echo "pre-wipe-check: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$PART" in all|system|user) ;; *) echo "pre-wipe-check: --part must be system or user" >&2; exit 2 ;; esac
  if [ -n "$AS_USER" ] && { [ "$PART" = all ] || [ "$ALL_USERS" = 1 ]; }; then
    echo "pre-wipe-check: --as-user is internal to --all-users and needs --part" >&2; exit 2
  fi
  if [ -z "$AS_USER" ] && [ "$PART" != all ]; then
    echo "pre-wipe-check: --part is internal to --all-users" >&2; exit 2
  fi
  if [ "$(uname -s)" != Darwin ]; then
    echo "pre-wipe-check: macOS only." >&2; exit 2
  fi
  if [ -n "$AS_USER" ]; then
    # A child must really be the account it reports on.
    [ "$(id -un)" = "$AS_USER" ] || { echo "pre-wipe-check: --as-user $AS_USER but running as $(id -un)" >&2; exit 2; }
    PROGRESS_TAG="pre-wipe:$AS_USER"
  fi
  local user_nix_bin
  user_nix_bin="/etc/profiles/per-user/$(id -un)/bin"
  export PATH="$user_nix_bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  if [ -n "$AS_USER" ]; then
    # sudo -u gives a bare system PATH; add the account's own tool dirs so its
    # npm/pipx/uv (installed under ~) are found like in a login shell.
    local d
    for d in "$HOME"/.nvm/versions/node/*/bin "$HOME"/Library/Python/*/bin "$HOME/.volta/bin" \
             "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
      [ -d "$d" ] && PATH="$d:$PATH"
    done
  fi
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"

  local raw_host lhn
  raw_host="$(hostname 2>/dev/null)"
  HOST="$(canonical_host "${HOST_OVERRIDE:-$raw_host}")"
  lhn="$(canonical_host "$(scutil --get LocalHostName 2>/dev/null)")"
  [ -n "$HOST" ] || HOST="$lhn"
  PLAN_USER="$(id -un)"

  if [ "$ALL_USERS" = 1 ]; then
    progress "pre-wipe check v$PWC_VERSION --all-users on $HOST — read-only; the only write is the report."
    run_all_users   # exits
  fi

  have_git && GIT_OK=1
  SIZE_DEADLINE=$((SECONDS + SIZE_BUDGET))
  [ -n "$AS_USER" ] || progress "pre-wipe check v$PWC_VERSION on $HOST — read-only; the only write is the report."

  collect_icloud_account

  if [ "$PART" = all ]; then
    emit "Host: \`$HOST\`$( [ -n "$lhn" ] && [ "$lhn" != "$HOST" ] && printf ' (LocalHostName `%s`)' "$lhn") · $(scutil --get ComputerName 2>/dev/null) · macOS $(sw_vers -productVersion 2>/dev/null) · $(sysctl -n hw.model 2>/dev/null)"
    emit "Generated $(date '+%Y-%m-%d %H:%M %Z') by pre-wipe-check v$PWC_VERSION · protected locations: $( [ "$SKIP_PROTECTED" = 1 ] && printf 'SKIPPED (--skip-protected)' || printf 'read')"
    blank
    local others
    others="$(list_real_users | awk -F'\t' -v me="$PLAN_USER" '$1 != me { printf "%s ", $1 }')"
    if [ -n "$others" ]; then
      finding AMBER "Other accounts on this Mac were not inspected: ${others% } — run \`sudo pre-wipe-check.sh --all-users\` from an admin account (terminal with Full Disk Access)."
      blank
    fi
  fi

  [ "$PART" = user ] || section_control_plane
  section_apps

  if [ "$PART" != system ]; then
    progress "looking for git repos and .env files under ~ (depth 5)…"
    collect_git_walk "$HOME" 5
    collect_home_sizes
    collect_appsupport_sizes
    [ "$SKIP_PROTECTED" = 1 ] || collect_protected
    REPOS="$(printf '%s' "$REPOS" | LC_ALL=C sort -u)"
    [ -n "$REPOS" ] && REPOS+=$'\n'

    section_local_data
    section_wallets
    section_cleanup
    section_largest
  fi
  section_backups

  if [ -n "$AS_USER" ]; then
    emit_fragment
    FINISHED=1
    exit 0
  fi

  section_backup_plan "$PLAN_USER"
  section_checklist

  emit "---"
  emit "Read-only report. Not inspected: system folders outside your home, other user accounts (\`--all-users\`), external volumes, and anything a denied privacy prompt or missing Full Disk Access hid (marked \"partly unreadable\")."
  finish_report
}

[ "${PRE_WIPE_CHECK_SOURCE_ONLY:-0}" = 1 ] || main "$@"
