#!/usr/bin/env bash
# Safe rebuild wrapper — build, preview changes, then apply.
#
# Usage:
#   rebuild.sh              # interactive: build → diff → confirm → switch
#   rebuild.sh --yes        # auto-confirm (still needs you to authenticate)
#   rebuild.sh --build-only # just build, don't switch
#   rebuild.sh --upgrade=all  # upgrade every declared outdated package
#   rebuild.sh --no-upgrade   # install/switch only, upgrade nothing
#   rebuild.sh --allow-unmerged  # build what is on disk, even if not origin/main
#
# This script avoids blind sudo by showing exactly what will change
# before asking for root confirmation.

set -euo pipefail

# The whole script is main(), called on the last line: bash parses all of it
# before running any of it, so an edit to this file mid-run (the checkout sync
# below can fast-forward it) cannot splice new lines into the running one.
main() {

# Captured before anything else, for the re-exec after the checkout sync.
ORIG_ARGS=("$@")
SELF=""; SELF_SUM=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  SELF_SUM=$(cksum <"$SELF") || SELF_SUM=""
fi
REEXECED="${RH7_REBUILD_REEXECED:-}"
unset RH7_REBUILD_REEXECED

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
HOSTNAME=$(hostname -s)
AUTO_CONFIRM=false
BUILD_ONLY=false
PLAN_ONLY=false
FORCE_MAS=false
# Which declared outdated packages this run upgrades (see homebrew_plan):
#   critical — only dotfiles.homebrew.criticalUpgrades (modules/darwin/homebrew.nix)
#   all      — everything declared and outdated
#   none     — nothing; activation still installs missing packages
UPGRADE_MODE=critical
# Build/activate a checkout that is NOT origin/main (branch, dirty, ahead,
# offline). See scripts/lib/dotfiles-checkout.sh for why the default refuses.
ALLOW_UNMERGED=false
# Lets the /etc preflight overwrite an existing <file>.before-nix-darwin when
# it moves a recognised stock file aside (see etc_preflight). Nothing else.
FORCE=false
FLAKE_REF="${DOTFILES_DIR}#${HOSTNAME}"

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

# ── Cleanup ──
# ONE EXIT trap for the whole script. bash replaces a trap rather than adding to
# it, so a second `trap ... EXIT` further down would silently disable this one —
# every cleanup must be registered through here.
PLAN_TMP=""             # Homebrew plan scratch dir (step 4b)
MAS_TMP=""              # App Store scratch dir (declared_outdated_mas)
SUDO_KEEPALIVE_PID=""   # sudo timestamp refresher (step 5b)
SUDO_TOUCHED=false      # true once this script refreshes the sudo timestamp
cleanup() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$PLAN_TMP" && -d "$PLAN_TMP" ]]; then
    rm -rf "$PLAN_TMP"
  fi
  if [[ -n "$MAS_TMP" && -d "$MAS_TMP" ]]; then
    rm -rf "$MAS_TMP"
  fi
  # /etc files this run moved aside that nix-darwin has NOT yet replaced
  # (failed or interrupted run): say so and how to undo, on every exit path —
  # Ctrl-C included. Prints nothing once activation has linked them.
  if [[ -n "${ETC_RENAMED:-}" ]]; then
    etc_restore_hint || true
  fi
  # Close the sudo window immediately rather than letting the 5-minute default
  # lapse.
  #
  # This revokes even a timestamp that already existed when the script started.
  # That is deliberate: the keep-alive below runs `sudo -n -v` every 60s, so by
  # the end of a long rebuild ANY timestamp — pre-existing or not — has been
  # repeatedly renewed by this script and would outlive the run. An earlier
  # version skipped `sudo -k` for pre-existing timestamps on the theory that
  # they "belonged to something else"; the result was that it extended a
  # credential it declined to clean up, leaving a fresh global window open for
  # unrelated processes. Renewing it makes it ours to revoke.
  #
  # Cost of being wrong in this direction: an unrelated sudo elsewhere prompts
  # once more than it would have. That is the right way to be wrong.
  if $SUDO_TOUCHED; then
    sudo -k 2>/dev/null || true
  fi
}
# INT/TERM/HUP as well as EXIT: a Ctrl-C partway through a rebuild must still
# revoke the sudo window and remove the scratch dir. (SIGKILL cannot be caught —
# a `kill -9` leaves the timestamp to expire on its own 5-minute timeout.)
#
# The signal handlers only `exit`; they must NOT call cleanup themselves, since
# exiting fires the EXIT trap which does. Calling it in both places ran the
# whole cleanup — sudo -k, rm -rf, kill — twice per interrupt.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        AUTO_CONFIRM=true; shift ;;
    --build-only)    BUILD_ONLY=true; shift ;;
    --plan-only)     PLAN_ONLY=true; shift ;;
    --upgrade-mas)   FORCE_MAS=true; shift ;;
    --upgrade=*)     UPGRADE_MODE="${1#--upgrade=}"; shift ;;
    --upgrade)       UPGRADE_MODE="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --no-upgrade)    UPGRADE_MODE=none; shift ;;
    --allow-unmerged) ALLOW_UNMERGED=true; shift ;;
    --force)         FORCE=true; shift ;;
    --flake)         FLAKE_REF="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: rebuild.sh [--yes] [--upgrade=critical|all|none] [--build-only|--plan-only] [--allow-unmerged] [--force] [--flake REF]"
      echo ""
      echo "  --yes, -y      Auto-confirm (skip interactive approval). Skips"
      echo "                 App Store upgrades unless --upgrade-mas is given,"
      echo "                 since those must not run unattended. It does NOT"
      echo "                 answer the first-adoption fix questions (flakes,"
      echo "                 Homebrew owner, /etc files): those stop the run."
      echo "  --upgrade-mas  Upgrade declared App Store apps even with --yes."
      echo "                 Only pass this when you are at the machine."
      echo "  --upgrade=MODE Which declared outdated packages to upgrade:"
      echo "                   critical  (default) only the curated list in"
      echo "                             modules/darwin/homebrew.nix"
      echo "                   all       everything declared and outdated"
      echo "                   none      nothing (same as --no-upgrade)"
      echo "  --no-upgrade   Install missing packages and switch; upgrade nothing."
      echo "  --build-only   Build only, don't activate"
      echo "  --plan-only    Show the Homebrew upgrade plan only — no build, no"
      echo "                 activation, no upgrades, no root. Does refresh brew"
      echo "                 metadata (network + Homebrew repo state). Run from"
      echo "                 another account than system.primaryUser, it takes"
      echo "                 one authentication to run Homebrew as that user."
      echo "  --allow-unmerged"
      echo "                 Build/activate the checkout as it is on disk even"
      echo "                 when it is not clean main at origin/main (feature"
      echo "                 branch, local edits, unpushed commits, or offline)."
      echo "                 The machine then runs UNMERGED config, and the drift"
      echo "                 audit compares against it. Default: refuse."
      echo "  --force        Only for the /etc preflight: when moving a recognised"
      echo "                 /etc file aside, overwrite an existing"
      echo "                 <file>.before-nix-darwin (refused by default)."
      echo "  --flake REF    Override flake reference (default: ~/dotfiles#\$HOSTNAME)"
      echo ""
      echo "Logs: every run is mirrored to \$REBUILD_LOG_DIR (default:"
      echo "  ~/.local/state/dotfiles/rebuild/) as <host>-<timestamp>.log."
      echo "  Last 20 per host retained."
      exit 0
      ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$UPGRADE_MODE" in
  critical|all|none) ;;
  *) err "--upgrade must be critical, all or none (got '${UPGRADE_MODE}')"; exit 1 ;;
esac

# Rejected rather than silently resolved: --plan-only short-circuits before the
# build, so passing both would quietly ignore --build-only.
if $BUILD_ONLY && $PLAN_ONLY; then
  err "--build-only and --plan-only are mutually exclusive"
  exit 1
fi

