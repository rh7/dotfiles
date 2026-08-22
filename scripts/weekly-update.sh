#!/usr/bin/env bash
# Weekly unattended software update — declared Homebrew FORMULAE only.
#
# Install: declared by modules/home/profiles/weekly-update.nix (launchd agent).
# Run once by hand: ./scripts/weekly-update.sh
# Preview without changing anything: ./scripts/weekly-update.sh --dry-run
#
# ── WHY FORMULAE ONLY ───────────────────────────────────────────────────────
# An earlier version also upgraded casks, skipping any that failed on the
# assumption they had needed root. That assumption was unsound in BOTH
# directions:
#
#   * It cannot deny root. Unsetting SUDO_ASKPASS stops a NEW authentication;
#     it does not stop sudo reusing an EXISTING credential. rebuild.sh holds a
#     user-global sudo timestamp open for the length of a rebuild (see
#     modules/darwin/sudo-rebuild.nix). If this job overlapped one, a cask
#     could have silently installed privileged payloads with no human present —
#     the exact outcome the "rootless" design was meant to rule out.
#   * A failed cask does not prove root was the reason. A running app, a
#     checksum mismatch or a network error look identical here.
#
# Formulae install under the Homebrew prefix, which this user owns, so by
# Homebrew's own convention a formula upgrade does not need root. That removes
# the expected privileged path — the cask installer — and is a large practical
# improvement.
#
# It is NOT a hard security boundary, and this file previously overclaimed that.
# `brew upgrade --formula` still runs formula/tap-authored install and
# post-install code as this user, and such code can invoke sudo and reuse a
# valid user-global timestamp exactly as a cask installer would. A real
# boundary would require the agent to be unable to use sudo at all — a separate
# non-admin identity — which this design does not implement. What is claimed
# here is narrower: this job does not itself run privileged installers.
#
# Outdated casks are REPORTED and PREFETCHED so an interactive rebuild.sh
# finishes them quickly, with one attributable authentication and a human
# watching.
#
# ── SCOPE: DECLARED PACKAGES ONLY (with one honest caveat) ──────────────────
# `brew outdated` lists everything installed; `brew bundle` only manages what
# the Brewfile declares. This job follows the flake: declared formulae are the
# upgrade TARGETS, undeclared ones are reported as drift.
#
# CAVEAT, stated because the previous wording was wrong: Homebrew resolves
# dependencies, so upgrading a declared formula MAY also upgrade an undeclared
# one it depends on. Only the selection of targets is restricted — this is not
# an absolute guarantee that undeclared packages never change.
#
# NOT covered by this job, stated so its scope is never mistaken for full
# coverage: macOS system updates, nix flake inputs (flake.lock), undeclared
# packages, declared casks, and Mac App Store apps.
#
# MAS is excluded on purpose, not by oversight. `mas_install` in postActivation
# only installs apps that are MISSING, so declared App Store apps otherwise
# never upgrade — a real gap. It is closed in scripts/rebuild.sh instead,
# because mas 7.0.0 spawns /usr/bin/sudo internally for update operations and
# must not run unattended while a rebuild holds a global sudo timestamp open.
#
# Nix/system config is intentionally NOT touched here — that stays rebuild.sh.

set -uo pipefail  # no -e: one failed formula must not abort the whole run

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
# Overridable so the "flake eval failed" path can actually be tested; normally
# resolves to this host's darwinConfiguration attribute name.
HOST="${WEEKLY_UPDATE_HOST:-$(hostname -s)}"
FLAKE_REF="${DOTFILES_DIR}#${HOST}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: weekly-update.sh [--dry-run]"
      echo ""
      echo "  --dry-run   Show what would be upgraded, change nothing"
      echo ""
      echo "Upgrades DECLARED Homebrew formulae only — never casks, which"
      echo "excludes the expected privileged path (the cask installer). Note"
      echo "this is a risk reduction, not a security boundary: formula"
      echo "post-install code still runs as you. Outdated casks and undeclared"
      echo "packages are reported; outdated casks are prefetched for a later"
      echo "rebuild.sh run."
      echo ""
      echo "Does NOT cover: macOS updates, flake.lock, undeclared packages,"
      echo "or App Store apps (those upgrade via rebuild.sh — see header)."
      echo "Logs to \$WEEKLY_UPDATE_LOG_DIR (default:"
      echo "  ~/.local/state/dotfiles/weekly-update/). Last 12 retained."
      echo ""
      echo "Exit: 0 all good · 1 could not determine state · 2 some upgrade failed"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Log file ──
