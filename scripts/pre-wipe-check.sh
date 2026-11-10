#!/usr/bin/env bash
# pre-wipe-check.sh — READ-ONLY "is it safe to wipe this Mac?" report.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash -s -- --skip-protected
#   ./scripts/pre-wipe-check.sh [--skip-protected] [--suggest-casks] [--offline] [--host NAME]
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
#
# What it guarantees:
#   * Read-only. The only file written is the report itself,
#     ~/pre-wipe-<host>-<YYYYmmdd-HHMM>.md (mode 600). Git is run with
#     GIT_OPTIONAL_LOCKS=0 so `git status` does not refresh the index. Here-strings
#     are avoided because bash 3.2 backs them with temp files.
#   * Nothing leaves the machine except one GET of this host's retirement verdict
#     from the fleet config service. No file names or contents are uploaded.
#   * No sudo. Things that need root are named, not attempted.
#   * Secrets: names, counts and public fingerprints only — never contents.
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

BIG_KB=102400      # 100 MB: a local-only folder this size is called out RED
SMALL_KB=1024      # 1 MB: below this a folder is treated as empty
DU_TIMEOUT=20      # seconds per du target
SIZE_BUDGET=100    # seconds of du across the whole run before sizing stops
GIT_TIMEOUT=10     # seconds per git command
FIND_TIMEOUT=60    # seconds for the repo discovery walk

# ── report buffer + findings ────────────────────────────────────────────────
# The verdict goes at the TOP but is only known at the end, so the body is
# buffered and printed (and saved) once.
BODY=""
N_RED=0; N_AMBER=0; N_GREEN=0
RED_ITEMS=""; AMBER_ITEMS=""