# A fragmentless --flake (`path`, `path#`) means this host. Pinned once, here,
# so the Homebrew plan's evaluations and the build/switch target the same
# configuration (darwin-rebuild would otherwise pick LocalHostName, which can
# differ from `hostname -s`).
if [[ "$FLAKE_REF" != *#* || "$FLAKE_REF" == *# ]]; then
  FLAKE_REF="${FLAKE_REF%#}#${HOSTNAME}"
fi

# ── Log file ──
# Mirror full output to ~/.local/state/dotfiles/rebuild/ so failures from brew
# bundle / activation can be grepped after the fact. Keeps last 20 per host.
LOG_DIR="${REBUILD_LOG_DIR:-$HOME/.local/state/dotfiles/rebuild}"
mkdir -p "$LOG_DIR"
if [[ -n "$REEXECED" && -n "${RH7_REBUILD_LOG_FILE:-}" ]]; then
  # Re-executed after the sync updated this script: stdout/stderr still go
  # through the first run's tee, into its log — keep that one log per run.
  LOG_FILE="$RH7_REBUILD_LOG_FILE"
else
  LOG_FILE="$LOG_DIR/${HOSTNAME}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi
unset RH7_REBUILD_LOG_FILE
while IFS= read -r _old_log; do rm -f "$_old_log"; done < <(
  ls -1t "$LOG_DIR/${HOSTNAME}-"*.log 2>/dev/null | tail -n +21
)

OS=$(uname -s)

# Idempotent so both the plan and the post-activation MAS step can call it.
# Checked explicitly so a missing helper reports itself rather than dying on an
# opaque "source: no such file" from `set -e`.
DECLARED_LIB_SOURCED=false
ensure_declared_lib() {
  if $DECLARED_LIB_SOURCED; then return 0; fi
  local lib="$DOTFILES_DIR/scripts/lib/declared-packages.sh"
  if [[ ! -r "$lib" ]]; then
    err "Helper not found at $lib"
    exit 1
  fi
  # shellcheck source=lib/declared-packages.sh
  source "$lib"
  DECLARED_LIB_SOURCED=true
}

# ── jq ──
# The cask plan, the declared-package helpers and the drift audit all need jq,
# and a household Mac's profile installs no CLI tools — so instead of skipping
# those checks, take jq from nixpkgs for this run. PATH is exported so the
# drift audit (a child process) sees it too.
ensure_jq() {
  if command -v jq &>/dev/null; then return 0; fi
  info "jq not found — taking it from nixpkgs for this run (nix shell nixpkgs#jq)..."
  local jq_path
  if jq_path=$(nix --extra-experimental-features 'nix-command flakes' \
       shell nixpkgs#jq -c sh -c 'command -v jq' 2>/dev/null) \
     && [[ -n "$jq_path" && -x "$jq_path" ]]; then
    PATH="$(dirname "$jq_path"):$PATH"
    export PATH
    return 0
  fi
  warn "Could not get jq from nixpkgs — the cask plan and drift audit will be incomplete"
  return 1
}

# ── Homebrew owner: rebuilding from ANOTHER account than system.primaryUser ──
# nix-darwin runs `brew bundle` as system.primaryUser, so on a household Mac
# (primaryUser = the daily user) /opt/homebrew belongs to her — and the owner
# rebuilds from his own admin account. Homebrew run as him would then fail on
# her prefix, or worse, create files there she can no longer update. So when
# the evaluated primaryUser differs from the invoking user, EVERY Homebrew
# command of this run (plan, adoption, upgrades, retirement) runs as her via
# `sudo -u <primary> -H` — the same form nix-darwin's activation uses — inside
# the run's one authentication. The same-user path is untouched: `brew` stays
# the plain command and nothing below runs.
#
# The prefix must be hers. Checked before anything else (before the plan, the
# drift audit and the build): a foreign-owned prefix fails halfway through
# activation otherwise, so setup_brew_user offers the chown, or stops.
PRIMARY_USER=""
BREW_AS_PRIMARY=false
BREW_BIN=""

# host_flake_ref — FLAKE_REF with a missing or empty fragment (`path` /
# `path#`) resolved to this host, exactly as build_darwin_system resolves it.
# Otherwise a fragment-less --flake would evaluate nothing below and silently
# fall back to running Homebrew as the invoker.
host_flake_ref() {
  local dir="${FLAKE_REF%%#*}" host=""
  [[ "$FLAKE_REF" == *#* ]] && host="${FLAKE_REF#*#}"
  printf '%s#%s\n' "$dir" "${host:-$HOSTNAME}"
}

# eval_failed <what> <stderr-file> — a configuration value this run depends on
# could not be evaluated. Fatal, never a guess: falling back (e.g. to running
# Homebrew as the invoker) turned one eval error into every brew step failing.
eval_failed() {
  err "Could not evaluate $1 for $(host_flake_ref). Nothing was built or changed."
  if [[ -s "$2" ]]; then
    err "nix said (first 20 lines):"
    head -20 "$2" | sed 's/^/          /' >&2
  fi
}

# eval_primary_user — prints system.primaryUser of the configuration; on any
# failure (or an empty value) prints the nix error and returns 1.
eval_primary_user() {
  local ref dir host errf out rc=0
  ref=$(host_flake_ref); dir="${ref%#*}"; host="${ref##*#}"
  errf=$(mktemp)
  out=$(nix eval --raw "${dir}#darwinConfigurations.\"${host}\".config.system.primaryUser" 2>"$errf") || rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    [[ $rc -ne 0 ]] || echo "(evaluated to an empty string)" >>"$errf"
    eval_failed system.primaryUser "$errf"
    rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  printf '%s' "$out"
}

# homebrew_enable_failed <flake_ref> — homebrew_managed answered "unknown" (2).
# Re-runs the evaluation only to show why, then exits: whether brew runs at
# all, and as whom, must never be guessed.
homebrew_enable_failed() {
  local dir="${1%#*}" host="${1##*#}" errf out
  errf=$(mktemp)
  if out=$(nix eval --json "${dir}#darwinConfigurations.\"${host}\".config.homebrew.enable" 2>"$errf"); then
    echo "(evaluated to '$out', not true/false)" >>"$errf"
  fi
  eval_failed homebrew.enable "$errf"
  rm -f "$errf"
  exit 1
}

# ── First-adoption fixes ──
# Three things a freshly-Nix-installed Mac reliably has wrong, each of which
# used to stop the run (or fail activation) with a command to paste:
# experimental features off, a Homebrew prefix owned by the wrong account, and
# installer-modified /etc shell files nix-darwin refuses to replace. rebuild.sh
# now fixes each one itself after ONE explicit question (default No), inside
# the run's single authentication. --plan-only / --build-only only report them.
#
# Paths are globals so the tests can point them at a temp root.
NIX_CONF=/etc/nix/nix.conf
ETC_DIR=/etc
PROMPT_TTY=/dev/tty
# `extra-`: ADDS to whatever list is in effect (an existing line, an
# !include), never replaces it — a plain `experimental-features` line appended
# last would silently drop features set elsewhere.
FLAKES_LINE='extra-experimental-features = nix-command flakes'

# ask_fix <question> — 0 only on an explicit y/Y. --yes does not count: these
# change system files, and its premise ("nothing here needs a human") is the
# opposite of a first adoption. An unreadable terminal reads as No.
ask_fix() {
  local answer=""
  if $AUTO_CONFIRM; then
    warn "--yes does not answer this question — treating it as No."
    return 1
  fi
  echo -en "${BOLD}  $1 [y/N] ${NC}"
  { read -r answer <"$PROMPT_TTY"; } 2>/dev/null || answer=""
  echo ""
  [[ "$answer" == y || "$answer" == Y ]]
}

# nix_missing_features — prints which of nix-command/flakes are off
# (space-separated), nothing when both are on. Probed WITHOUT the flag (the
# flag would show up in the answer); an error naming the feature as disabled
# is the "off" signal.
nix_missing_features() {
  local out feats="" missing=""
  if out=$(nix config show experimental-features 2>&1); then
    feats="$out"
  elif [[ "$out" != *"experimental Nix feature 'nix-command' is disabled"* ]] \
    && out=$(nix show-config 2>&1); then
    # Nix older than `nix config show`.
    feats=$(awk -F' = ' '$1 == "experimental-features" { print $2 }' <<<"$out")
  fi
  [[ " $feats " == *" nix-command "* ]] || missing+=" nix-command"
  [[ " $feats " == *" flakes "* ]] || missing+=" flakes"
  echo "${missing# }"
}

# restart_nix_daemon — so the daemon picks up the changed nix.conf too.
restart_nix_daemon() {
  if [[ "$OS" == Darwin ]]; then
    sudo -n launchctl kickstart -k system/org.nixos.nix-daemon
  else
    sudo -n systemctl restart nix-daemon
  fi
}

# nix_conf_append — appends FLAKES_LINE as root, on a line of its own.
nix_conf_append() {
  local sep=""
  if [[ -s "$NIX_CONF" && -n "$(tail -c 1 "$NIX_CONF")" ]]; then sep=$'\n'; fi
  printf '%s%s\n' "$sep" "$FLAKES_LINE" | sudo -n tee -a "$NIX_CONF" >/dev/null
}

# require_nix_features — before any flake evaluation, nix-command and flakes
# must be on. The official installer leaves both off, and on macOS nothing
# turns them on later: the darwin config sets nix.enable = false, so nix-darwin
# never writes /etc/nix/nix.conf (only NixOS sets
# nix.settings.experimental-features). Fixing the config — rather than passing
# --extra-experimental-features to rebuild.sh's own nix calls — also covers the
# nix calls in the libs/scripts it runs, darwin-rebuild, and every later
# interactive `nix` use.
#
# Appends `extra-experimental-features` (see FLAKES_LINE), at the end so it
# follows any !include — but only when nix.conf does not set that exact key
# yet (then the existing line is the one to edit), and never into a symlinked
# nix.conf (NixOS, nix-darwin-managed), which is not ours to edit.
require_nix_features() {
  local missing restart can_append=true nl=$'\n'
  missing=$(nix_missing_features)
  [[ -n "$missing" ]] || return 0
  if [[ "$OS" == Darwin ]]; then restart="launchctl kickstart -k system/org.nixos.nix-daemon"
  else restart="systemctl restart nix-daemon"; fi
  if [[ -L "$NIX_CONF" ]] \
     || grep -qE '^[[:space:]]*extra-experimental-features[[:space:]]*=' "$NIX_CONF" 2>/dev/null; then
    can_append=false
  fi
  warn "Nix experimental feature(s) not enabled: $missing (the official installer leaves them off)."
  if $PLAN_ONLY; then
    if $can_append; then
      info "  will fix: rebuild.sh (without --plan-only) offers to append '$FLAKES_LINE'"
      info "  to $NIX_CONF and restart nix-daemon."
    else
      warn "  rebuild.sh will STOP here: $NIX_CONF already sets extra-experimental-features (or is a symlink) — edit it by hand."
    fi
    # The preview itself evaluates the flake: enable them for this process
    # only. NIX_CONFIG is read by every nix command this run spawns.
    NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$nl}extra-experimental-features = nix-command flakes"
    export NIX_CONFIG
    echo ""
    return 0
  fi
  if $can_append; then
    echo "    Fix (as root): append '$FLAKES_LINE' to $NIX_CONF, then $restart"
    if ask_fix "Enable them now?"; then
      authenticate_once "Nothing was evaluated, built or changed."
      if ! nix_conf_append; then
        err "Could not append to $NIX_CONF. Nothing was evaluated, built or changed."
        exit 1
      fi
      restart_nix_daemon || warn "Could not restart nix-daemon ($restart) — continuing; the client reads $NIX_CONF itself."
      missing=$(nix_missing_features)
      if [[ -n "$missing" ]]; then
        err "Still not enabled after the change: $missing. Check $NIX_CONF (and any !include). Nothing was built or changed."
        exit 1
      fi
      ok "nix-command and flakes enabled in $NIX_CONF"
      echo ""
      return 0
    fi
    err "Nix experimental feature(s) not enabled: $missing. Nothing was evaluated, built or changed."
    err "Enable them once, then open a new terminal and re-run:"
    err "    echo '$FLAKES_LINE' | sudo tee -a $NIX_CONF && sudo $restart"
  else
    err "Nix experimental feature(s) not enabled: $missing. Nothing was evaluated, built or changed."
    err "$NIX_CONF already sets extra-experimental-features (or is a symlink), so rebuild.sh"
    err "will not add a second one. Add 'nix-command flakes' to that setting by hand, run"
    err "'sudo $restart', open a new terminal and re-run."
  fi
  if [[ "$OS" != Darwin ]]; then
    err "  (NixOS hosts get this from nix.settings.experimental-features after their first switch.)"
  fi
  exit 1
}

# brew_prefix — the Homebrew prefix on this Mac, or empty when there is none.
# Derived from where `brew` is (<prefix>/bin/brew; on Intel /usr/local/bin/brew
# is a symlink, and its own location is still the prefix), not by running it:
# cross-user, no Homebrew command may run as the invoker.
brew_prefix() {
  local b p
  if b=$(command -v brew 2>/dev/null) && [[ "$b" == /* ]]; then
    dirname "$(dirname "$b")"; return 0
  fi
  for p in /opt/homebrew /usr/local; do
    if [[ -x "$p/bin/brew" ]]; then echo "$p"; return 0; fi
  done
  return 1
}

# brew_owned_dirs <prefix> — the trees Homebrew writes to, i.e. what must be
# PRIMARY_USER's. The whole prefix on Apple Silicon; on Intel /usr/local itself
# (and its bin/, shared with other installers) is root's, so only Homebrew's
# own trees count there.
brew_owned_dirs() {
  local prefix="$1" d
  if [[ "$prefix" != /usr/local ]]; then echo "$prefix"; return 0; fi
  for d in "$prefix/Homebrew" "$prefix/Cellar" "$prefix/Caskroom" "$prefix/var/homebrew"; do
    if [[ -e "$d" ]]; then echo "$d"; fi
  done
}

# brew_prefix_foreign <prefix> — paths ANYWHERE in those trees not owned by
# PRIMARY_USER; nothing when all are hers. First line "<count><TAB><owners>"
# (owners comma-separated), then "<path> (owner)" for the first 5 and
# "… and N more". Nested paths count: one foreign tap, keg or
# Library/Homebrew is enough for `brew update` or an install to fail later,
# after the authentication — so the whole tree is walked, once, up front.
brew_prefix_foreign() {
  local prefix="$1" d dirs=()
  while IFS= read -r d; do dirs+=("$d"); done < <(brew_owned_dirs "$prefix")
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  # `|| true`: an unreadable subtree must not abort the run under `set -e`;
  # what find could read is still reported.
  { find "${dirs[@]}" -xdev -exec stat -f '%Su %N' {} + 2>/dev/null || true; } \
    | awk -v u="$PRIMARY_USER" '
        { owner = $1; path = substr($0, length($1) + 2) }
        owner != u {
          n++; if (n <= 5) shown[n] = path " (" owner ")"
          if (!(owner in seen)) { seen[owner] = 1; owners = owners (owners == "" ? "" : ", ") owner }
        }
        END {
          if (n == 0) exit
          print n "\t" owners
          for (i = 1; i <= n && i <= 5; i++) print shown[i]
          if (n > 5) print "… and " n - 5 " more"
        }'
}

# brew_as_primary <args...> — Homebrew as PRIMARY_USER. `sudo -n`: it runs
# only inside the run's authentication (authenticate_once), so it can fail but
# never prompt. From / because the invoker's cwd (~/dotfiles in HIS home) may
# not be readable by her. sudo resets the environment, so the HOMEBREW_*
# switches this script sets are passed through explicitly.
brew_as_primary() {
  local envs=() v
  for v in HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP HOMEBREW_NO_ENV_HINTS; do
    if [[ -n "${!v:-}" ]]; then envs+=("$v=${!v}"); fi
  done
  ( cd / && exec sudo -n -u "$PRIMARY_USER" -H env ${envs[@]+"${envs[@]}"} "$BREW_BIN" "$@" )
}

# setup_brew_user — decides who runs Homebrew. Cross-user, a prefix the
# primary user does not own is offered a chown (one question); declined, the
# run stops before anything is built.
setup_brew_user() {
  [[ "$OS" == Darwin ]] || return 0
  local invoker prefix foreign count owners dirs managed_rc=0
  invoker=$(id -un)
  if ! PRIMARY_USER=$(eval_primary_user); then
    exit 1
  fi
  [[ "$PRIMARY_USER" != "$invoker" ]] || return 0
  ensure_declared_lib
  homebrew_managed "$(host_flake_ref)" || managed_rc=$?
  # homebrew.enable = false (1): nothing runs brew for her. Unknown (2) is
  # fatal — running brew as the wrong account is what this guards against.
  [[ $managed_rc -ne 2 ]] || homebrew_enable_failed "$(host_flake_ref)"
  [[ $managed_rc -ne 1 ]] || return 0
  if ! prefix=$(brew_prefix) || [[ -z "$prefix" ]]; then
    return 0   # no Homebrew yet: nothing to own or to run as her
  fi
  foreign=$(brew_prefix_foreign "$prefix")
  if [[ -n "$foreign" ]]; then
    IFS=$'\t' read -r count owners <<<"$(head -1 <<<"$foreign")"
    dirs=$(brew_owned_dirs "$prefix" | xargs)
    warn "This configuration's system.primaryUser is '$PRIMARY_USER' (you are '$invoker')."
    warn "nix-darwin runs Homebrew as $PRIMARY_USER, but $count path(s) under $prefix belong to $owners:"
    tail -n +2 <<<"$foreign" | sed 's/^/          /'
    warn "Left like this, Homebrew fails partway through activation."
    echo "    Fix (as root): chown -R $PRIMARY_USER:admin $dirs"
    echo "    Afterwards Homebrew belongs to $PRIMARY_USER: every other account (you included) runs"
    echo "    it as 'sudo -u $PRIMARY_USER brew …' — a plain 'brew' from another account fails."
    if $PLAN_ONLY || $BUILD_ONLY; then
      info "  will fix: rebuild.sh offers this chown before the plan of a full run."
      echo ""
    elif ask_fix "Hand Homebrew to $PRIMARY_USER now (chown -R $PRIMARY_USER:admin $dirs)?"; then
      authenticate_once "Nothing was built or changed."
      # shellcheck disable=SC2086  # $dirs: one or more prefix trees, no spaces
      if ! sudo -n chown -R "$PRIMARY_USER:admin" $dirs; then
        err "chown failed. Nothing was built or changed."
        exit 1
      fi
      foreign=$(brew_prefix_foreign "$prefix")
      if [[ -n "$foreign" ]]; then
        err "Still not owned by $PRIMARY_USER after the chown:"
        tail -n +2 <<<"$foreign" | sed 's/^/          /' >&2
        err "Nothing was built or changed."
        exit 1
      fi
      ok "Homebrew under $prefix now belongs to $PRIMARY_USER"
      echo ""
    else
      err "Nothing was built or changed. Fix, then re-run:"
      err "    sudo chown -R $PRIMARY_USER:admin $dirs"
      err "Afterwards other accounts run Homebrew as $PRIMARY_USER:"
      err "    sudo -u $PRIMARY_USER brew …"
      exit 1
    fi
  fi
  BREW_BIN="$prefix/bin/brew"
  BREW_AS_PRIMARY=true
  # Every `brew` below — plan, adoption, upgrades, retirement — goes through
  # this. Defined only on this path, so the same-user run keeps the command.
  brew() { brew_as_primary "$@"; }
  info "system.primaryUser is '$PRIMARY_USER', you are '$invoker': every Homebrew command"
  info "  in this run runs as $PRIMARY_USER (sudo -u $PRIMARY_USER -H), inside its one authentication."
  echo ""
}

# ── One authentication for the whole run ──
# Without this, the prompts arrive one-per-root-requiring-cask from inside
# `brew bundle` (nix-darwin drops root back to the user to run brew), each
# giving no clue what it is for. Authenticating once — after the plan, or
# before it when Homebrew must run as the primary user — means the single
# prompt you get is one you can actually attribute.
#
# Requires `Defaults:<user> timestamp_type=global` to cover brew's children;
# see modules/darwin/sudo-rebuild.nix. Without that module this still works,
# it just may not suppress every downstream prompt.
#
# Idempotent: the second call (Step 5b after a cross-user plan) is a no-op.
# <hint> is printed after a failed or cancelled authentication.
SUDO_AUTHENTICATED=false
authenticate_once() {
  local hint="${1:-}"
  if $SUDO_AUTHENTICATED; then return 0; fi
  # Set BEFORE the first sudo call, not after. Setting it afterwards left a
  # race: a signal arriving between a successful `sudo -v` and the assignment
  # would run cleanup with SUDO_TOUCHED still false, leaving a just-renewed
  # timestamp live. Claiming it early is the safe direction — if we die before
  # sudo ever succeeds, the worst case is a `sudo -k` that revokes nothing (or
  # costs one extra prompt).
  SUDO_TOUCHED=true
  if sudo -n true 2>/dev/null; then
    info "sudo already authenticated — no prompt needed"
  else
    info "Authenticating once for the entire rebuild (Touch ID)..."
    if ! sudo -v; then
      err "Authentication failed or cancelled — nothing was applied."
      if [[ -n "$hint" ]]; then err "$hint"; fi
      exit 1
    fi
  fi
  # Refresh the timestamp every 60s so a long run (large casks, multi-GB MAS
  # downloads) never lapses mid-flight and re-prompts. Dies with this script
  # via the EXIT trap, and self-exits if the parent disappears or sudo is
  # revoked.
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n -v 2>/dev/null || exit 0
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  SUDO_AUTHENTICATED=true
  ok "Authenticated — you should not be prompted again for this run"
  echo ""
}

# ── /etc files nix-darwin will refuse to replace ──
# nix-darwin's activation `checks` (modules/system/etc.nix in the pinned
# nix-darwin) abort the WHOLE activation with "Unexpected files in /etc" when
# a file the configuration links into /etc exists, is not already its
# /etc/static link, and its sha256 is not in that entry's knownSha256Hashes
# (the stock macOS files plus a few installer-modified ones). It only ever
# moved files with a KNOWN hash aside itself. On kassie-mbp-m1 /etc/bashrc and
# /etc/zshrc were stock macOS plus the official Nix installer's
# `# Nix` … `# End Nix` block in a layout the list does not cover — and the
# failure came AFTER 25 apps had been replaced. So the same rule runs here,
# from the evaluated configuration (no build needed, so --plan-only sees it),
# before anything is changed:
#   - stock + only the installer block (the block removed, the rest hashes to
#     one of nix-darwin's own known hashes) → offer to move it to
#     <file>.before-nix-darwin, exactly what nix-darwin asks for. The move
#     happens after the switch is confirmed, inside its one authentication,
#     BEFORE any app is replaced: moving /etc/zshrc earlier would drop nix
#     from new shells' PATH for a run the user may still cancel.
#   - anything else → stop now, with the unexpected lines and the manual step.
ETC_RENAMES=""   # "<path><TAB><sha256>" lines confirmed for moving aside
ETC_RENAMED=""   # paths actually moved (for the restore hint)
ETC_MATCH_EB=0; ETC_MATCH_EA=0   # blank-line variant that matched (see below)

# etc_managed_targets — "<target><TAB><known hashes>" for every enabled
# environment.etc entry: exactly the links nix-darwin's check walks.
etc_managed_targets() {
  local ref dir host errf out rc=0
  ref=$(host_flake_ref); dir="${ref%#*}"; host="${ref##*#}"
  errf=$(mktemp)
  out=$(nix eval --raw "${dir}#darwinConfigurations.\"${host}\".config.environment.etc" --apply \
    'etc: builtins.concatStringsSep "" (map (f: f.target + "\t" + builtins.concatStringsSep " " f.knownSha256Hashes + "\n") (builtins.filter (f: f.enable) (builtins.attrValues etc)))' \
    2>"$errf") || rc=$?
  if [[ $rc -ne 0 ]]; then
    eval_failed environment.etc "$errf"
    rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  printf '%s' "$out"
}

sha256_of() { local o; o=$(shasum -a 256 "$1") || return 1; echo "${o%% *}"; }

# nix_block_stripped <file> <eat_blank_before> <eat_blank_after> — the file
# without the official Nix installer's block(s); fails (printing nothing) if
# there is none or a block holds anything but the installer's nix-daemon.sh
# sourcing. The installer prepends (current) or appends (older) the block
# with blank lines around it, hence the blank-line variants.
nix_block_stripped() {
  awk -v eb="$2" -v ea="$3" -v q="'" '
    BEGIN {
      re_if  = "^if \\[ -e " q "[^" q "]*/nix-daemon\\.sh" q " \\]; then$"
      re_src = "^[ \t]*\\. " q "[^" q "]*/nix-daemon\\.sh" q "$"
    }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (!inb) {
          if (line[i] == "# Nix") { inb = 1; start = i }
          continue
        }
        if (line[i] == "# End Nix") {
          inb = 0; blocks++
          for (j = start; j <= i; j++) drop[j] = 1
          if (eb && start > 1 && line[start - 1] == "") drop[start - 1] = 1
          if (ea && i < NR && line[i + 1] == "") drop[i + 1] = 1
        } else if (line[i] !~ re_if && line[i] !~ re_src && line[i] != "fi") {
          bad = 1
        }
      }
      if (inb || !blocks || bad) exit 1
      for (i = 1; i <= NR; i++) if (!(i in drop)) print line[i]
    }' "$1"
}

# etc_stock_with_nix_block <file> <known hashes> — 0 when the file minus the
# installer block hashes to one of nix-darwin's known hashes for it; sets
# ETC_MATCH_EB/EA to the variant that matched.
etc_stock_with_nix_block() {
  local f="$1" known=" $2 " eb ea h
  nix_block_stripped "$f" 0 0 >/dev/null 2>&1 || return 1
  for eb in 0 1; do
    for ea in 0 1; do
      h=$(nix_block_stripped "$f" "$eb" "$ea" | shasum -a 256) || continue
      if [[ "$known" == *" ${h%% *} "* ]]; then
        ETC_MATCH_EB=$eb; ETC_MATCH_EA=$ea
        return 0
      fi
    done
  done
  return 1
}

# etc_body <file> — its content outside a well-formed installer block.
etc_body() { nix_block_stripped "$1" 1 1 2>/dev/null || cat "$1"; }

# etc_unexpected_lines <file> — what is in it beyond a stock file: a diff
# against the official installer's own backup of the original
# (<file>.backup-before-nix) when there is one, else the content itself.
etc_unexpected_lines() {
  local f="$1" ref="$1.backup-before-nix"
  if [[ -f "$f" && -f "$ref" ]]; then
    echo "      Differences from the Nix installer's backup of the original ($ref):"
    { diff "$ref" <(etc_body "$f") | sed -n 's/^< \{0,1\}/      - /p; s/^> \{0,1\}/      + /p' | head -40; } || true
  elif [[ -f "$f" ]]; then
    echo "      No stock file has this checksum and there is no installer backup ($ref)"
    echo "      to compare with. Its content (outside a Nix installer block):"
    { etc_body "$f" | head -40 | sed 's/^/      | /'; } || true
  else
    echo "      Not a regular file ($(stat -f %HT "$f" 2>/dev/null || echo unknown type)) — nix-darwin rejects it unconditionally."
  fi
}

# etc_restore_hint — for each file this run moved aside, if its replacement
# link is still missing (activation never reached nix-darwin's etc phase),
# how to undo the move. A path nix-darwin already re-linked is left alone:
# restoring the old file over the managed link would be wrong. Called from
# cleanup (the EXIT trap), so it covers failures and interrupts alike.
etc_restore_hint() {
  local f missing=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -e "$f" || -L "$f" ]] || missing+="$f"$'\n'
  done <<<"$ETC_RENAMED"
  [[ -n "$missing" ]] || return 0
  warn "Moved aside this run and NOT yet replaced by nix-darwin (new shells may lack nix on PATH):"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "      $f → $f.before-nix-darwin"
  done <<<"$missing"
  warn "Re-run rebuild.sh to finish the switch, or undo with:"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    echo "      sudo mv $f.before-nix-darwin $f"
  done <<<"$missing"
}

