#!/usr/bin/env bash
# Pull-based collector runner — rh7/dotfiles (see rh-device-management#83, Phase 2).
#
# Fetches the CURRENT collector from the config service over Tailscale, verifies
# its checksum AND that the server's read-only scan is clean, then runs it
# (read-only, --run). Installed once per device; thereafter what we collect
# is changed centrally (merge to dotfiles) — no need to touch the device again.
#
# Safety:
#   - Tailscale-only origin (config service on the tailnet).
#   - Verifies sha256 against the manifest before executing — never runs
#     unverified bytes.
#   - Refuses to run if the server's read_only_scan is not clean.
#   - Falls back to the cached last-good collector if the service is
#     unreachable; skips entirely if neither is available.
#   - Touches only its own cache + logs — never mutates the device.
#
# Usage:
#   collector-runner.sh             # fetch -> verify -> run --run (default)
#   collector-runner.sh --check     # fetch + verify only (no execute)
#   collector-runner.sh --local     # run cached last-good without fetching
#   collector-runner.sh --install   # daily LaunchAgent (macOS) / cron (Linux)
#   collector-runner.sh --uninstall
set -euo pipefail

COLLECTOR="${COLLECTOR:-audit-device.sh}"
RUN_ARGS="${COLLECTOR_RUN_ARGS:---run}"
CACHE_DIR="${COLLECTOR_CACHE_DIR:-$HOME/.cache/fleet-collector}"
LABEL="${COLLECTOR_LABEL:-com.rh7.collector-runner}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
# Source(s) to self-install THIS runner from when invoked clone-free via
# `curl … | bash`, so a no-clone device gets the gated pull path instead of the
# un-gated audit fallback (rh-device-management#119). PRIMARY is the
# config.rh7labs.com short link (a Vercel rewrite -> raw dotfiles). The built-in
# raw-dotfiles fallback is auto-used ONLY when the primary is this default short
# link (so enrollment survives the short link being undeployed/lagging — the #39
# alias trap). A CUSTOM COLLECTOR_RUNNER_URL (staging/fork) fails closed unless
# the operator also sets COLLECTOR_RUNNER_URL_FALLBACK, so a custom primary's
# transient failure never silently installs main's runner. Both are TLS; the
# AUDIT the runner later pulls is still sha256 + scan + ref gated regardless.
RUNNER_URL_DEFAULT="https://config.rh7labs.com/collector-runner"
RUNNER_RAW_FALLBACK="https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/collector-runner.sh"
RUNNER_URL="${COLLECTOR_RUNNER_URL:-$RUNNER_URL_DEFAULT}"
OS="$(uname -s)"
CACHE="$CACHE_DIR/$COLLECTOR"
RUNNER_SELF="$CACHE_DIR/collector-runner.sh"
LOG="$CACHE_DIR/runner.log"
AGENT_PATH="/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$CACHE_DIR"
log() { echo "$(date -u +%FT%TZ) collector-runner: $*" | tee -a "$LOG" >&2; }

find_config_service() {
  if [ -n "${CONFIG_SERVICE_URL:-}" ]; then
    curl -sf "${CONFIG_SERVICE_URL}/api/health" --max-time 3 &>/dev/null && { echo "$CONFIG_SERVICE_URL"; return 0; }
    return 1
  fi
  local host
  for host in localhost rouvens-mac-studio-1 Rouvens-Mac-Studio.local rouvens-mac-studio 100.100.241.110; do
    if curl -sf "http://${host}:3456/api/health" --max-time 3 &>/dev/null; then
      echo "http://${host}:3456"; return 0
    fi
  done
  return 1
}

json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

