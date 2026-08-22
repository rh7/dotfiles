#!/usr/bin/env bash
# Weekly unattended software update — Homebrew only, deliberately rootless, and
# scoped to packages the flake DECLARES.
#
# Install: declared by modules/home/profiles/weekly-update.nix (launchd agent).
# Run once by hand: ./scripts/weekly-update.sh
# Preview without changing anything: ./scripts/weekly-update.sh --dry-run
#
# ── SCOPE: DECLARED PACKAGES ONLY ───────────────────────────────────────────
# `brew outdated` lists everything installed; `brew bundle` only manages what
# the Brewfile declares. This job follows the flake, not the machine: declared
# packages are upgraded, undeclared ones are REPORTED as drift and left alone.
# Otherwise a hand-installed tool would start changing on a weekly schedule
# nobody asked for, and the flake would stop being the source of truth.
#
# ── WHY THIS DOES NOT USE ROOT ──────────────────────────────────────────────
# The obvious design — a launchd *daemon* running `darwin-rebuild switch` — is
# rejected on purpose:
#
#   1. A root daemon re-applying whatever is on `main` turns every merge into a
#      silent fleet-wide auto-deploy. Applying config is a decision; keep it in
#      rebuild.sh where a human sees the diff.
#   2. Homebrew refuses to run as root, so a root daemon would drop back to the
#      user for `brew` anyway — buying nothing.
#   3. Making brew's root-requiring casks work unattended would need a standing
#      NOPASSWD grant, open 24/7. That is a far larger concession than the
#      during-a-run window in modules/darwin/sudo-rebuild.nix, and it is not
#      worth it for convenience.
#
# So this runs as the user, and everything needing root is SKIPPED and REPORTED
# rather than forced. /Applications is group-writable by admin, so ordinary
# .app casks upgrade fine without root; only pkg-based casks (and anything
# installing daemons/kexts) need it. Those are left for an interactive
# rebuild.sh run, where you authenticate once and can see what you approved.
#
# Nix/system config is intentionally NOT touched here — that stays rebuild.sh.

set -uo pipefail  # no -e: one failed formula must not abort the whole run

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
# Overridable so the "flake eval failed" bail-out path can actually be tested;
# in normal use this resolves to the host's darwinConfiguration attribute name.
HOSTNAME="${WEEKLY_UPDATE_HOST:-$(hostname -s)}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: weekly-update.sh [--dry-run]"
      echo ""
      echo "  --dry-run   Show what would be upgraded, change nothing"
      echo ""
      echo "Upgrades DECLARED Homebrew packages that do not require root."
      echo "Undeclared packages are reported as drift, never upgraded."
      echo "Casks needing root are skipped and reported for a rebuild.sh run."
      echo "Logs to \$WEEKLY_UPDATE_LOG_DIR (default:"
      echo "  ~/.local/state/dotfiles/weekly-update/). Last 12 retained."
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Log file ──
LOG_DIR="${WEEKLY_UPDATE_LOG_DIR:-$HOME/.local/state/dotfiles/weekly-update}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${HOSTNAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
while IFS= read -r _old_log; do rm -f "$_old_log"; done < <(
  ls -1t "$LOG_DIR/${HOSTNAME}-"*.log 2>/dev/null | tail -n +13
)

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

log "=== weekly update start ($HOSTNAME) ==="

# ── Locate brew ──
# launchd agents get a minimal PATH; the nix module sets one, but don't rely on
# it when run by hand from a stripped environment.
if ! command -v brew &>/dev/null; then
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$candidate" ]] && { eval "$("$candidate" shellenv)"; break; }
  done
fi
if ! command -v brew &>/dev/null; then
  log "ERROR: brew not found — nothing to do"
  exit 1
fi

# ── Locate nix ──
# Needed to evaluate which packages the flake declares. Same reason as brew:
# a launchd agent's PATH is minimal, and the module sets one, but don't depend
# on it when run by hand.
if ! command -v nix &>/dev/null; then
  for candidate in /run/current-system/sw/bin /nix/var/nix/profiles/default/bin; do
    [[ -x "$candidate/nix" ]] && { PATH="$candidate:$PATH"; export PATH; break; }
  done
fi

# Never let brew try to escalate. With no tty and no askpass, a cask needing
# root fails fast and cleanly instead of hanging forever waiting on a prompt
# that no human will ever see.
unset SUDO_ASKPASS
export HOMEBREW_NO_AUTO_UPDATE=1   # we update explicitly, once, below
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# ── Step 1: Refresh metadata ──
log "Refreshing Homebrew metadata..."
brew update --quiet || log "WARN: brew update failed — continuing with cached metadata"

# ── Step 1b: Restrict to what the flake declares ──
# `brew outdated` lists everything installed, including packages installed by
# hand that the flake deliberately does not manage. Upgrading those here would
# make this job quietly broader than a rebuild — the flake would stop being the
# source of truth, and hand-installed software would change under you on a
# schedule you never asked for. So: upgrade DECLARED packages only, and report
# the rest as drift for you to either declare or remove.
# shellcheck source=lib/declared-brew.sh
source "$DOTFILES_DIR/scripts/lib/declared-brew.sh"