# etc_preflight — classifies every /etc file nix-darwin's check would reject;
# asks once to move the recognised ones aside, stops on anything else.
# --plan-only / --build-only only report.
etc_preflight() {
  [[ "$OS" == Darwin ]] || return 0
  local targets t known f h dest fixable="" stop=false preview=false
  if $PLAN_ONLY || $BUILD_ONLY; then preview=true; fi
  if ! targets=$(etc_managed_targets); then exit 1; fi
  while IFS=$'\t' read -r t known; do
    [[ -n "$t" ]] || continue
    f="$ETC_DIR/$t"; h=""
    # The same rule as nix-darwin's check, in the same order.
    [[ -e "$f" ]] || continue
    [[ "$(readlink "$f" 2>/dev/null)" != "$ETC_DIR/static/$t" ]] || continue
    if [[ -f "$f" ]]; then
      h=$(sha256_of "$f") || h=""
      # Known hash: nix-darwin moves it aside itself.
      if [[ -n "$h" && " $known " == *" $h "* ]]; then continue; fi
    fi
    dest="$f.before-nix-darwin"
    if [[ -n "$h" ]] && etc_stock_with_nix_block "$f" "$known"; then
      warn "$f: stock macOS file + the Nix installer's block — nix-darwin would abort activation on it."
      echo "      Differs from the stock file only by:"
      { diff <(nix_block_stripped "$f" "$ETC_MATCH_EB" "$ETC_MATCH_EA") "$f" \
          | sed -n 's/^> \{0,1\}/      + /p'; } || true
      if [[ -e "$dest" || -L "$dest" ]] && { ! $FORCE || [[ -d "$dest" ]]; }; then
        err "  $dest already exists — refusing to overwrite it."
        err "  Compare it (diff $dest $f), remove or rename it yourself, or re-run with --force to overwrite it."
        stop=true
      else
        fixable+="$f"$'\t'"$h"$'\n'
      fi
    else
      warn "$f: unexpected content — nix-darwin would abort activation on it."
      etc_unexpected_lines "$f"
      err "  Keep what you need from it elsewhere, then move it aside yourself and re-run:"
      err "    sudo mv $f $dest"
      stop=true
    fi
  done <<<"$targets"
  if $stop; then
    if $preview; then
      warn "rebuild.sh will STOP before changing anything until the /etc file(s) above are dealt with."
      echo ""
      return 0
    fi
    err "Nothing was built or changed. Deal with the /etc file(s) above, then re-run."
    exit 1
  fi
  [[ -n "$fixable" ]] || return 0
  if $preview; then
    info "  will fix: rebuild.sh offers to move them to *.before-nix-darwin before activation."
    echo ""
    return 0
  fi
  if ask_fix "Move them aside (sudo mv <file> <file>.before-nix-darwin) after you confirm the switch?"; then
    ETC_RENAMES="$fixable"
    info "They are moved inside the run's one authentication, before any app is replaced."
    echo ""
    return 0
  fi
  err "Not moved — nix-darwin would abort activation on them. Nothing was built or changed."
  err "Move them aside yourself, then re-run:"
  while IFS=$'\t' read -r f h; do
    [[ -n "$f" ]] && err "    sudo mv $f $f.before-nix-darwin"
  done <<<"$fixable"
  exit 1
}

