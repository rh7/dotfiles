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
# Set by fetch_and_verify to the instance the collector was actually fetched and
# verified against; exported to the collector below so one run cannot straddle two.
RESOLVED_CONFIG_URL=""
RUNNER_SELF="$CACHE_DIR/collector-runner.sh"
LOG="$CACHE_DIR/runner.log"
AGENT_PATH="/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$CACHE_DIR"
log() { echo "$(date -u +%FT%TZ) collector-runner: $*" | tee -a "$LOG" >&2; }

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

json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

fetch_and_verify() {  # writes $CACHE on success
  local base manifest want clean tmp got
  # The shared resolver's contract is: echo a URL or nothing, and ALWAYS return 0
  # (it must, because audit-device.sh calls it under `set -e`). So test the VALUE,
  # never the exit status -- `|| { ... }` here would be dead code that reads like a
  # guard. An empty result means no pin answered and no fallback responded.
  base="$(find_config_service)"
  [ -n "$base" ] || { log "config service not reachable"; return 1; }
  # Hand the RESOLVED url to the collector so it does not re-resolve independently.
  # Without this the runner can fetch and sha256-verify the collector against one
  # instance while the collector POSTs its audit to another -- the integrity gate
  # evaluated against a server that never receives the data.
  RESOLVED_CONFIG_URL="$base"
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
    local hour=8 minute=$(( RANDOM % 30 )) tmp_plist domain bootstrap_output
    domain="gui/$(id -u)"
    mkdir -p "$HOME/Library/LaunchAgents"
    # Write beside the target and replace it atomically. Home Manager may leave
    # $PLIST as a symlink into the read-only Nix store; `cat > "$PLIST"` follows
    # that symlink and fails with EACCES. Replacing the directory entry works for
    # both a managed symlink and an ordinary stale/read-only plist.
    tmp_plist="$(mktemp "$HOME/Library/LaunchAgents/.${LABEL}.XXXXXX")"
    if ! cat > "$tmp_plist" <<PLIST
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
    then
      rm -f "$tmp_plist"
      log "failed to write temporary LaunchAgent plist"
      return 1
    fi
    # Remove an existing registration by label before replacing its plist.
    # `unload <path>` is deprecated and can return success without removing the
    # service on current macOS; bootout addresses the actual per-user domain.
    launchctl bootout "$domain/$LABEL" 2>/dev/null \
      || launchctl unload "$PLIST" 2>/dev/null \
      || true
    chmod 0644 "$tmp_plist"
    if ! mv -f "$tmp_plist" "$PLIST"; then
      rm -f "$tmp_plist"
      log "failed to replace LaunchAgent plist at $PLIST"
      return 1
    fi
    if ! bootstrap_output="$(launchctl bootstrap "$domain" "$PLIST" 2>&1)"; then
      log "launchctl bootstrap failed for $PLIST: $bootstrap_output"
      return 1
    fi
    launchctl enable "$domain/$LABEL" 2>/dev/null || true
    if ! launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
      log "LaunchAgent bootstrap returned success but $domain/$LABEL is not registered"
      return 1
    fi
    log "installed LaunchAgent $LABEL (daily $(printf '%d:%02d' "$hour" "$minute"))"
    # Supersede the legacy direct-audit job (#38, #83): collector-runner replaces
    # it, so retire com.rh7.audit to avoid two daily audits firing.
    if [ -f "$HOME/Library/LaunchAgents/com.rh7.audit.plist" ]; then
      launchctl bootout "$domain/com.rh7.audit" 2>/dev/null \
        || launchctl unload "$HOME/Library/LaunchAgents/com.rh7.audit.plist" 2>/dev/null \
        || true
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
# Pin the collector to the same instance this run verified against. In --local mode
# nothing was fetched, so there is nothing to pin and the collector resolves on its
# own -- which is correct, not a gap.
if [ -n "$RESOLVED_CONFIG_URL" ]; then
  export CONFIG_SERVICE_URL="$RESOLVED_CONFIG_URL"
  log "pinning collector to $RESOLVED_CONFIG_URL for this run"
fi
exec bash "$CACHE" $RUN_ARGS