LOG_DIR="${WEEKLY_UPDATE_LOG_DIR:-$HOME/.local/state/dotfiles/weekly-update}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${HOST}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
while IFS= read -r _old_log; do rm -f "$_old_log"; done < <(
  ls -1t "$LOG_DIR/${HOST}-"*.log 2>/dev/null | tail -n +13
)

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

log "=== weekly update start ($HOST) ==="

# ── Locate brew ──
# launchd agents get a minimal PATH; the nix module sets one, but don't rely on
# it when run by hand from a stripped environment.
if ! command -v brew &>/dev/null; then
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$candidate" ]] && { eval "$("$candidate" shellenv)"; break; }
  done
fi
if ! command -v brew &>/dev/null; then
  log "ERROR: brew not found — cannot determine state"
  exit 1
fi

# ── Locate nix ──
# Needed to evaluate which packages the flake declares.
if ! command -v nix &>/dev/null; then
  for candidate in /run/current-system/sw/bin /nix/var/nix/profiles/default/bin; do
    [[ -x "$candidate/nix" ]] && { PATH="$candidate:$PATH"; export PATH; break; }
  done
fi
if ! command -v nix &>/dev/null; then
  log "ERROR: nix not found — cannot determine which packages are declared"
  exit 1
fi

export HOMEBREW_NO_AUTO_UPDATE=1   # we update explicitly, once, below
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# Checked explicitly: this script runs without `set -e`, so a failed `source`
# would otherwise continue to "declared_brew_names: command not found" and a
# misleading "could not evaluate" error that blames nix for a missing file.
DECLARED_LIB="$DOTFILES_DIR/scripts/lib/declared-packages.sh"
if [[ ! -r "$DECLARED_LIB" ]]; then
  log "ERROR: helper not found at $DECLARED_LIB"
  log "       (is DOTFILES_DIR=$DOTFILES_DIR correct?)"
  exit 1
fi
# shellcheck source=lib/declared-packages.sh
source "$DECLARED_LIB"