# etc_apply_renames — performs the confirmed moves. Re-checks each file first
# (unchanged since it was classified, destination still free), and stops on
# any failure before an app is replaced or activation starts.
etc_apply_renames() {
  local f h dest now
  [[ -n "$ETC_RENAMES" ]] || return 0
  while IFS=$'\t' read -r f h; do
    [[ -n "$f" ]] || continue
    dest="$f.before-nix-darwin"
    now=$(sha256_of "$f" 2>/dev/null) || now=""
    if [[ "$now" != "$h" ]]; then
      err "$f changed since it was checked — not moving it. Stopping before any app is replaced or activation."
      exit 1
    fi
    if [[ -e "$dest" || -L "$dest" ]] && { ! $FORCE || [[ -d "$dest" ]]; }; then
      err "$dest appeared since the check — not overwriting it. Stopping before any app is replaced or activation."
      exit 1
    fi
    if ! sudo -n mv -f "$f" "$dest"; then
      err "Could not move $f. Stopping before any app is replaced or activation."
      exit 1
    fi
    ETC_RENAMED+="$f"$'\n'
    ok "$f → $dest"
  done <<<"$ETC_RENAMES"
  echo ""
}

# ── Declared Mac App Store apps that are outdated ────────────────────────────
# Prints one id per line. Returns nonzero if state could not be determined, so
# callers can distinguish "nothing to upgrade" from "could not tell".
#
# WHY THIS LIVES IN rebuild.sh AND NOT THE WEEKLY AGENT:
# `mas_install` in postActivation only installs apps that are MISSING — it never
# upgrades — so declared App Store apps were installed once and then never
# updated again. The obvious fix was to put `mas upgrade` in the weekly
# LaunchAgent, and that is WRONG: mas 7.0.0 spawns /usr/bin/sudo internally for
# update operations (verified — `/usr/bin/sudo` and "Requires root privileges to
# install apps" are both embedded in the installed Mach-O). Running it
# unattended while rebuild.sh holds a user-global sudo timestamp open would let
# it silently consume that credential, which is exactly why cask upgrades were
# removed from that agent. One app upgrading without a prompt does not prove
# otherwise — the capability is what matters, not a single observation.
#
# Here the situation is different in the way that counts: a human ran this,
# saw the plan, and authenticated deliberately. Same treatment as casks.
# Result is returned via the MAS_OUTDATED global, NOT stdout. That is not
# stylistic: callers used `x=$(declared_outdated_mas)`, which runs the function
# in a SUBSHELL, so its `MAS_TMP=` assignment never reached the parent and the
# shared EXIT trap could not clean the directory after an early return. Setting
# a global keeps the function in the parent shell, where the trap works.
MAS_OUTDATED=""
declared_outdated_mas() {
  MAS_OUTDATED=""
  # Indirected so the "mas missing" branch is reachable in tests; `mas` lives in
  # the same dir as `brew`, so it cannot be hidden via PATH without also
  # breaking brew.
  local mas_bin="${REBUILD_MAS_BIN:-mas}"
  if ! command -v "$mas_bin" &>/dev/null; then
    return 2   # distinct from "none outdated"; caller reports it
  fi
  ensure_declared_lib

  # This function is called twice (plan, then post-activation). If the first
  # call failed it deliberately left its directory for the EXIT trap — so clear
  # it BEFORE allocating another, or the second assignment orphans the first
  # beyond the trap's reach.
  if [[ -n "$MAS_TMP" && -d "$MAS_TMP" ]]; then
    rm -rf "$MAS_TMP"
  fi
  MAS_TMP=$(mktemp -d -t rebuild-mas.XXXXXX) || return 1

  if ! "$mas_bin" outdated 2>/dev/null | awk '{print $1}' >"$MAS_TMP/outdated"; then
    return 1   # dir left for the EXIT trap, which can now see it
  fi
  if ! declared_mas_ids "$(host_flake_ref)" >"$MAS_TMP/declared"; then
    return 1
  fi

  # Status captured explicitly: ending on `rm` would have returned the CLEANUP's
  # exit code, so a failed intersection would have looked like success.
  local rc=0
  MAS_OUTDATED=$(intersect_lines "$MAS_TMP/outdated" "$MAS_TMP/declared") || rc=1
  rm -rf "$MAS_TMP"; MAS_TMP=""
  return $rc
}

# ── Hand-installed apps and retired casks ──
# Two jobs that used to need hand-run, privileged commands — each one its own
# unexplained Touch ID prompt — and now happen inside the run's single
# authentication, listed in the plan beforehand:
#
#   ADOPT  — a newly declared cask whose app is ALREADY in /Applications,
#            installed by hand. `brew bundle` cannot take those over: its
#            --adopt refuses any version mismatch, and macOS App Management
#            blocks it from touching the bundle at all (see below). rebuild.sh
#            replaces them with `brew install --cask --force` BEFORE activation.
#   RETIRE — casks in dotfiles.homebrew.retiredCasks that are still installed.
#            cleanup = "none" never removes anything, so this list is the
#            fleet's only removal path. Uninstalled AFTER a successful switch.
#
# Results are globals, not stdout, for the same subshell reason as MAS_OUTDATED.
ADOPT_CASKS=""      # space-separated cask names to replace
ADOPT_APPS=""       # newline-separated app paths those casks will overwrite
ADOPT_BLOCKED=""    # newline-separated subset App Management currently blocks
RETIRE_CASKS=""     # space-separated cask names to uninstall
NEW_CASKS=""        # space-separated declared casks activation installs fresh

APP_MGMT_PANE="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"

# app_bundle_modifiable <app path>
# 0 = this process may modify the bundle, 1 = macOS App Management blocks it.
#
# App Management (macOS 13+) stops a process from modifying an app bundle it did
# not install unless its responsible app — the TERMINAL — holds that permission.
# Ownership is irrelevant and so is sudo: a user-owned, hand-installed Zen.app
# refused even `sudo chmod`, while VLC, installed by Homebrew, stays writable.
# Apple lets only the user (or an MDM profile) grant it, so the script cannot;
# what it can do is find out BEFORE asking for Touch ID instead of failing
# halfway through activation.
#
# The probe sets and removes an extended attribute on the bundle directory:
# blocked exactly like any other modification, and harmless when allowed (a
# non-com.apple xattr on the directory is not part of the code signature).
# Only EPERM counts as blocked. EACCES (a root-owned bundle) is a plain
# ownership error that the run's sudo-backed brew handles.
app_bundle_modifiable() {
  local app="$1" out
  if out=$(xattr -w com.rh7.dotfiles.probe 1 "$app" 2>&1); then
    xattr -d com.rh7.dotfiles.probe "$app" 2>/dev/null || true
    return 0
  fi
  [[ "$out" != *"Operation not permitted"* ]]
}