emit()  { BODY+="$*"$'\n'; }
blank() { BODY+=$'\n'; }
progress() { printf '[pre-wipe] %s\n' "$*" >&2; }

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
classify_app() {
  case "$1" in
    */"Nix Apps"/*|*/"Home Manager Apps"/*|/nix/store/*) echo nix; return ;;
  esac
  case "$3" in 1|2) echo mas; return ;; esac
  case "$2" in com.apple.*) echo apple; return ;; esac
  [ "$4" = 1 ] && { echo brew; return; }
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
    .cache|.npm|.npm-global|.cargo|.rustup|.gradle|.m2|.pnpm-store|.bun|.nvm|.pyenv|.rbenv|.gem|.ollama|.lmstudio|.vscode|.vscode-insiders|.cursor|.windsurf|.node-gyp|.yarn|.deno|.expo|.android|.swiftpm|.platformio|go|.nix-defexpr|.nix-profile|.cocoapods|.conda|miniconda3|anaconda3|.pub-cache|.dartServer|.huggingface|.zsh_sessions|.local) echo cache ;;
    *) echo other ;;
  esac
}

# home_entry_level KIND KB DD_SYNCED(0|1) HAS_REPOS(0|1) NAME → "LEVEL<TAB>note"
# LEVEL is RED, AMBER, GREEN, REPO (folded into one finding) or NONE (table
# note only).
home_entry_level() {
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
      printf 'VM\tlocal iPhone/iPad backups\n' ;;
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

# Is a path inside something that is synced off this Mac?
is_cloud_path() { # is_cloud_path PATH DD_SYNCED
  case "$1" in
    "$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*|"$HOME/Dropbox"|"$HOME/Dropbox/"*|"$HOME/Dropbox ("*) return 0 ;;
    "$HOME/Desktop"|"$HOME/Desktop/"*|"$HOME/Documents"|"$HOME/Documents/"*) [ "$2" = 1 ] ;;
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
    HOMEBREW_NO_INSTALL_CLEANUP=1 run_timeout 90 brew "$@" 2>/dev/null
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
  emit "## 3. Apps to reinstall"
  blank
  progress "inventorying /Applications and ~/Applications…"
  local have_brew=0 have_mas=0 cask_map="" cask_list="" mas_map="" cask_names=""
  command -v brew >/dev/null 2>&1 && have_brew=1
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

  local paths info
  paths="$(find /Applications "$HOME/Applications" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null | LC_ALL=C sort -f)"
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
        [ -n "$hint" ] || hint="(brew not installed)"
        t_manual+="| $(md_cell "$base") | $(md_cell "$ver") | $(md_cell "$bid") | $(md_cell "$hint") |"$'\n' ;;
    esac
  done < <(printf '%s\n' "$info")

  emit "Apple system apps skipped: $n_apple. Every other \`.app\` in /Applications and ~/Applications:"
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
  else
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

collect_git_walk() { # collect_git_walk ROOT MAXDEPTH — appends to REPOS / ENV_FILES
  local root="$1" depth="$2" out line
  out="$(run_timeout "$FIND_TIMEOUT" find "$root" -xdev -maxdepth "$depth" \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "$HOME/Desktop" -o -path "$HOME/Documents" \
       -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" -o -path "$HOME/Music" -o -path "$HOME/Movies" \
       -o -path "$HOME/Applications" \
       -o -name node_modules -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup -o -name .gradle \
       -o -name .m2 -o -name .pnpm-store -o -name .bun -o -name .nvm -o -name .pyenv -o -name .rbenv \
       -o -name .ollama -o -name .lmstudio -o -name .vscode -o -name .cursor -o -name .orbstack -o -name .docker \
       -o -name .colima -o -name .lima -o -name .venv -o -name venv -o -name Pods -o -name DerivedData \
       -o -name 'Dropbox' -o -name 'Dropbox (*' -o -name 'OneDrive*' -o -name 'Google Drive*' \
       -o -name 'Creative Cloud Files*' -o -name '*.photoslibrary' -o -name '*.app' \) -prune \
    -o -name .git -print -prune \
    -o -type f \( -name .env -o -name '.env.*' \) ! -name '*.example' ! -name '*.sample' ! -name '*.template' ! -name '*.dist' -print \
    2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in
      */.git) REPOS+="${line%/.git}"$'\n' ;;
      ?*) ENV_FILES+="$line"$'\n' ;;
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
    lvl="$(home_entry_level "$kind" "$judge_kb" "$DD_SYNCED" "$has" "$name")"
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
      RED|AMBER) FINDINGS_DEFERRED+="$lvl"$'\t'"\`~/$name\` — $dlabel — $note"$'\n' ;;
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
  fi
  if [ "$PROTECTED_DONE" = 1 ] && [ -n "$MAIL_KB" ] && [ "$MAIL_KB" != "?" ] && [ "$MAIL_KB" -ge "$BIG_KB" ]; then
    finding AMBER "Local Mail store $(size_label "$MAIL_KB" "$MAIL_DENIED") — IMAP/iCloud mail re-downloads, \"On My Mac\" mailboxes do not."
  elif [ "$PROTECTED_DONE" = 1 ] && [ -n "$MAIL_KB" ]; then
    emit "- ~/Library/Mail: $(size_label "$MAIL_KB" "$MAIL_DENIED")"
  fi
  [ "$MSG_DENIED" = 1 ] || [ "$MAIL_DENIED" = 1 ] && emit "- Mail/Messages sizes need Full Disk Access for the terminal to be exact."
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
  # Findings for every flagged entry, not just the top 20.
  while IFS=$'\t' read -r kb den name; do
    [ -n "$name" ] || continue
    flag="$(appdata_flag "$name")"; [ -n "$flag" ] || continue
    lvl="${flag%%$'\t'*}"; note="${flag#*$'\t'}"
    if [ "$lvl" = VM ]; then
      if [ "$kb" != "?" ] && [ "$kb" -ge "$BIG_KB" ]; then lvl=RED
      elif [ "$kb" = "?" ] || [ "$den" = 1 ]; then lvl=AMBER
      else lvl=NONE; fi
    fi
    [ "$lvl" = NONE ] || finding "$lvl" "$name: $note ($(size_label "$kb" "$den"))."
  done < <(printf '%s' "$rows")
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
        noremote=0; unpushed=0; stashes=0
      else
        if [ -n "$(g "$r" remote)" ]; then
          noremote=0
          unpushed="$(g "$r" rev-list --branches --not --remotes --count)"
        else
          noremote=1; unpushed="$(g "$r" rev-list --branches --count)"
        fi
        stashes="$(g "$r" rev-list --walk-reflogs --count refs/stash)"
        [ -n "$unpushed" ] || unpushed="?"
        [ -n "$stashes" ] || stashes=0
      fi
      if git_at_risk "$dirty" "$unpushed" "$noremote" "$stashes"; then
        at=$((at + 1))
        if [ "$shared" = 1 ]; then
          rows+="| \`$(md_cell "$(tilde_path "$r")")\` | $dirty | (worktree) | – | – |"$'\n'
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
  emit "## 5. Backups & before you erase"
  blank
  progress "checking Time Machine, FileVault, Find My, browsers…"
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
  blank

  emit "### Browsers"
  blank
  local as="$HOME/Library/Application Support" b dir prof signed total
  for b in "Google Chrome:Google/Chrome" "Brave:BraveSoftware/Brave-Browser" "Microsoft Edge:Microsoft Edge" \
           "Vivaldi:Vivaldi" "Arc:Arc/User Data" "Dia:Dia/User Data" "Chromium:Chromium"; do
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
      emit "- ${b%%:*}: $total profile(s), all signed in to an account (sync itself not verified)."
    else
      finding AMBER "${b%%:*}: $((total - signed)) of $total profile(s) not signed in — bookmarks/passwords/extensions there are local only."
    fi
  done
  if [ -d "$as/Firefox/Profiles" ]; then
    total=0; signed=0
    for prof in "$as/Firefox/Profiles"/*; do
      [ -d "$prof" ] || continue
      total=$((total + 1)); [ -f "$prof/signedInUser.json" ] && signed=$((signed + 1))
    done
    if [ "$total" -gt 0 ] && [ "$signed" -lt "$total" ]; then
      finding AMBER "Firefox: $((total - signed)) of $total profile(s) not signed in to a Firefox account."
    elif [ "$total" -gt 0 ]; then
      emit "- Firefox: $total profile(s), signed in."
    fi
  fi
  if [ -d "$HOME/Library/Safari" ]; then
    if icloud_service BOOKMARKS; then emit "- Safari: syncs via iCloud (Safari is on in the iCloud account)."
    else finding AMBER "Safari: iCloud Safari sync not reported on — bookmarks/reading list may be local only."; fi
  fi
  blank

  emit "### Commonly forgotten"
  blank
  local nf nla cron hist
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
  if [ -r /etc/hosts ] && [ "$(grep -v -E '^[[:space:]]*(#|$)' /etc/hosts | grep -v -E '[[:space:]](localhost|broadcasthost)$' | grep -c .)" -gt 0 ]; then
    emit "- /etc/hosts has custom entries."
  fi
  if [ "$MANUAL_COUNT" -gt 0 ] || [ "$SETAPP_COUNT" -gt 0 ]; then
    emit "- Licences: collect keys for the manual/Setapp apps above and deactivate seat-limited ones (Adobe, JetBrains, …)."
  fi
  emit "- Music/TV: Account → Authorizations → Deauthorize This Computer (5-computer limit)."
  blank
}

# ── section 6: checklist ───────────────────────────────────────────────────

section_checklist() {
  local cfg="${CFG_URL:-http://rouvens-mac-studio:3456}"
  emit "## 6. Checklist (in this order)"
  blank
  emit "1. **Escrow secrets** — SSH keys, GPG keys, age key, .env files: \`scripts/escrow-secrets-1password.sh\` (rh7/rh-device-management)."
  emit "2. **Commit and push every repo** flagged above (including stashes and branches without upstream)."
  emit "3. **Copy every RED folder / app data** to iCloud Drive, Dropbox or an external disk."
  emit "4. **Run a final Time Machine backup** (or a one-off copy) and confirm it completed."
  emit "5. **Confirm browser sync, licences, Music deauthorization.** Re-run this script — it should say \`safe to wipe: likely\` or only list AMBERs you accept."
  emit "6. **Sign out of iCloud** (System Settings → Apple Account → Sign Out) — this turns off Find My / Activation Lock."
  emit "7. **Erase**: System Settings → General → Transfer or Reset → Erase All Content and Settings."
  emit "8. **Afterwards, retire the registry row**: \`curl -X DELETE $cfg/api/devices/$HOST\` (admin-gated)."
  blank
}

# ── main ───────────────────────────────────────────────────────────────────

usage() { sed -n '2,21p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; echo "See $PWC_RAW_URL"; }

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
      -h|--help) usage; FINISHED=1; exit 0 ;;
      *) echo "pre-wipe-check: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ "$(uname -s)" != Darwin ]; then
    echo "pre-wipe-check: macOS only." >&2; exit 2
  fi
  local user_nix_bin
  user_nix_bin="/etc/profiles/per-user/$(id -un)/bin"
  export PATH="$user_nix_bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  export LC_ALL="${LC_ALL:-en_US.UTF-8}"

  local raw_host lhn
  raw_host="$(hostname 2>/dev/null)"
  HOST="$(canonical_host "${HOST_OVERRIDE:-$raw_host}")"
  lhn="$(canonical_host "$(scutil --get LocalHostName 2>/dev/null)")"
  [ -n "$HOST" ] || HOST="$lhn"
  have_git && GIT_OK=1
  SIZE_DEADLINE=$((SECONDS + SIZE_BUDGET))

  progress "pre-wipe check v$PWC_VERSION on $HOST — read-only; the only write is the report."

  collect_icloud_account

  emit "Host: \`$HOST\`$( [ -n "$lhn" ] && [ "$lhn" != "$HOST" ] && printf ' (LocalHostName `%s`)' "$lhn") · $(scutil --get ComputerName 2>/dev/null) · macOS $(sw_vers -productVersion 2>/dev/null) · $(sysctl -n hw.model 2>/dev/null)"
  emit "Generated $(date '+%Y-%m-%d %H:%M %Z') by pre-wipe-check v$PWC_VERSION · protected locations: $( [ "$SKIP_PROTECTED" = 1 ] && printf 'SKIPPED (--skip-protected)' || printf 'read')"
  blank

  section_control_plane
  section_apps

  progress "looking for git repos and .env files under ~ (depth 5)…"
  collect_git_walk "$HOME" 5
  collect_home_sizes
  collect_appsupport_sizes
  [ "$SKIP_PROTECTED" = 1 ] || collect_protected
  REPOS="$(printf '%s' "$REPOS" | LC_ALL=C sort -u)"
  [ -n "$REPOS" ] && REPOS+=$'\n'

  section_local_data
  section_backups
  section_checklist

  emit "---"
  emit "Read-only report. Not inspected: system folders outside your home, other user accounts, external volumes, and anything a denied privacy prompt or missing Full Disk Access hid (marked \"partly unreadable\")."

  local verdict head out file stamp safe_host
  verdict="$(verdict_word "$N_RED" "$N_AMBER")"
  head="# Pre-wipe check: $HOST"$'\n\n'
  head+="## 1. Verdict"$'\n\n'
  head+="**Safe to wipe: ${verdict}** — $N_RED RED (will be lost) · $N_AMBER AMBER (check) · $N_GREEN GREEN"$'\n\n'
  [ -n "$RED_ITEMS" ] && head+="RED:"$'\n'"$RED_ITEMS"$'\n'
  [ -n "$AMBER_ITEMS" ] && head+="AMBER:"$'\n'"$AMBER_ITEMS"$'\n'
  out="$head$BODY"

  stamp="$(date '+%Y%m%d-%H%M')"
  safe_host="$(printf '%s' "$HOST" | tr -c 'a-z0-9.-' '_')"
  file="$HOME/pre-wipe-$safe_host-$stamp.md"
  [ -e "$file" ] && file="$HOME/pre-wipe-$safe_host-$stamp$(date '+%S').md"

  printf '%s' "$out"
  local rc=0
  if ( umask 077; printf '%s' "$out" > "$file" ) 2>/dev/null; then
    printf '\nReport saved: %s\n' "$file"
    progress "report saved: $file"
  else
    echo "pre-wipe-check: could not write $file" >&2
    rc=2
  fi
  [ "$rc" = 0 ] && [ "$N_RED" -gt 0 ] && rc=1
  FINISHED=1
  exit "$rc"
}

[ "${PRE_WIPE_CHECK_SOURCE_ONLY:-0}" = 1 ] || main "$@"