fetch_and_verify() {  # writes $CACHE on success
  local base manifest want clean tmp got
  base="$(find_config_service)" || { log "config service not reachable"; return 1; }
  manifest="$(curl -fsS --max-time 15 "$base/api/collector/$COLLECTOR/manifest")" || { log "manifest fetch failed"; return 1; }
  want="$(printf '%s' "$manifest" | json_field 'd.get("sha256","")')"
  clean="$(printf '%s' "$manifest" | json_field 'str(d.get("read_only_scan",{}).get("clean",False)).lower()')"
  [ -n "$want" ] || { log "manifest missing sha256"; return 1; }
  if [ "$clean" != "true" ]; then log "REFUSING: $COLLECTOR failed the server read-only scan"; return 3; fi

  # Defense-in-depth (rh-device-management#99, follow-up to #96): consult the
  # manifest's serving-ref + host-checkout-state fields. Serving is already
  # pinned to origin/main SERVER-side, so these are belt-and-suspenders:
  #   - REFUSE if the server is serving from an unexpected ref (guards a
  #     misconfigured COLLECTOR_REF on the host). Configurable via
  #     COLLECTOR_EXPECTED_REF (default origin/main); set it empty to disable.
  #   - WARN (but proceed) if the host's dotfiles checkout is dirty or off-main
  #     — operator visibility only; the served bytes are still the pinned ref.
  #   - Tolerate older servers that omit ref/branch/dirty (warn-only, no fail).
  local ref branch dirty expected="${COLLECTOR_EXPECTED_REF-origin/main}"
  ref="$(printf '%s' "$manifest" | json_field 'd.get("ref","")')"
  branch="$(printf '%s' "$manifest" | json_field 'd.get("branch","")')"
  dirty="$(printf '%s' "$manifest" | json_field 'str(d.get("dirty","")).lower()')"
  if [ -n "$expected" ] && [ -n "$ref" ] && [ "$ref" != "$expected" ]; then
    log "REFUSING: server serves $COLLECTOR from ref '$ref', expected '$expected' (set COLLECTOR_EXPECTED_REF= to disable)"; return 4
  fi
  if [ -z "$ref" ] && [ -z "$branch" ] && [ -z "$dirty" ]; then
    log "note: server manifest omits ref/branch/dirty (older server) — gating on sha256 + scan only"
  else
    if [ "$dirty" = "true" ]; then
      log "WARNING: host dotfiles checkout is dirty — served bytes are still pinned ${ref:-origin/main}, proceeding"
    fi
    if [ -n "$branch" ] && [ "$branch" != "main" ]; then
      log "WARNING: host dotfiles checkout is on branch '$branch' (not main) — served bytes are still pinned ${ref:-origin/main}, proceeding"
    fi
  fi

  tmp="$(mktemp)"
  curl -fsS --max-time 30 "$base/api/collector/$COLLECTOR" -o "$tmp" || { rm -f "$tmp"; log "script fetch failed"; return 1; }
  got="$(sha_of "$tmp")"
  if [ "$want" != "$got" ]; then rm -f "$tmp"; log "checksum mismatch (want $want, got $got)"; return 2; fi
  mv "$tmp" "$CACHE"
  printf '%s\n' "$want" > "$CACHE.sha256"
  log "fetched $COLLECTOR ok ($want) from $base"
}