tmp=$(mktemp -d -t weekly-update.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# ── Step 1: Refresh metadata ──
log "Refreshing Homebrew metadata..."
brew update --quiet || log "WARN: brew update failed — continuing with cached metadata"

# ── Step 2: Determine state ──
# Every inventory command's status is checked. Treating a failed `brew outdated`
# as "nothing is outdated" would report success while doing nothing, forever.
if ! brew outdated --formula --quiet >"$tmp/outdated_formulae" 2>/dev/null; then
  log "ERROR: 'brew outdated --formula' failed — refusing to guess at state"
  exit 1
fi
if ! brew outdated --cask --quiet >"$tmp/outdated_casks" 2>/dev/null; then
  log "ERROR: 'brew outdated --cask' failed — refusing to guess at state"
  exit 1
fi

# Per-category status checks. A failure in ONE category must not be mistaken
# for "that category declares nothing" — see the header of declared-packages.sh.
if ! declared_brew_names brews "$FLAKE_REF" >"$tmp/declared_formulae"; then
  log "ERROR: could not evaluate homebrew.brews for $FLAKE_REF"
  log "       refusing to guess — no upgrades performed"
  exit 1
fi
if ! declared_brew_names casks "$FLAKE_REF" >"$tmp/declared_casks"; then
  log "ERROR: could not evaluate homebrew.casks for $FLAKE_REF"
  log "       refusing to guess — no upgrades performed"
  exit 1
fi

mapfile -t targets < <(intersect_lines "$tmp/outdated_formulae" "$tmp/declared_formulae")
mapfile -t undeclared_formulae < <(subtract_lines "$tmp/outdated_formulae" "$tmp/declared_formulae")
mapfile -t declared_casks_outdated < <(intersect_lines "$tmp/outdated_casks" "$tmp/declared_casks")
mapfile -t undeclared_casks < <(subtract_lines "$tmp/outdated_casks" "$tmp/declared_casks")

log "Declared formulae to upgrade: ${#targets[@]}"
if [[ ${#targets[@]} -gt 0 ]]; then log "  ${targets[*]}"; fi

# Casks are never upgraded here — reported so they are visible, not silent.
if [[ ${#declared_casks_outdated[@]} -gt 0 ]]; then
  log "Declared casks outdated (NOT upgraded — needs interactive rebuild.sh): ${declared_casks_outdated[*]}"
fi
# Drift kept split by type: the same token can exist as both a formula and a
# cask, and merging them would double-count and log ambiguously.
if [[ ${#undeclared_formulae[@]} -gt 0 ]]; then
  log "Outdated but NOT declared — formulae (drift): ${undeclared_formulae[*]}"
fi
if [[ ${#undeclared_casks[@]} -gt 0 ]]; then
  log "Outdated but NOT declared — casks (drift): ${undeclared_casks[*]}"
fi
if [[ ${#undeclared_formulae[@]} -gt 0 || ${#undeclared_casks[@]} -gt 0 ]]; then
  log "  -> declare them in a profile, or upgrade by hand"
fi

if $DRY_RUN; then
  log "--dry-run: stopping before any changes"
  log "=== weekly update complete ==="
  exit 0
fi

# ── Step 3: Upgrade declared formulae ──
# One at a time so a single failure can't abort the rest and the summary can
# name exactly what was left behind.
failed_formulae=()
if [[ ${#targets[@]} -gt 0 ]]; then
  log "Upgrading formulae..."
  for f in "${targets[@]}"; do
    if brew upgrade --formula "$f"; then
      log "  ok: $f"
    else
      log "  FAILED: $f"
      failed_formulae+=("$f")
    fi
  done
fi

# ── Step 4: Prefetch outdated casks ──
# Downloading needs no root. Caching now means the interactive rebuild.sh run
# that installs them is fast instead of another multi-GB wait.
prefetch_failed=false
if [[ ${#declared_casks_outdated[@]} -gt 0 ]]; then
  log "Prefetching outdated declared casks for the next rebuild.sh..."
  if brew fetch --cask "${declared_casks_outdated[@]}" &>/dev/null; then
    log "  cached: ${declared_casks_outdated[*]}"
  else
    log "  WARN: prefetch failed (harmless — rebuild.sh will download then)"
    prefetch_failed=true
  fi
fi

# ── Summary ──
log "--- summary ---"
log "formulae upgraded: $(( ${#targets[@]} - ${#failed_formulae[@]} )) / ${#targets[@]}"
if [[ ${#failed_formulae[@]} -gt 0 ]]; then log "formulae failed: ${failed_formulae[*]}"; fi
if [[ ${#declared_casks_outdated[@]} -gt 0 ]]; then
  log "-> run ./scripts/rebuild.sh to install ${#declared_casks_outdated[@]} outdated cask(s)"
fi
log "log: $LOG_FILE"
log "=== weekly update complete ==="

# Exit non-zero on real upgrade failures so launchd and any monitoring see them.
# Continuing past a failure and reporting success are separate decisions; this
# job does the former, not the latter. A failed prefetch is not counted — it
# costs time on the next rebuild, nothing more.
if [[ ${#failed_formulae[@]} -gt 0 ]]; then
  exit 2
fi
$prefetch_failed && exit 0
exit 0