# cask_app_targets — cask names on stdin, prints "<cask><TAB><app path>" for
# each one that installs an .app. pkg-based casks have no app artifact and are
# skipped; their installers handle an existing copy themselves.
cask_app_targets() {
  local names
  names=$(awk 'NF' | tr '\n' ' ')
  [[ -n "$names" ]] || return 0
  # shellcheck disable=SC2086
  brew info --cask --json=v2 $names 2>/dev/null \
    | jq -r '.casks[] | .token as $t | .artifacts[] | select(has("app"))
             | (.target // ("/Applications/" + (.app[0] | strings)))
             | "\($t)\t\(.)"'
}

# cask_lifecycle_plan [declared_known] — fills the globals above. Reads
# PLAN_TMP/declared_casks from homebrew_plan; pass "false" when that evaluation
# failed and only the retirement half runs. Deliberately independent of the
# formula/upgrade plan: an unrelated `brew outdated` failure must not stop a
# retired cask's removal or let activation trip over a hand-installed copy.
# A failed inventory leaves the lists EMPTY and says so: not removing or
# replacing is the safe direction, guessing is not. Same for a host whose
# config does not manage Homebrew (homebrew.enable = false, the Studio): its
# casks are owned by hand, so this plan touches none of them.
cask_lifecycle_plan() {
  local declared_known="${1:-true}" managed_rc=0
  ADOPT_CASKS=""; ADOPT_APPS=""; ADOPT_BLOCKED=""; RETIRE_CASKS=""; NEW_CASKS=""
  homebrew_managed "$(host_flake_ref)" || managed_rc=$?
  if [[ $managed_rc -eq 1 ]]; then
    info "homebrew.enable = false for this host — no casks replaced or removed"
    return 0
  elif [[ $managed_rc -ne 0 ]]; then
    homebrew_enable_failed "$(host_flake_ref)"
  fi
  if ! brew list --cask -1 >"$PLAN_TMP/installed_casks" 2>/dev/null; then
    warn "'brew list --cask' failed — install/replace/remove plan unavailable"
    return 0
  fi

  if retired_cask_names "$(host_flake_ref)" >"$PLAN_TMP/retired_casks"; then
    RETIRE_CASKS=$(intersect_lines "$PLAN_TMP/installed_casks" "$PLAN_TMP/retired_casks" | xargs)
  else
    warn "Could not evaluate dotfiles.homebrew.retiredCasks — nothing will be removed"
  fi

  if [[ "$declared_known" != true ]]; then
    warn "Declared casks unavailable — hand-installed copies not checked"
  else
    subtract_lines "$PLAN_TMP/declared_casks" "$PLAN_TMP/installed_casks" >"$PLAN_TMP/missing_casks"
  fi
  if [[ "$declared_known" == true && -s "$PLAN_TMP/missing_casks" ]]; then
    local cask app adopt=()
    if cask_app_targets <"$PLAN_TMP/missing_casks" >"$PLAN_TMP/missing_targets"; then
      while IFS=$'\t' read -r cask app; do
        [[ -n "$app" && -e "$app" ]] || continue
        adopt+=("$cask")
        ADOPT_APPS+="$app"$'\n'
        if ! app_bundle_modifiable "$app"; then ADOPT_BLOCKED+="$app"$'\n'; fi
      done <"$PLAN_TMP/missing_targets"
    else
      warn "Could not read cask metadata — hand-installed copies not checked"
    fi
    ADOPT_CASKS="${adopt[*]:-}"
    NEW_CASKS=$(subtract_lines "$PLAN_TMP/missing_casks" <(printf '%s\n' "${adopt[@]:-}") | xargs)
  fi

  if [[ -n "$NEW_CASKS" ]]; then
    info "Will INSTALL $(wc -w <<<"$NEW_CASKS" | tr -d ' ') newly declared cask(s): $NEW_CASKS"
  fi
  if [[ -n "$ADOPT_CASKS" ]]; then
    warn "Will REPLACE $(wc -w <<<"$ADOPT_CASKS" | tr -d ' ') hand-installed app(s) with the Homebrew copy:"
    local running=""
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      echo "    $app"
      if pgrep -qf "$app/Contents/MacOS/"; then running+=" $(basename "$app" .app)"; fi
    done <<<"$ADOPT_APPS"
    echo "    (settings and data live outside the app and are kept)"
    if [[ -n "$running" ]]; then
      echo "    Quit these first:$running"
    fi
  fi
  if [[ -n "$RETIRE_CASKS" ]]; then
    warn "Will UNINSTALL $(wc -w <<<"$RETIRE_CASKS" | tr -d ' ') retired cask(s) (dotfiles.homebrew.retiredCasks): $RETIRE_CASKS"
  fi
  if [[ -n "$ADOPT_BLOCKED" ]]; then
    warn "macOS App Management currently blocks replacing:"
    sed '/^$/d; s/^/    /' <<<"$ADOPT_BLOCKED"
  fi
}

# terminal_app_name — the app macOS holds responsible for this script, i.e.
# the one that needs App Management. Falls back to a generic phrase.
terminal_app_name() {
  local id="${__CFBundleIdentifier:-}" path
  if [[ -n "$id" ]]; then
    path=$(mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null | head -1)
    if [[ -n "$path" ]]; then basename "$path" .app; return; fi
  fi
  if [[ -n "${TERM_PROGRAM:-}" ]]; then echo "$TERM_PROGRAM"; return; fi
  echo "your terminal app"
}

# ensure_app_management — runs after the plan, BEFORE confirmation and
# authentication. If replacements are blocked, opens the exact Settings page,
# names the switch to flip, and continues on its own once the probe passes.
# Gives up before anything is applied, so a missing permission costs a re-run,
# never a half-switched system.
ensure_app_management() {
  [[ -n "$ADOPT_BLOCKED" ]] || return 0
  # A short wait, not a long one: macOS usually applies the switch only once
  # the terminal is relaunched, so this mainly catches an already-granted
  # permission or a terminal that applies it live. Seen on m5-air 2026-11-10:
  # a 5-minute wait in a terminal running since before the grant just timed out.
  local term waited=0 limit="${REBUILD_APP_MGMT_WAIT:-60}" app still
  term=$(terminal_app_name)
  echo ""
  warn "One-time step only you can do (Apple allows no script or sudo to):"
  echo "    1. System Settings → Privacy & Security → App Management → turn on '$term'"
  echo "       (not listed? add it with the + button)"
  echo "    2. QUIT '$term' completely with ⌘Q — closing its windows is not enough —"
  echo "       then reopen it and re-run this command. Nothing has been applied yet."
  open "$APP_MGMT_PANE" 2>/dev/null || true
  # A notification too: when this runs under another tool (e.g. an agent that
  # buffers output) the terminal text may not be visible while it waits.
  osascript -e "display notification \"Turn on '$term' under App Management, then quit and reopen it (⌘Q).\" with title \"Rebuild needs a one-time permission\"" >/dev/null 2>&1 || true
  info "Opened that page. Checking for ${limit}s in case it applies without a relaunch..."
  while :; do
    still=""
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      app_bundle_modifiable "$app" || still+="$app"$'\n'
    done <<<"$ADOPT_BLOCKED"
    if [[ -z "$still" ]]; then
      ADOPT_BLOCKED=""
      ok "App Management granted to '$term' — continuing"
      echo ""
      return 0
    fi
    if (( waited >= limit )); then break; fi
    sleep 3; waited=$((waited + 3))
  done
  err "Still blocked — nothing was applied. Turn on '$term' (step 1), quit it"
  err "with ⌘Q (step 2), reopen it, and re-run."
  exit 1
}

# ── Step 4b: Homebrew plan ──
# A function, not an inline block, so `--plan-only` can run it without building
# or activating — which also makes its failure paths testable. It needs no root
# and upgrades nothing, but it is NOT read-only: `brew update` below mutates
# Homebrew's local repo/metadata and hits the network.
#
# Upgrading outdated packages is the bulk of a long rebuild and the part that
# used to happen invisibly behind context-free Touch ID prompts, so surface it
# BEFORE asking for authentication. Activation no longer upgrades anything
# (homebrew.onActivation.upgrade = false); this plan SELECTS the upgrades, per
# --upgrade, and Step 6a performs exactly that selection after the switch.
#
# CRUCIALLY: `brew bundle` only touches what the Brewfile DECLARES, while
# `brew outdated` lists everything installed. Reporting raw `brew outdated`
# here promised upgrades that activation then did not perform (e.g. manually
# installed `bash`/`session` were listed, then left untouched). Intersect with
# the flake's declared set so this preview states what will actually happen,
# and report the undeclared remainder separately as drift.
#
# `brew update` refreshes metadata and needs no root. Activation would run it
# anyway (autoUpdate = true), so doing it here costs nothing and makes the
# preview accurate rather than stale.
# ── Upgrade selection (--upgrade=critical|all|none) ──
# The critical list is loaded once and kept in a global (not a subshell
# capture) so both the plan and the post-activation App Store step see the same
# answer. A failed evaluation is NOT an empty list: CRITICAL_KNOWN=false makes
# critical mode select nothing, and says so, rather than silently upgrading
# nothing while claiming the list was empty — or, worse, falling back to all.
CRITICAL_NAMES=""
CRITICAL_KNOWN=false
CRITICAL_LOADED=false
load_critical_names() {
  if $CRITICAL_LOADED; then
    if $CRITICAL_KNOWN; then return 0; fi
    return 1
  fi
  CRITICAL_LOADED=true
  ensure_declared_lib
  local names
  if names=$(critical_upgrade_names "$(host_flake_ref)"); then
    CRITICAL_NAMES="$names"
    CRITICAL_KNOWN=true
  else
    warn "Could not evaluate dotfiles.homebrew.criticalUpgrades for $FLAKE_REF"
    warn "  critical mode will upgrade NOTHING this run (pass --upgrade=all to override)"
  fi
  $CRITICAL_KNOWN
}

# select_by_mode — names on stdin (one per line), prints those this run's
# UPGRADE_MODE upgrades. awk rather than `grep -Fx || true`, which would mask a
# real grep error as "nothing matched".
select_by_mode() {
  case "$UPGRADE_MODE" in
    all)  awk 'NF' ;;
    none) cat >/dev/null ;;
    critical)
      if load_critical_names; then
        awk 'NR==FNR { if (NF) c[$0]=1; next } NF && ($0 in c)' \
          <(printf '%s\n' "$CRITICAL_NAMES") -
      else
        cat >/dev/null
      fi
      ;;
  esac
}

# What the plan promised and the post-activation step performs. Set ONLY by
# homebrew_plan, from a fully known plan; empty otherwise, so an unknown plan
# upgrades nothing rather than guessing.
BREW_UPGRADE_FORMULAE=""
BREW_UPGRADE_CASKS=""