tmp=$(mktemp -d -t weekly-update.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

brew outdated --formula --quiet 2>/dev/null >"$tmp/outdated_formulae" || true
brew outdated --cask --quiet 2>/dev/null >"$tmp/outdated_casks" || true
declared_brew_names brews "$HOSTNAME" "$DOTFILES_DIR" >"$tmp/declared_formulae"
declared_brew_names casks "$HOSTNAME" "$DOTFILES_DIR" >"$tmp/declared_casks"

# Empty declared set means the nix eval failed, not that nothing is declared.
# Bail rather than guess: upgrading nothing is a silent no-op that would look
# like success week after week.
if [[ ! -s "$tmp/declared_formulae" && ! -s "$tmp/declared_casks" ]]; then
  log "ERROR: could not read declared packages from $DOTFILES_DIR (nix eval failed)"
  log "       refusing to guess — no upgrades performed"
  exit 1
fi

outdated_formulae=$(intersect_lines "$tmp/outdated_formulae" "$tmp/declared_formulae")
outdated_casks=$(intersect_lines "$tmp/outdated_casks" "$tmp/declared_casks")
undeclared=$(cat \
  <(subtract_lines "$tmp/outdated_formulae" "$tmp/declared_formulae") \
  <(subtract_lines "$tmp/outdated_casks" "$tmp/declared_casks"))

n_formulae=$(grep -c . <<<"$outdated_formulae" || true)
n_casks=$(grep -c . <<<"$outdated_casks" || true)
n_undeclared=$(grep -c . <<<"$undeclared" || true)
n_formulae=${n_formulae:-0}
n_casks=${n_casks:-0}
n_undeclared=${n_undeclared:-0}

log "Outdated + declared: $n_formulae formula(e), $n_casks cask(s)"
if [[ "$n_formulae" -gt 0 ]]; then log "  formulae: $(tr '\n' ' ' <<<"$outdated_formulae")"; fi
if [[ "$n_casks" -gt 0 ]]; then log "  casks:    $(tr '\n' ' ' <<<"$outdated_casks")"; fi
if [[ "$n_undeclared" -gt 0 ]]; then
  log "Outdated but NOT declared — left alone (drift): $(tr '\n' ' ' <<<"$undeclared")"
  log "  -> declare them in a profile, or 'brew upgrade <name>' by hand"
fi

if [[ "$n_formulae" -eq 0 && "$n_casks" -eq 0 ]]; then
  log "No declared package needs upgrading — nothing to do"
  log "=== weekly update complete ==="
  exit 0
fi

if $DRY_RUN; then
  log "--dry-run: stopping before any changes"
  exit 0
fi

# ── Step 2: Upgrade formulae ──
# CLI tools live under the Homebrew prefix, which the user owns. No root.
failed_formulae=""
if [[ "$n_formulae" -gt 0 ]]; then
  log "Upgrading formulae..."
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if brew upgrade --formula "$f"; then
      log "  ok: $f"
    else
      log "  FAILED: $f"
      failed_formulae+="$f "
    fi
  done <<<"$outdated_formulae"
fi

# ── Step 3: Upgrade casks that don't need root ──
# Upgraded one at a time so a single root-requiring cask can't abort the rest,
# and so the summary can name exactly which ones were left behind.
failed_casks=""
if [[ "$n_casks" -gt 0 ]]; then
  log "Upgrading casks (root-requiring ones will be skipped)..."
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if brew upgrade --cask "$c"; then
      log "  ok: $c"
    else
      log "  SKIPPED/FAILED: $c (likely needs root, or app was running)"
      failed_casks+="$c "
    fi
  done <<<"$outdated_casks"
fi

# ── Step 4: Pre-fetch what we couldn't install ──
# Downloading needs no root. Caching now means the interactive rebuild.sh run
# that finishes these is fast instead of another multi-GB wait.
if [[ -n "$failed_casks" ]]; then
  log "Pre-fetching skipped casks so the next rebuild.sh is quick..."
  # shellcheck disable=SC2086
  brew fetch --cask $failed_casks &>/dev/null \
    && log "  cached" || log "  WARN: prefetch failed (harmless)"
fi

# ── Summary ──
log "--- summary ---"
log "formulae upgraded: $((n_formulae - $(wc -w <<<"$failed_formulae"))) / $n_formulae"
log "casks upgraded:    $((n_casks - $(wc -w <<<"$failed_casks"))) / $n_casks"
if [[ -n "$failed_formulae" ]]; then log "formulae failed: $failed_formulae"; fi
if [[ -n "$failed_casks" ]]; then
  log "needs an interactive run: $failed_casks"
  log "-> run ./scripts/rebuild.sh to finish these (downloads already cached)"
fi
log "log: $LOG_FILE"
log "=== weekly update complete ==="