# Absolute path to a persistent copy of THIS runner for the scheduled job to
# exec daily. With a real on-disk clone, schedule it in place. When run clone-free
# via `curl … | bash` ($0 is "bash"/stdin, not a readable script), self-install a
# copy into the cache dir and schedule THAT — this is what lets a no-clone device
# get the sha256/scan-gated pull path instead of the un-gated audit fallback
# (rh-device-management#119). The runner script itself updates only on a re-install
# or clone pull; the AUDIT logic it pulls still changes centrally (#83).
resolve_self() {
  # Accept $0 only if it is actually an on-disk collector-runner.sh. A piped
  # invocation sets $0 to the shell — "bash", or "/bin/bash" which IS a readable
  # file — so a bare `[ -f "$0" ]` would hand back the shell binary and the
  # schedule would exec `bash /bin/bash` (collector never runs). Match the name.
  if [ -f "$0" ] && [ -r "$0" ] && [ "$(basename "$0")" = "collector-runner.sh" ]; then
    printf '%s\n' "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    return 0
  fi
  # Clone-free: self-install a persistent copy. Try the primary, then a fallback.
  # The built-in raw-dotfiles fallback is auto-used ONLY when the primary is the
  # default short link; a custom COLLECTOR_RUNNER_URL fails closed unless the
  # operator sets COLLECTOR_RUNNER_URL_FALLBACK explicitly.
  log "no on-disk runner (\$0='$0') — self-installing to $RUNNER_SELF"
  local fallback=""
  if [ -n "${COLLECTOR_RUNNER_URL_FALLBACK:-}" ]; then
    fallback="$COLLECTOR_RUNNER_URL_FALLBACK"
  elif [ "$RUNNER_URL" = "$RUNNER_URL_DEFAULT" ]; then
    fallback="$RUNNER_RAW_FALLBACK"
  fi
  local url
  for url in "$RUNNER_URL" ${fallback:+"$fallback"}; do
    if curl -fsSL --max-time 30 "$url" -o "$RUNNER_SELF" 2>/dev/null; then
      chmod +x "$RUNNER_SELF"
      log "self-installed runner from $url"
      printf '%s\n' "$RUNNER_SELF"
      return 0
    fi
    log "runner fetch failed from $url"
  done
  log "failed to fetch runner (primary $RUNNER_URL${fallback:+, fallback $fallback})"
  return 1
}

install_schedule() {
  local self; self="$(resolve_self)" || { log "cannot resolve runner path for schedule — aborting install"; return 1; }
  if [ "$OS" = "Darwin" ]; then
    local hour=8 minute=$(( RANDOM % 30 ))
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>-lc</string><string>bash "${self}"</string></array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>${AGENT_PATH}</string></dict>
    <key>StandardOutPath</key><string>/tmp/${LABEL}.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/${LABEL}.err.log</string>
    <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    log "installed LaunchAgent $LABEL (daily $(printf '%d:%02d' "$hour" "$minute"))"
    # Supersede the legacy direct-audit job (#38, #83): collector-runner replaces
    # it, so retire com.rh7.audit to avoid two daily audits firing.
    if [ -f "$HOME/Library/LaunchAgents/com.rh7.audit.plist" ]; then
      launchctl unload "$HOME/Library/LaunchAgents/com.rh7.audit.plist" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/com.rh7.audit.plist"
      log "retired legacy com.rh7.audit LaunchAgent (superseded by $LABEL)"
    fi
  else
    local min=$(( RANDOM % 30 ))
    # `|| true`: under `set -euo pipefail`, a fresh user with no crontab makes
    # `crontab -l | grep` exit non-zero and would abort before the echo, silently
    # installing no schedule. Keep the existing entries (if any) + append ours.
    (crontab -l 2>/dev/null | grep -v 'fleet-collector-runner' || true; echo "${min} 8 * * * bash ${self} # fleet-collector-runner") | crontab -
    log "installed cron (daily 8:$(printf '%02d' "$min"))"
  fi
}

uninstall_schedule() {
  if [ "$OS" = "Darwin" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; log "removed LaunchAgent $LABEL"
  else
    (crontab -l 2>/dev/null | grep -v 'fleet-collector-runner' | crontab -) || true; log "removed cron"
  fi
}

case "${1:-run}" in
  --install)   install_schedule; exit 0 ;;
  --uninstall) uninstall_schedule; exit 0 ;;
  --check)
    if fetch_and_verify; then log "check OK -> $CACHE"; exit 0; else log "check FAILED (rc=$?)"; exit 1; fi ;;
  --local)
    [ -f "$CACHE" ] || { log "no cached collector to run"; exit 1; } ;;
  run|"")
    if ! fetch_and_verify; then
      if [ -f "$CACHE" ]; then log "fetch failed — using cached last-good"; else log "no collector available — skipping"; exit 1; fi
    fi ;;
  *) log "unknown mode: $1"; exit 2 ;;
esac

log "running: bash $CACHE $RUN_ARGS"
exec bash "$CACHE" $RUN_ARGS