homebrew_plan() {
  if [[ "$OS" != "Darwin" ]] || ! command -v brew &>/dev/null; then
    return 0
  fi
  echo -e "${BOLD}━━━ Homebrew ━━━${NC}"
  echo ""
  # Cross-user: the plan's brew commands already run as the primary user,
  # which needs root — so the run's one authentication happens here (unless
  # the drift audit already took it), in the parent shell (it starts the
  # keep-alive the EXIT trap must see).
  if $BREW_AS_PRIMARY && ! $SUDO_AUTHENTICATED; then
    info "Homebrew belongs to $PRIMARY_USER — authenticating now to run it as $PRIMARY_USER"
    info "  (this one authentication also covers the activation later)."
    authenticate_once ""
  fi
  info "Refreshing Homebrew metadata..."
  brew update --quiet &>/dev/null || warn "brew update failed (preview may be stale)"

  ensure_declared_lib

  # PLAN_TMP is cleaned by the shared EXIT trap, not an inline rm, so an
  # interrupt between here and the end of this block cannot leak it.
  PLAN_TMP=$(mktemp -d -t rebuild-plan.XXXXXX)

  # Inventory status is checked, never assumed. A failed `brew outdated` that
  # was treated as "nothing outdated" would silently print a clean plan.
  plan_known=true
  if ! brew outdated --formula --quiet >"$PLAN_TMP/outdated_formulae" 2>/dev/null; then
    warn "'brew outdated --formula' failed — formula plan unavailable"
    plan_known=false
  fi
  if ! brew outdated --cask --quiet >"$PLAN_TMP/outdated_casks" 2>/dev/null; then
    warn "'brew outdated --cask' failed — cask plan unavailable"
    plan_known=false
  fi

  # Formulae pulled in as DEPENDENCIES are not drift. `brew outdated` lists
  # them, but they are not yours to declare — Homebrew owns them on behalf of
  # the formula that requires them (e.g. `bash` exists only because the declared
  # `direnv` depends on it, and upgrades with it). Reporting them as undeclared
  # drift meant a permanent, unfixable warning: declaring a dependency is wrong,
  # so the message could never be acted on.
  #
  # `brew list --installed-on-request`, NOT `brew leaves`. Leaves means "nothing
  # else depends on it", which is a different question: a formula you explicitly
  # asked for that later became some other formula's dependency drops out of
  # `leaves` and would silently stop being reported. Installed-on-request is
  # exactly "you asked for this".
  requested_known=false
  if $plan_known; then
    if brew list --installed-on-request >"$PLAN_TMP/requested" 2>/dev/null; then
      requested_known=true
    else
      warn "'brew list --installed-on-request' failed — reporting drift unfiltered"
      warn "  (dependency formulae may appear below; they are not yours to declare)"
    fi
  fi

  # Per-category checks. A failure in ONE category must not read as "nothing
  # declared there" — that would relabel every package of that kind as drift.
  # Casks are evaluated even when the inventory failed: the cask lifecycle plan
  # below needs them and does not depend on `brew outdated`.
  declared_casks_known=false
  if declared_brew_names casks "$(host_flake_ref)" >"$PLAN_TMP/declared_casks"; then
    declared_casks_known=true
  fi
  if $plan_known; then
    if ! declared_brew_names brews "$(host_flake_ref)" >"$PLAN_TMP/declared_formulae"; then
      warn "Could not evaluate homebrew.brews for $FLAKE_REF"
      plan_known=false
    elif ! $declared_casks_known; then
      warn "Could not evaluate homebrew.casks for $FLAKE_REF"
      plan_known=false
    fi
  fi

  if ! $plan_known; then
    # Say nothing about what activation WILL do — at this point the script has
    # no evidence either way. Claiming the raw outdated list here is what the
    # original bug did, and doing it under a warning would not make it true.
    warn "Homebrew activation plan unavailable — showing raw outdated inventory:"
    if [[ -s "$PLAN_TMP/outdated_formulae" ]]; then
      echo "    outdated formulae: $(tr '\n' ' ' <"$PLAN_TMP/outdated_formulae")"
    fi
    if [[ -s "$PLAN_TMP/outdated_casks" ]]; then
      echo "    outdated casks:    $(tr '\n' ' ' <"$PLAN_TMP/outdated_casks")"
    fi
    echo "    (no Homebrew upgrades will run — the selection cannot be trusted)"
  else
    intersect_lines "$PLAN_TMP/outdated_formulae" "$PLAN_TMP/declared_formulae" >"$PLAN_TMP/will_formulae"
    intersect_lines "$PLAN_TMP/outdated_casks" "$PLAN_TMP/declared_casks" >"$PLAN_TMP/will_casks"
    # Declared + outdated, then narrowed by --upgrade. What is not selected is
    # DEFERRED and listed, so "why is X still old?" always has an answer.
    # Critical names are loaded up front, NOT lazily inside select_by_mode:
    # its stdout is redirected into the selection file, so a warning printed
    # from there would land in the file as a "package name".
    if [[ "$UPGRADE_MODE" == critical ]]; then load_critical_names || true; fi
    select_by_mode <"$PLAN_TMP/will_formulae" >"$PLAN_TMP/sel_formulae"
    select_by_mode <"$PLAN_TMP/will_casks" >"$PLAN_TMP/sel_casks"
    BREW_UPGRADE_FORMULAE=$(tr '\n' ' ' <"$PLAN_TMP/sel_formulae" | sed 's/ $//')
    BREW_UPGRADE_CASKS=$(tr '\n' ' ' <"$PLAN_TMP/sel_casks" | sed 's/ $//')
    defer_formulae=$(subtract_lines "$PLAN_TMP/will_formulae" "$PLAN_TMP/sel_formulae" | tr '\n' ' ' | sed 's/ $//')
    defer_casks=$(subtract_lines "$PLAN_TMP/will_casks" "$PLAN_TMP/sel_casks" | tr '\n' ' ' | sed 's/ $//')
    # Undeclared formulae are narrowed to the requested set — a dependency is
    # not drift. On failure to determine that set, report UNFILTERED rather than
    # intersecting against an empty file: intersecting would silently produce
    # zero drift, which is the encode-failure-as-emptiness bug this codebase
    # keeps having to unlearn. Over-reporting is the safe direction.
    subtract_lines "$PLAN_TMP/outdated_formulae" "$PLAN_TMP/declared_formulae" \
      >"$PLAN_TMP/undeclared_formulae"
    if $requested_known; then
      skip_formulae=$(intersect_lines "$PLAN_TMP/undeclared_formulae" "$PLAN_TMP/requested" | tr '\n' ' ' | sed 's/ $//')
    else
      skip_formulae=$(tr '\n' ' ' <"$PLAN_TMP/undeclared_formulae" | sed 's/ $//')
    fi
    skip_casks=$(subtract_lines "$PLAN_TMP/outdated_casks" "$PLAN_TMP/declared_casks" | tr '\n' ' ' | sed 's/ $//')

    n_sel=$(wc -w <<<"$BREW_UPGRADE_FORMULAE $BREW_UPGRADE_CASKS" | tr -d ' ')
    n_defer=$(wc -w <<<"$defer_formulae $defer_casks" | tr -d ' ')
    n_skip=$(wc -w <<<"$skip_formulae $skip_casks" | tr -d ' ')

    if [[ "$n_sel" -eq 0 && "$n_defer" -eq 0 ]]; then
      ok "No declared Homebrew packages need upgrading"
    fi
    if [[ "$n_sel" -gt 0 ]]; then
      warn "Will UPGRADE $n_sel declared package(s) after activation (--upgrade=$UPGRADE_MODE):"
      # if/fi, not `[[ ]] && echo` — under `set -e` a false test would abort here.
      if [[ -n "$BREW_UPGRADE_FORMULAE" ]]; then echo "    formulae: $BREW_UPGRADE_FORMULAE"; fi
      if [[ -n "$BREW_UPGRADE_CASKS" ]]; then echo "    casks:    $BREW_UPGRADE_CASKS"; fi
      echo "    (Homebrew may also upgrade undeclared dependencies of these.)"
    fi
    if [[ "$n_defer" -gt 0 ]]; then
      if [[ "$n_sel" -gt 0 ]]; then echo ""; fi
      info "$n_defer declared outdated package(s) DEFERRED by --upgrade=$UPGRADE_MODE:"
      if [[ -n "$defer_formulae" ]]; then echo "    formulae: $defer_formulae"; fi
      if [[ -n "$defer_casks" ]]; then echo "    casks:    $defer_casks"; fi
      echo "    (run 'rebuild.sh --upgrade=all' to include them)"
    fi

    # Not a warning: undeclared packages are yours to manage by hand, and
    # cleanup = "none" means activation preserves them. Surfaced so an outdated
    # package that never seems to update has a visible explanation.
    if [[ "$n_skip" -gt 0 ]]; then
      echo ""
      info "$n_skip outdated package(s) are NOT declared — not upgrade targets:"
      if [[ -n "$skip_formulae" ]]; then echo "    formulae: $skip_formulae"; fi
      if [[ -n "$skip_casks" ]]; then echo "    casks:    $skip_casks"; fi
      echo "    (upgrade by hand with 'brew upgrade <name>', or declare them in a profile)"
    fi
  fi

  echo ""
  cask_lifecycle_plan "$declared_casks_known"

  # Mac App Store, shown in the same breath as Homebrew so the plan covers
  # everything this run will change before you authenticate.
  # `if declared_outdated_mas; then` — NOT `x=$(...)`. Two reasons: under
  # `set -e` a failing command substitution in a bare assignment aborts the
  # script (a missing `mas` silently killed the whole run), and command
  # substitution would put the function in a subshell where its temp-dir
  # bookkeeping cannot reach the EXIT trap.
  local mas_ids mas_sel mas_defer rc
  if declared_outdated_mas; then rc=0; else rc=$?; fi
  mas_ids="$MAS_OUTDATED"
  case $rc in
    0)
      if [[ -n "$mas_ids" ]]; then
        if [[ "$UPGRADE_MODE" == critical ]]; then load_critical_names || true; fi
        mas_sel=$(select_by_mode <<<"$mas_ids")
        mas_defer=$(subtract_lines <(printf '%s\n' "$mas_ids") <(printf '%s\n' "$mas_sel") | awk 'NF')
        # Describe what will ACTUALLY happen. The gate below skips App Store
        # upgrades under --yes without --upgrade-mas, so promising an upgrade
        # here would be the same class of lie as the original Homebrew preview.
        if [[ -n "$mas_sel" ]]; then
          if $AUTO_CONFIRM && ! $FORCE_MAS; then
            info "$(wc -w <<<"$mas_sel" | tr -d ' ') declared App Store app(s) outdated — will be SKIPPED:"
            echo "    mas: $(tr '\n' ' ' <<<"$mas_sel" | sed 's/ $//')"
            echo "    (--yes without --upgrade-mas; run interactively to upgrade)"
          else
            warn "Will also UPGRADE $(wc -w <<<"$mas_sel" | tr -d ' ') declared App Store app(s):"
            echo "    mas: $(tr '\n' ' ' <<<"$mas_sel" | sed 's/ $//')"
          fi
        fi
        if [[ -n "$mas_defer" ]]; then
          info "$(wc -w <<<"$mas_defer" | tr -d ' ') declared App Store app(s) DEFERRED by --upgrade=$UPGRADE_MODE:"
          echo "    mas: $(tr '\n' ' ' <<<"$mas_defer" | sed 's/ $//')"
        fi
      else
        ok "No declared App Store apps need upgrading"
      fi
      ;;
    2) warn "mas not found — App Store apps not checked" ;;
    *) warn "Could not determine App Store state — apps not checked" ;;
  esac
  echo ""
}

echo ""
echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│       Safe Nix Rebuild                   │${NC}"
echo -e "${BOLD}${CYAN}│       $HOSTNAME ($OS)${NC}"
echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}"
echo ""

# ── Step 1: Sync the dotfiles checkout to origin/main ──
# Refuses to build/activate unless the checkout is clean `main` at origin/main
# (fast-forwarding it when that is safe), or --allow-unmerged is given. See
# scripts/lib/dotfiles-checkout.sh for why (rh7/rh-device-management#312).
# --plan-only builds and activates nothing, so for it a refusal is advisory.
CHECKOUT_LIB="$DOTFILES_DIR/scripts/lib/dotfiles-checkout.sh"
if [[ ! -r "$CHECKOUT_LIB" ]]; then
  err "Helper not found at $CHECKOUT_LIB"
  exit 1
fi
# shellcheck source=lib/dotfiles-checkout.sh
source "$CHECKOUT_LIB"
if ! sync_dotfiles_checkout "$ALLOW_UNMERGED" "rebuild.sh --allow-unmerged" "$FLAKE_REF"; then
  $PLAN_ONLY || exit 1
  warn "--plan-only builds and activates nothing, so continuing — but this plan"
  warn "is for the checkout above, NOT origin/main. A real rebuild would refuse."
  echo ""
fi

# ── Re-run the updated script ──
# The sync may have just fast-forwarded THIS file, but bash keeps executing
# the version it already parsed: kassie-mbp-m1 pulled the /etc preflight fix
# and then ran without it, failing exactly the way the fix prevents. So when
# the file changed, exec it — same interpreter, same arguments. Nothing has
# been authenticated, changed or created yet (no sudo, no temp dirs), so the
# exec loses nothing and the run still authenticates once. --allow-unmerged
# never touches the checkout, so it re-execs only if the file really changed.
# Once per run: a second change means origin moved mid-run — stop, not loop.
# A script the sync removed or made unreadable is not "unchanged": stop too.
if [[ -n "$SELF" ]] && ! new_sum=$(cksum 2>/dev/null <"$SELF"); then
  err "rebuild.sh ($SELF) is gone or unreadable after the checkout sync. Nothing was built or changed."
  exit 1
fi
if [[ -n "$SELF" && "$new_sum" != "$SELF_SUM" ]]; then
  if [[ -n "$REEXECED" ]]; then
    err "rebuild.sh changed again during this run's checkout sync. Nothing was built or changed — re-run it."
    exit 1
  fi
  info "rebuild.sh was updated by the sync — restarting the updated version."
  echo ""
  RH7_REBUILD_REEXECED=1 RH7_REBUILD_LOG_FILE="$LOG_FILE" \
    exec "$BASH" "$SELF" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi
cd "$DOTFILES_DIR"

# ── Step 2: Audit drift ──
# Ensure Nix is in PATH (audit needs `nix eval`, build needs it too).
if ! command -v nix &>/dev/null; then
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  else
    err "Nix not found. Install it first: curl -fsSL config.rh7labs.com/setup | bash"
    exit 1
  fi
fi

# ── First-adoption preflight ──
# Each check below either passes, fixes itself after one question (default
# No), or stops — all before the plan, the drift audit and the build, so a
# first adoption cannot fail halfway with some apps already replaced.
# --plan-only reports them as "will fix" and changes nothing; --build-only
# does the same for the Homebrew and /etc checks (it needs flakes to build).
require_nix_features

if [[ "$OS" == "Darwin" ]]; then
  ensure_jq || true
fi
# Who runs Homebrew — and, cross-user, whether the primary user owns it.
setup_brew_user
# /etc files nix-darwin's activation would reject (moved, if confirmed, only
# after the switch is confirmed — see etc_apply_renames).
etc_preflight

# ── --plan-only: preview the Homebrew plan and stop ──
# Placed after the nix-in-PATH setup (the plan evaluates the flake) but before
# the drift audit and build, so it stays fast. Nothing below this point runs:
# no build, no activation, no sudo — except that from another account than
# system.primaryUser the plan's brew commands run as that user, which takes
# the one authentication. (The plan itself does refresh Homebrew metadata —
# see homebrew_plan.)
if $PLAN_ONLY; then
  homebrew_plan
  ok "Plan complete (--plan-only). Nothing was built, upgraded, or activated."
  exit 0
fi

# Catch manual changes (dock pins, brew installs, MAS apps, defaults)
# that 'switch' would silently overwrite. Advisory — user decides.
#
# audit-config-drift.sh reads dock, casks, MAS and `defaults` — all macOS-only,
# and it bails with "macOS only." (exit 2) anywhere else. Skipping it up front
# keeps Linux rebuilds from printing an error and a warning they can do nothing
# about, on every single run.
# >>> BEGIN DRIFT AUDIT >>>
if [[ "$OS" == "Darwin" && -x "$DOTFILES_DIR/scripts/audit-config-drift.sh" ]]; then
  info "Auditing local state for manual drift..."
  echo ""
  AUDIT_HOST="${FLAKE_REF##*#}"
  audit_log=$(mktemp -t audit-log.XXXXXX)
  audit_rc=0
  # Cross-user, the audit's Homebrew calls must run as $PRIMARY_USER too: it
  # is a child process, so the brew() wrapper above does not reach it, and
  # `brew info` as the invoker failed — every declared app read as unmanaged.
  # Its sudo -n needs the run's one authentication, so that moves up to here
  # (the plan would take it next anyway). --build-only authenticates for
  # nothing: without a cached credential its audit runs Homebrew as you —
  # `brew list` still works from any account, and the casks whose apps
  # `brew info` cannot resolve are reported as such.
  audit_brew_cmd=""
  if ${BREW_AS_PRIMARY:-false}; then
    if ! ${BUILD_ONLY:-false}; then
      info "Homebrew belongs to $PRIMARY_USER — authenticating now so the drift audit can run it as $PRIMARY_USER"
      info "  (this one authentication also covers the plan and the activation later)."
      authenticate_once ""
    fi
    if ${SUDO_AUTHENTICATED:-false} || sudo -n true 2>/dev/null; then
      audit_brew_cmd="sudo -n -u $PRIMARY_USER -H $BREW_BIN"
    else
      info "--build-only takes no authentication: the drift audit runs Homebrew as you, not $PRIMARY_USER."
    fi
  fi
  BREW_CMD="$audit_brew_cmd" "$DOTFILES_DIR/scripts/audit-config-drift.sh" "$AUDIT_HOST" 2>&1 \
    | tee "$audit_log" || audit_rc=${PIPESTATUS[0]}

  # Parse risky/benign counts from audit's machine-readable summary line.
  #
  # The summary is ABSENT whenever the audit errors out (exit 2) rather than
  # completing — a bad flake ref, a nix eval failure, the macOS-only bail. The
  # `*)` case below exists precisely to keep going in that situation, but it
  # never got the chance: `var=$(grep ... | sed ...)` is FATAL under
  # `set -e` + `pipefail`, because a no-match grep exits 1 and errexit aborts
  # the script on a failed assignment. rebuild.sh died right here, exit 1, with
  # no message after the audit's own output — no build, no diff, no activation.
  # Read the line once and tolerate its absence, so a failed audit stays
  # advisory the way the case statement always intended.
  drift_summary=$(grep -E "^DRIFT_RESULT:" "$audit_log" || true)
  # A crash must never read as "no drift". Exit 0/1 is a RESULT only together
  # with the summary line: on kassie-mbp-m1 the audit died under macOS's bash
  # 3.2 ("tailscale: unbound variable", exit 1 — the drift code) and this
  # block reported "Drift is non-destructive (0 … pending)". Exit 0/1 without
  # the summary is a failure, shown with the audit's own error.
  if [[ ( "$audit_rc" == 0 || "$audit_rc" == 1 ) && -z "$drift_summary" ]]; then
    audit_rc="$audit_rc, no DRIFT_RESULT line"
  fi
  audit_error=$(sed $'s/\033\\[[0-9;]*m//g' "$audit_log" | grep -v '^DRIFT_RESULT:' \
    | grep -iE 'error|unbound|line [0-9]+:|aborted|not found|unable|fail' | tail -5 || true)
  if [[ -z "$audit_error" ]]; then
    audit_error=$(sed $'s/\033\\[[0-9;]*m//g' "$audit_log" | sed '/^[[:space:]]*$/d' | tail -3 || true)
  fi
  rm -f "$audit_log"
  risky=$(sed -nE 's/.*risky=([0-9]+).*/\1/p' <<<"$drift_summary")
  benign=$(sed -nE 's/.*benign=([0-9]+).*/\1/p' <<<"$drift_summary")
  informational=$(sed -nE 's/.*informational=([0-9]+).*/\1/p' <<<"$drift_summary")
  risky=${risky:-0}
  benign=${benign:-0}
  informational=${informational:-0}

  case "$audit_rc" in
    0) : ;;  # no drift
    1) # some drift exists; only prompt when it's risky
      if [[ "$risky" -gt 0 ]]; then
        echo ""
        warn "$risky manual change(s) above would be overwritten by 'switch'."
        warn "Fold them into the flake first if you want to keep them."
        if ! $AUTO_CONFIRM; then
          echo -en "${BOLD}  Continue with rebuild anyway? [y/N] ${NC}"
          read -r drift_confirm < /dev/tty
          if [[ "$drift_confirm" != "y" && "$drift_confirm" != "Y" ]]; then
            info "Cancelled. Edit the flake to capture the drift, then re-run."
            exit 0
          fi
        fi
      else
        info "Drift is non-destructive ($benign declared item(s) pending, $informational informational item(s) preserved) — proceeding."
      fi
      ;;
    *)
      warn "Audit failed (exit $audit_rc) — drift is UNKNOWN, not zero. Proceeding without a drift check."
      if [[ -n "$audit_error" ]]; then
        warn "Its error:"
        sed 's/^/          /' <<<"$audit_error"
      fi
      warn "Re-run it alone to see everything: $DOTFILES_DIR/scripts/audit-config-drift.sh $AUDIT_HOST"
      ;;
  esac
  echo ""
fi
# <<< END DRIFT AUDIT <<<

# ── Step 3: Build (no sudo needed) ──
# Where the built system lands. `darwin-rebuild build` / `nixos-rebuild build`
# write ./result in the cwd ($DOTFILES_DIR); the nix-build fallback below is
# pointed at the same path explicitly, so every later step (closure diff,
# activation, the "kept for inspection" messages, cleanup) refers to a link this
# run actually created.
RESULT_LINK="${DOTFILES_DIR}/result"

# Build the Darwin system and set DARWIN_REBUILD to the binary that activates it.
#
# darwin-rebuild is not on PATH on a freshly-Nix-installed Mac — exactly the
# first rebuild. The fallback used to build with `--no-link` and then point at
# ./result/sw/bin/darwin-rebuild, which `--no-link` had just suppressed: the
# closure diff was silently skipped and activation ran a path that did not exist
# (rh7/rh-device-management#311). Build to an explicit out-link instead and
# activate with the darwin-rebuild inside the closure we just built.
build_darwin_system() {
  if command -v darwin-rebuild &>/dev/null; then
    DARWIN_REBUILD="darwin-rebuild"
    darwin-rebuild build --flake "$FLAKE_REF" 2>&1 || return 1
  else
    info "darwin-rebuild not in PATH — using nix build..."
    # Honour --flake: build the same configuration activation will switch to.
    # A missing or empty fragment (`path` / `path#`) means "this host". Pin it
    # into FLAKE_REF itself so the later `darwin-rebuild switch` activates the
    # same host we build here, rather than applying its own LocalHostName
    # default (which can differ from `hostname -s`).
    local flake_path="${FLAKE_REF%%#*}" flake_host=""
    [[ "$FLAKE_REF" == *#* ]] && flake_host="${FLAKE_REF#*#}"
    flake_host="${flake_host:-$HOSTNAME}"
    FLAKE_REF="${flake_path}#${flake_host}"
    nix build "${flake_path}#darwinConfigurations.${flake_host}.system" \
      --out-link "$RESULT_LINK" 2>&1 || return 1
    DARWIN_REBUILD="${RESULT_LINK}/sw/bin/darwin-rebuild"
    if [[ ! -x "$DARWIN_REBUILD" ]]; then
      err "Built system has no darwin-rebuild at $DARWIN_REBUILD"
      return 1
    fi
  fi
}

info "Building configuration (no root required)..."
echo ""

cd "$DOTFILES_DIR"
case "$OS" in
  Darwin)
    if ! build_darwin_system; then
      err "Build failed. Fix the issue and try again."
      exit 1
    fi
    ;;
  Linux)
    if ! nixos-rebuild build --flake "$FLAKE_REF" 2>&1; then
      err "Build failed. Fix the issue and try again."
      exit 1
    fi
    ;;
esac

ok "Build succeeded"
echo ""

# ── Step 4: Show diff (no sudo needed) ──
CURRENT="/run/current-system"
NEW="$RESULT_LINK"

if [[ -e "$CURRENT" ]] && [[ -e "$NEW" ]]; then
  echo -e "${BOLD}━━━ Changes ━━━${NC}"
  echo ""

  if command -v nvd &>/dev/null; then
    nvd diff "$CURRENT" "$NEW"
  else
    # Fallback to built-in nix command
    nix store diff-closures "$CURRENT" "$NEW" 2>/dev/null || \
      warn "Could not diff closures (install nvd for better output)"
  fi

  echo ""
else
  if [[ ! -e "$CURRENT" ]]; then
    warn "No current system profile found (first install?)"
  fi
fi

if $BUILD_ONLY; then
  ok "Build complete (--build-only). Result in ./result"
  exit 0
fi


homebrew_plan
ensure_app_management

# ── Step 5: Confirm ──
if ! $AUTO_CONFIRM; then
  echo -e "${BOLD}━━━ Activation ━━━${NC}"
  echo ""
  echo "  The changes above will be applied to your system."
  echo "  This requires sudo for: system defaults, launchd services, /etc/ links."
  echo ""
  echo -en "${BOLD}  Apply these changes? [y/N] ${NC}"
  read -r confirm < /dev/tty
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    info "Cancelled. Build result is in ./result for inspection."
    exit 0
  fi
  echo ""
fi

# ── Step 5b: Authenticate ONCE for the whole run ──
# See authenticate_once. A cross-user run already authenticated before its
# plan (Homebrew runs as the primary user from the first `brew update`); the
# summary still lists what that one authentication covers.
#
# Say what the one prompt is for, so it can be attributed — and so a SECOND
# prompt during the run stands out as something to report, not to tap through.
info "One authentication covers this entire run:"
echo "    • activation: system settings, launchd services, /etc links"
if $BREW_AS_PRIMARY; then echo "    • every Homebrew command, run as $PRIMARY_USER"; fi
if [[ -n "$NEW_CASKS" ]]; then echo "    • install: $NEW_CASKS"; fi
if [[ -n "$ETC_RENAMES" ]]; then
  echo "    • move aside (→ *.before-nix-darwin): $(cut -f1 <<<"$ETC_RENAMES" | xargs)"
fi
if [[ -n "$ADOPT_CASKS" ]]; then echo "    • replace hand-installed: $ADOPT_CASKS"; fi
if [[ -n "$BREW_UPGRADE_FORMULAE$BREW_UPGRADE_CASKS" ]]; then
  echo "    • upgrade: $(xargs <<<"$BREW_UPGRADE_FORMULAE $BREW_UPGRADE_CASKS")"
fi
if [[ -n "$RETIRE_CASKS" ]]; then echo "    • uninstall retired: $RETIRE_CASKS"; fi
echo "    Any further prompt during this run is unexpected — the log will show what asked."

authenticate_once "Build result is in ./result for inspection."

# ── Before Step 5c: move recognised /etc files aside ──
# Confirmed in etc_preflight; done here — after the switch is confirmed,
# inside its one authentication, and BEFORE any app is replaced, so a failed
# move stops the run with nothing else changed.
if [[ "$OS" == "Darwin" ]]; then
  etc_apply_renames
fi

# ── Step 6: Activate (requires sudo) ──
# Classify darwin-rebuild exit into success / known-harmless / real failure.
# Captures the output so we can inspect it, then prints a truthful summary.
run_darwin_rebuild() {
  local cmd=("$@")
  local log rc
  log="$(mktemp -t rebuild-log.XXXXXX)"
  set +e
  "${cmd[@]}" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 0 ]]; then
    ok "System updated"
    # Household guard (configurations/macos/home-household.nix): the primary
    # user had no GUI session, so her LaunchAgents were installed, not loaded.
    if grep -q 'LaunchAgents installed; they load at the next login' "$log"; then
      info "The primary user is not logged in: her LaunchAgents (daily audit) load at her next login."
    fi
    rm -f "$log"
    return 0
  fi

  # Heuristics: real failures we don't want to hide.
  # Note: "Installing X has failed!" is a brew-bundle output line, NOT MAS —
  # it fires for cask install failures (e.g. version-mismatch on adopt).
  local has_brew_fail=false has_mas_fail=false has_nix_fail=false
  local has_xcode_fail=false has_secrets_fail=false
  grep -qiE 'brew bundle`? failed|brewfile dependenc(y|ies) failed|(installing|upgrading) .* has failed' "$log" && has_brew_fail=true
  grep -qiE 'failed to install .* from app store' "$log" && has_mas_fail=true
  grep -qiE 'error: builder for|error: build of' "$log" && has_nix_fail=true
  grep -qiE 'not agreed to the xcode license' "$log" && has_xcode_fail=true
  grep -qiE 'sops|age key|no key could decrypt' "$log" && has_secrets_fail=true

  warn "darwin-rebuild exited with code $rc"
  # Xcode first: it gates Homebrew entirely, so it explains a brew failure
  # rather than being a second, independent problem.
  if $has_xcode_fail; then
    err "Xcode's license has not been accepted, so Homebrew refused to run."
    err "NO cask was processed this run."
    # Activation accepts the license automatically before the Homebrew phase
    # (modules/darwin/xcode-license.nix). Reaching this branch means that
    # auto-accept did not take, so the manual command is a real escalation now
    # rather than the routine first-run step it used to be.
    err "Activation's auto-accept did not take. Run by hand, then re-run:"
    err "    sudo xcodebuild -license accept"
  fi
  if $has_mas_fail; then
    err "mas / App Store install failed — check output above for the app name"
    err "Workaround: install the app manually from the App Store, then re-run"
  fi
  if $has_brew_fail && ! $has_xcode_fail; then
    err "brew bundle had failures — not all Homebrew packages installed"
  fi
  if $has_nix_fail; then
    err "Nix build error — check output above"
  fi
  if $has_secrets_fail && ! $has_xcode_fail; then
    err "Possible sops/secrets failure on first build (see #27)"
  fi
  # Nothing matched. Do NOT guess a cause — the switch already printed one.
  # Quote it back instead, so the reader sees evidence rather than a hunch.
  if ! $has_brew_fail && ! $has_mas_fail && ! $has_nix_fail \
     && ! $has_xcode_fail && ! $has_secrets_fail; then
    err "Unrecognised failure. Error lines from the switch:"
    grep -iE 'error|fatal|failed' "$log" | tail -5 | sed 's/^/      /' || true
    err "Full output: $LOG_FILE"
  fi
  rm -f "$log"
  return "$rc"
}

# ── Step 5c: Replace hand-installed copies of newly declared casks ──
# Before activation, because `brew bundle` inside it fails on exactly these
# (see cask_lifecycle_plan). --force overwrites the existing bundle; the plan
# already confirmed App Management allows it. A failure here is left for
# activation to report rather than aborting the run.
#
# Cross-user: brew runs as the primary user, and a bundle she does not own
# (installed by hand from another account, or root's) makes Homebrew fall back
# to its OWN `sudo` to remove it — as her, i.e. a prompt for HER password,
# outside this run's authentication. The bundle is replaced by hers anyway, so
# it is handed to her first, as root, inside the authentication.
replace_hand_installed() {
  local cask app owner
  echo -e "${BOLD}━━━ Replacing hand-installed apps ━━━${NC}"
  echo ""
  if $BREW_AS_PRIMARY; then
    while IFS= read -r app; do
      [[ -n "$app" && -e "$app" ]] || continue
      owner=$(stat -f %Su "$app" 2>/dev/null) || owner=""
      if [[ "$owner" != "$PRIMARY_USER" ]]; then
        if sudo -n chown -R "$PRIMARY_USER" "$app"; then
          info "$app: owner ${owner:-unknown} → $PRIMARY_USER (it is being replaced by her Homebrew copy)"
        else
          warn "$app: could not hand it to $PRIMARY_USER — Homebrew may prompt for her password"
        fi
      fi
    done <<<"$ADOPT_APPS"
  fi
  for cask in $ADOPT_CASKS; do
    if HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask --force "$cask"; then
      ok "$cask now managed by Homebrew"
    else
      warn "$cask could not be replaced — activation will report it"
    fi
  done
  echo ""
}
if [[ "$OS" == "Darwin" && -n "$ADOPT_CASKS" ]]; then
  replace_hand_installed
fi

info "Activating configuration..."
# Activation failure must reach the exit status. Previously run_darwin_rebuild
# swallowed it (its last statement was `rm -f`, always 0), so a switch that died
# mid-activation still printed "Done." and exited 0 — the script reporting
# success for a system that was never fully switched.
ACTIVATION_RC=0
case "$OS" in
  Darwin)
    # DARWIN_REBUILD is the PATH binary, or the one inside the closure built in
    # step 3 on a fresh Mac — never a ./result this run did not create.
    run_darwin_rebuild sudo "$DARWIN_REBUILD" switch --flake "$FLAKE_REF" || ACTIVATION_RC=$?
    ;;
  Linux)
    sudo nixos-rebuild switch --flake "$FLAKE_REF" \
      && ok "System updated" \
      || { ACTIVATION_RC=$?; warn "nixos-rebuild exited non-zero — check output above"; }
    ;;
esac
echo ""

# Stop here on a failed activation: do not layer App Store upgrades on top of a
# half-switched system, and do not end with a success banner. ./result is kept
# deliberately for inspection, matching the authentication-failure path above.
if [[ $ACTIVATION_RC -ne 0 ]]; then
  err "Activation FAILED (exit $ACTIVATION_RC) — the system was NOT fully switched."
  err "Skipping App Store upgrades. Build result kept in ./result for inspection."
  # (moved /etc files still unlinked are reported by cleanup on exit)
  echo "Log: $LOG_FILE"
  echo ""
  exit "$ACTIVATION_RC"
fi

# ── Step 6r: Uninstall retired casks ──
# After a successful switch only, so a failed activation never leaves a machine
# with the old app removed and its replacement missing.
if [[ "$OS" == "Darwin" && -n "$RETIRE_CASKS" ]]; then
  echo -e "${BOLD}━━━ Removing retired casks ━━━${NC}"
  echo ""
  # shellcheck disable=SC2086
  if HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask $RETIRE_CASKS; then
    ok "Removed: $RETIRE_CASKS"
  else
    warn "Some retired casks were not removed — re-run to retry:"
    warn "  $(brew list --cask -1 2>/dev/null | grep -Fx -f <(tr ' ' '\n' <<<"$RETIRE_CASKS") | xargs || true)"
  fi
  echo ""
fi

# ── Step 6a: Upgrade the Homebrew packages the plan selected ──
# Activation only installs (homebrew.onActivation.upgrade = false — see
# modules/darwin/homebrew.nix for why it cannot select upgrades itself), so the
# upgrades --upgrade picked happen here, as the user, after a successful switch.
# Being outside activation also means a failed download — routine on a flaky
# network — costs that one package instead of failing the whole switch.
#
# Exactly the list the plan showed before you authenticated, not recomputed:
# the run does what it promised. Casks whose installer needs root reuse this
# run's sudo timestamp (timestamp_type=global, modules/darwin/sudo-rebuild.nix).
# HOMEBREW_NO_AUTO_UPDATE: the plan and activation both just ran `brew update`.
if [[ "$OS" == "Darwin" && -n "$BREW_UPGRADE_FORMULAE$BREW_UPGRADE_CASKS" ]]; then
  echo -e "${BOLD}━━━ Homebrew upgrades (--upgrade=$UPGRADE_MODE) ━━━${NC}"
  echo ""
  brew_upgrade_failed=false
  # Unquoted on purpose: space-separated package names.
  # shellcheck disable=SC2086
  if [[ -n "$BREW_UPGRADE_FORMULAE" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula $BREW_UPGRADE_FORMULAE || brew_upgrade_failed=true
  fi
  # shellcheck disable=SC2086
  if [[ -n "$BREW_UPGRADE_CASKS" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask $BREW_UPGRADE_CASKS || brew_upgrade_failed=true
  fi
  echo ""
  if $brew_upgrade_failed; then
    # Name what is STILL outdated rather than echoing brew's exit status, so
    # the summary is a re-runnable list instead of "something failed".
    still_outdated=""
    # shellcheck disable=SC2086
    if [[ -n "$BREW_UPGRADE_FORMULAE" ]]; then
      still_outdated+=" $(brew outdated --formula --quiet $BREW_UPGRADE_FORMULAE 2>/dev/null | tr '\n' ' ' || true)"
    fi
    # shellcheck disable=SC2086
    if [[ -n "$BREW_UPGRADE_CASKS" ]]; then
      still_outdated+=" $(brew outdated --cask --quiet $BREW_UPGRADE_CASKS 2>/dev/null | tr '\n' ' ' || true)"
    fi
    still_outdated=$(xargs <<<"$still_outdated")
    warn "Some Homebrew upgrades failed (the system switch itself succeeded)."
    if [[ -n "$still_outdated" ]]; then
      warn "  still outdated: $still_outdated"
    fi
    warn "  Re-run to retry; downloads already completed are cached."
  else
    ok "Homebrew upgrades complete"
  fi
  echo ""
fi

# ── Step 6b: Upgrade declared Mac App Store apps ──
# AFTER activation, deliberately: postActivation's `mas_install` installs any
# app that is MISSING, so running this second means a freshly-declared app is
# installed by activation and then, if the App Store already has a newer
# version, upgraded here in the same run.
#
# Recomputed rather than reusing the plan's list, because activation may have
# just installed apps that change the answer.
#
# See declared_outdated_mas() for why this is here and not in the weekly agent:
# mas invokes /usr/bin/sudo internally, which is acceptable with a human present
# who authenticated for this run, and not acceptable unattended.
# The whole justification for doing this here rather than in the weekly agent is
# that a human is present and authenticated deliberately. `--yes` breaks that
# premise — it exists to skip the prompt — so it must not silently authorise
# privileged App Store upgrades. Skipped by default there, with `--upgrade-mas`
# as an explicit "I am at the machine" override. Without this the safety
# argument would be a comment rather than a property of the script.
if [[ "$UPGRADE_MODE" == none ]]; then
  :  # --no-upgrade: the plan already listed outdated App Store apps as deferred
elif $AUTO_CONFIRM && ! $FORCE_MAS; then
  if [[ "$OS" == "Darwin" ]]; then
    info "Skipping App Store upgrades (--yes without --upgrade-mas)."
    info "  mas can invoke sudo; run interactively, or pass --upgrade-mas."
    echo ""
  fi
elif [[ "$OS" == "Darwin" ]]; then
  mas_rc=0
  declared_outdated_mas || mas_rc=$?
  # Same --upgrade selection the plan applied. Loaded here explicitly, not
  # lazily inside the $(...) below: the plan may never have loaded it (e.g. no
  # outdated apps then), and a load failure's warning would otherwise be
  # captured as an app id and handed to `mas upgrade`.
  if [[ "$UPGRADE_MODE" == critical ]]; then load_critical_names || true; fi
  mas_to_upgrade=$(select_by_mode <<<"$MAS_OUTDATED")
  case $mas_rc in
    0)
      if [[ -n "$mas_to_upgrade" ]]; then
        echo -e "${BOLD}━━━ App Store ━━━${NC}"
        echo ""
        mas_failed=()
        while IFS= read -r app_id; do
          [[ -z "$app_id" ]] && continue
          info "Upgrading App Store app $app_id..."
          if "${REBUILD_MAS_BIN:-mas}" upgrade "$app_id"; then
            ok "$app_id upgraded"
          else
            warn "$app_id failed — update it manually in the App Store"
            mas_failed+=("$app_id")
          fi
        done <<<"$mas_to_upgrade"
        if [[ ${#mas_failed[@]} -gt 0 ]]; then
          warn "App Store apps not upgraded: ${mas_failed[*]}"
        fi

        # An Xcode upgrade revokes the license agreement, and Homebrew refuses
        # to run at all while it is unaccepted. Activation already accepts it
        # up front (modules/darwin/xcode-license.nix, a preActivation hook),
        # but that ran BEFORE this step — so an Xcode upgraded here would
        # silently break the NEXT rebuild's entire Homebrew phase. Re-check and
        # re-accept now, while the run's sudo timestamp is still warm, so the
        # breakage never reaches the next run.
        #
        # Probe is Homebrew's own test, matched on OUTPUT and captured rather
        # than piped: `xcrun clang` exits 1 either way (no input files), and
        # under `set -o pipefail` a `| grep -q` would inherit that and never
        # fire. Same reasoning as modules/darwin/xcode-license.nix.
        xcode_probe=$(/usr/bin/xcrun clang 2>&1 || true)
        if [[ "$xcode_probe" == *license* ]]; then
          info "Xcode was upgraded — re-accepting its license for Homebrew..."
          # `sudo -n` and a kept stderr, both deliberately. This is the very
          # last thing rebuild.sh does, and the keep-alive subshell exits for
          # good the first time `sudo -n -v` fails — e.g. a cask postinstall
          # ran `sudo -k` earlier in the run. A plain `sudo … >/dev/null 2>&1`
          # would then block on a password prompt that has been redirected to
          # nowhere: a silent hang at the end of a long rebuild. Non-interactive
          # turns that into an immediate, visible failure, and keeping stderr
          # means the WARN below says what actually went wrong.
          # `</dev/null` guards the same way against xcodebuild itself asking.
          if xcode_err=$(sudo -n /usr/bin/xcodebuild -license accept </dev/null 2>&1); then
            ok "Xcode license accepted"
          else
            warn "Could not accept the Xcode license — the next rebuild will skip Homebrew."
            if [[ -n "$xcode_err" ]]; then
              warn "  ${xcode_err%%$'\n'*}"
            fi
            warn "Run once by hand: sudo xcodebuild -license accept"
          fi
        fi
        echo ""
      fi
      ;;
    2) warn "mas not found — declared App Store apps were not upgraded" ;;
    *) warn "Could not determine App Store state — apps were not upgraded" ;;
  esac
fi

# ── Step 7: Clean up ──
rm -f "$RESULT_LINK"

echo -e "${GREEN}${BOLD}Done.${NC} Run 'darwin-rebuild list' to see available generations."
echo "Log: $LOG_FILE"
echo ""
}

main "$@"; exit
