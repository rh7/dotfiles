#!/usr/bin/env bash
# restic-backup.sh — targeted, encrypted, versioned backup of this device's
# important folders to the fleet's restic REST server (rh-device-management:
# rest-server on the Mac Studio, append-only, one private repo per host).
#
# Usage (on a host with services.rh7.resticBackup.enable the wrapper
# `rh7-restic-backup` bakes in restic, paths, excludes and the server):
#   rh7-restic-backup setup [--force]  # read the server token (stdin or prompt),
#                                      # create the local encryption key, init the repo
#   rh7-restic-backup run              # one backup (what the LaunchAgent runs)
#   rh7-restic-backup status [--json]  # last result from the status file
#   rh7-restic-backup snapshots [...]  # list this host's snapshots (read-only)
#   rh7-restic-backup restore-hint     # how to list / restore
#
# FILES
#   ~/.config/rh7-restic/server-user      REST user (= the canonical hostname from the token)
#   ~/.config/rh7-restic/server-password  REST password from the token
#   ~/.config/rh7-restic/repo-password    restic ENCRYPTION key, generated here; it
#                                         never leaves the device except via the
#                                         1Password escrow command `setup` prints.
#                                         Lose it and the snapshots are unreadable.
#   ~/.local/state/rh7-restic/status.json last run (contract below; read by
#                                         audit-device.sh and fleet-fix.sh backup)
#   ~/.local/state/rh7-restic/backup.log  run log (rotated at 1 MB)
#   ~/.local/state/rh7-restic/approved-paths.json
#                                         last good owner-approved list fetched
#                                         from the control plane (see APPROVED)
#
# STATUS CONTRACT (schema 1, atomic write, rh-device-management backup coverage):
#   {schema, enabled, configured, last_run_at, last_result, reason,
#    last_snapshot_time, snapshot_id, files_new, bytes_added, paths, repo_host,
#    exclude_larger_than, approved_paths, skipped_paths, approved_source}
#   last_result: ok | failed | skipped | not-configured
#   reason:      on-battery | offline | auth-failed | repo-locked |
#                permission-denied | unknown | null
#   paths:       what the snapshot named by last_snapshot_time contains: the
#                configured paths that existed and were readable when it was
#                taken, as "~/…" under $HOME (absolute otherwise). A run that
#                makes no snapshot carries the snapshot fields AND its paths
#                forward (before the first snapshot: the existing paths).
#   exclude_larger_than: the size cap the run used ("100M"): a file over it is
#                in no snapshot, so the audit does not call a folder holding one
#                restic-covered
#   approved_paths:  owner-approved paths (control plane) that passed device
#                    validation, "~/…" — given to restic, or already inside a
#                    module path / another approved path
#   skipped_paths:   [{path, reason}] approved paths refused here; reason:
#                    not-home-relative | control-character | home-root |
#                    dot-segment | excluded-location | not-found |
#                    outside-home | permission-denied
#   approved_source: control-plane | cache | none — where the list came from.
#                    The three approved fields are carried forward by a run
#                    that stops before fetching (not configured, battery,
#                    offline).
#
# APPROVED PATHS (rh-device-management data inventory): the owner marks
# folders "back up" on the dashboard; `run` fetches
#   GET <config service>/api/fleet/data/<host>/backup-paths  (10 s cap)
# found by the fleet's one config-service resolver (scripts/lib/config-service.sh),
# validates every entry HERE — the server is not trusted to keep this device's
# backup sane — and merges the survivors with the module's paths. A path must
# be "~/…", free of control characters and . / .. segments, not the home
# itself, not under ~/Library/Caches, ~/.Trash, ~/Library/CloudStorage,
# ~/Library/Mobile Documents or ~/Dropbox*, exist, resolve inside the home,
# and be readable by this job (macOS privacy). Refused entries are skipped and
# reported, never fatal. Fetch failure → the last good list
# (approved-paths.json); no list ever fetched → module paths only.
#
# POLICY
#   - Never forgets or prunes: the server is append-only, retention is a
#     server-side job. Nothing here deletes a snapshot.
#   - Skips (status written, exit 0) when on battery below
#     RH7_RESTIC_MIN_BATTERY % (default 30) or when the server is unreachable.
#   - Unconfigured (no setup yet) is a successful no-op that records
#     not-configured, so enabling the module fleet-wide is safe.
#   - macOS privacy (TCC): a launchd job cannot read ~/Desktop, ~/Documents,
#     ~/Downloads, iCloud Drive or external volumes without Full Disk Access.
#     restic reports that as "operation not permitted" (EPERM) — recorded as
#     permission-denied, and such a path is dropped from `paths`.
#
# ENVIRONMENT (the nix wrapper sets these; defaults in brackets)
#   RH7_RESTIC_BIN [restic]  RH7_RESTIC_REPO_HOST [rouvens-mac-studio]
#   RH7_RESTIC_PORT [8000]   RH7_RESTIC_PATHS, RH7_RESTIC_EXCLUDES (newline lists;
#   `run` needs PATHS)       RH7_RESTIC_EXCLUDE_LARGER_THAN [100M]
#   RH7_RESTIC_MIN_BATTERY [30]  RH7_RESTIC_CONFIG_DIR, RH7_RESTIC_STATE_DIR
#
# Exit: 0 ok / skipped / not-configured, 1 failed, 2 usage or setup error.
# Paths are stored and shown as "~/…" (status contract); those tildes are
# literal text, expanded explicitly by untilde().
# shellcheck disable=SC2088
set -uo pipefail

CONF_DIR="${RH7_RESTIC_CONFIG_DIR:-$HOME/.config/rh7-restic}"
STATE_DIR="${RH7_RESTIC_STATE_DIR:-$HOME/.local/state/rh7-restic}"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/backup.log"
LOCK_DIR="$STATE_DIR/run.lock"
RESTIC="${RH7_RESTIC_BIN:-restic}"
REPO_HOST="${RH7_RESTIC_REPO_HOST:-rouvens-mac-studio}"
PORT="${RH7_RESTIC_PORT:-8000}"
MIN_BATTERY="${RH7_RESTIC_MIN_BATTERY:-30}"
EXCLUDE_LARGER="${RH7_RESTIC_EXCLUDE_LARGER_THAN:-100M}"
PATHS_SPEC="${RH7_RESTIC_PATHS:-}"
EXCLUDES_SPEC="${RH7_RESTIC_EXCLUDES:-}"
APPROVED_CACHE="$STATE_DIR/approved-paths.json"
APPROVED_TIMEOUT="${RH7_RESTIC_APPROVED_TIMEOUT:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_TAG="rh7-restic"
ESCROW_CMD="~/rh-device-management/scripts/escrow-secrets-1password.sh --env ~/.config/rh7-restic/repo-password"

# ── helpers ──────────────────────────────────────────────────────────────────
die() { echo "rh7-restic: $*" >&2; exit 2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
canonical_host() { hostname | sed 's/\.local$//' | tr '[:upper:]' '[:lower:]'; }
tilde() { case "$1" in "$HOME") printf '~' ;; "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
untilde() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

log() {
  mkdir -p "$STATE_DIR" || return 0
  if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt 1048576 ]; then mv -f "$LOG_FILE" "$LOG_FILE.1"; fi
  printf '%s %s\n' "$(now_iso)" "$*" | tee -a "$LOG_FILE" >&2
}

need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

configured() { [ -s "$CONF_DIR/server-user" ] && [ -s "$CONF_DIR/server-password" ] && [ -s "$CONF_DIR/repo-password" ]; }
server_user() { cat "$CONF_DIR/server-user" 2>/dev/null; }
repo_url() { printf 'rest:http://%s:%s/%s/' "$REPO_HOST" "$PORT" "$1"; }

# The REST password goes through the environment, never argv (it would show in
# `ps`); the encryption key stays a file.
restic_env() { # restic_env <user> [rest-password; default: the stored one]
  export RESTIC_REPOSITORY RESTIC_REST_USERNAME RESTIC_REST_PASSWORD RESTIC_PASSWORD_FILE
  RESTIC_REPOSITORY="$(repo_url "$1")"
  RESTIC_REST_USERNAME="$1"
  if [ $# -ge 2 ]; then RESTIC_REST_PASSWORD="$2"; else RESTIC_REST_PASSWORD="$(cat "$CONF_DIR/server-password")"; fi
  RESTIC_PASSWORD_FILE="$CONF_DIR/repo-password"
}

# 0 = the server answers HTTP at all (any status; rest-server says 401 to an
# anonymous GET /). restic itself retries a dead server for many minutes, so
# reachability is decided here first.
server_reachable() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://$REPO_HOST:$PORT/" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# 0 = skip: on battery below MIN_BATTERY, or on battery with an unreadable
# charge. No pmset (Linux) or AC power = do not skip.
battery_low() {
  command -v pmset >/dev/null 2>&1 || return 1
  local out pct
  out="$(pmset -g batt 2>/dev/null)" || return 1
  case "$out" in *"'Battery Power'"*) ;; *) return 1 ;; esac
  pct="$(printf '%s\n' "$out" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"
  [ -z "$pct" ] && return 0
  [ "$pct" -lt "$MIN_BATTERY" ]
}

# write_status <result> <reason|""> <configured 0|1> <paths-json> [summary-json run_started]
# Snapshot fields: from the summary when this run made a snapshot, else carried
# forward from the previous status file. Approved fields: from this run when
# it fetched (APPROVED_SOURCE set), else carried forward.
write_status() {
  local result="$1" reason="$2" conf="$3" paths="$4" summary="${5:-}" started="${6:-}" prev='{}' tmp
  mkdir -p "$STATE_DIR" || return 1
  if [ -f "$STATUS_FILE" ] && jq -e 'type == "object"' "$STATUS_FILE" >/dev/null 2>&1; then prev="$(cat "$STATUS_FILE")"; fi
  tmp="$(mktemp "$STATE_DIR/.status.json.XXXXXX")" || return 1
  if jq -n --argjson prev "$prev" --arg now "$(now_iso)" --arg result "$result" --arg reason "$reason" \
      --argjson conf "$conf" --argjson paths "$paths" --arg summary "$summary" --arg started "$started" \
      --arg host "$REPO_HOST" --argjson approved "$APPROVED_JSON" --argjson skipped "$SKIPPED_JSON" \
      --arg asource "$APPROVED_SOURCE" --arg cap "$EXCLUDE_LARGER" '
    ($summary | if . == "" then null else fromjson end) as $s
    | (if $s != null and ($s.snapshot_id // "") != "" then
         { last_snapshot_time: $started, snapshot_id: ($s.snapshot_id[0:8]),
           files_new: $s.files_new, bytes_added: $s.data_added }
       else
         # No snapshot this run: the carried snapshot keeps the paths IT
         # contains, so a newly configured path is never credited to an older
         # snapshot that lacks it.
         { last_snapshot_time: ($prev.last_snapshot_time // null), snapshot_id: ($prev.snapshot_id // null),
           files_new: ($prev.files_new // null), bytes_added: ($prev.bytes_added // null),
           paths: (if ($prev.last_snapshot_time // null) != null and ($prev.paths | type) == "array"
                   then $prev.paths else $paths end) }
       end) as $snap
    | { schema: 1, enabled: true, configured: ($conf == 1), last_run_at: $now,
        last_result: $result, reason: (if $reason == "" then null else $reason end),
        last_snapshot_time: $snap.last_snapshot_time, snapshot_id: $snap.snapshot_id,
        files_new: $snap.files_new, bytes_added: $snap.bytes_added,
        paths: ($snap.paths // $paths), repo_host: $host, exclude_larger_than: $cap,
        approved_paths: (if $asource != "" then $approved else ($prev.approved_paths // []) end),
        skipped_paths: (if $asource != "" then $skipped else ($prev.skipped_paths // []) end),
        approved_source: (if $asource != "" then $asource else ($prev.approved_source // null) end) }' >"$tmp"; then
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATUS_FILE"
  else
    rm -f "$tmp"; return 1
  fi
}

# Configured paths -> RUN_PATHS (what restic is given: absolute, existing,
# symlinked roots resolved) + RUN_PATHS_TILDE (the configured name, same index,
# what `paths` reports). restic stores a symlink ROOT as just the link, so a
# symlinked ~/dotfiles would otherwise be "covered" with none of its content.
RUN_PATHS=(); RUN_PATHS_TILDE=(); LINK_FROM=(); LINK_TO=()
resolve_paths() {
  local p abs real
  RUN_PATHS=(); RUN_PATHS_TILDE=(); LINK_FROM=(); LINK_TO=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    abs="$(untilde "$p")"
    case "$abs" in /*) ;; *) log "ignoring non-absolute path '$p' (use ~/… or /…)"; continue ;; esac
    [ -e "$abs" ] || continue
    real="$abs"
    if [ -L "$abs" ]; then
      real="$(realpath "$abs" 2>/dev/null)" || { log "cannot resolve symlink $(tilde "$abs") — skipped"; continue; }
      log "$(tilde "$abs") is a symlink — backing up its target $real"
      LINK_FROM+=("$abs"); LINK_TO+=("$real")
    fi
    RUN_PATHS+=("$real"); RUN_PATHS_TILDE+=("$(tilde "$abs")")
  done <<<"$PATHS_SPEC"$'\n'"$APPROVED_SPEC"
}

paths_json() { # paths_json <tilde-path>... ; '[]' for none
  if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -cs .; fi
}

# ── approved paths (control plane, see APPROVED PATHS above) ─────────────────
APPROVED_SPEC=""; APPROVED_JSON='[]'; SKIPPED_JSON='[]'; APPROVED_SOURCE=""

# The fleet's ONE config-service resolver (pins, impostor check, fail-closed),
# loaded from the sibling lib — the nix wrapper ships this script together
# with scripts/collector-runner.sh and scripts/lib/.
load_resolver() {
  declare -F find_config_service >/dev/null && return 0
  [ -r "$SCRIPT_DIR/lib/config-service.sh" ] || return 1
  # shellcheck source=lib/config-service.sh
  . "$SCRIPT_DIR/lib/config-service.sh" && load_config_service_resolver "$SCRIPT_DIR/.."
}

# fetch_approved <host> → the response body; 1 on any failure (no service,
# non-2xx, timeout, not the documented shape, or a list for another host).
fetch_approved() {
  local host="$1" url body
  load_resolver || { log "approved paths: config-service resolver not found next to this script"; return 1; }
  url="$(find_config_service 2>/dev/null)"
  [ -n "$url" ] || return 1
  body="$(curl -fsS --connect-timeout 5 --max-time "$APPROVED_TIMEOUT" "${url%/}/api/fleet/data/$host/backup-paths" 2>/dev/null)" || return 1
  jq -e --arg h "$host" 'type == "object" and (.paths | type) == "array" and all(.paths[]; type == "string")
    and ((.hostname // $h) | ascii_downcase) == ($h | ascii_downcase)' <<<"$body" >/dev/null 2>&1 || return 1
  printf '%s\n' "$body"
}

# 0 = a home-relative path (no leading "~/", any case: APFS is
# case-insensitive) that must never be backed up from an approval.
excluded_rel() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    library/caches|library/caches/*|.trash|.trash/*|library/cloudstorage|library/cloudstorage/*) return 0 ;;
    "library/mobile documents"|"library/mobile documents/"*|dropbox*) return 0 ;;
  esac
  return 1
}

# "~/Pictures/" and "~/Pictures//" are "~/Pictures": strip trailing slashes
# before anything compares, dedupes or merges paths.
strip_slashes() { local p="$1"; while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done; printf '%s' "$p"; }

# approved_reason <path> → nothing when acceptable, else the skip reason.
# Control characters (NUL, newline, …) are refused before this, on the JSON.
approved_reason() {
  local p rest real home_real
  p="$(strip_slashes "$1")"
  case "$p" in "~") echo home-root; return ;; "~/"*) ;; *) echo not-home-relative; return ;; esac
  rest="${p#\~/}"
  [ -n "$rest" ] && [ "$rest" != . ] || { echo home-root; return; }
  case "/$rest/" in */../*|*/./*|*//*) echo dot-segment; return ;; esac
  excluded_rel "$rest" && { echo excluded-location; return; }
  [ -e "$HOME/$rest" ] || { echo not-found; return; }
  real="$(realpath "$HOME/$rest" 2>/dev/null)" || { echo not-found; return; }
  home_real="$(realpath "$HOME" 2>/dev/null)" || home_real="$HOME"
  case "$real" in "$home_real"/*) ;; *) echo outside-home; return ;; esac
  excluded_rel "${real#"$home_real"/}" && { echo excluded-location; return; }
  # macOS privacy: a folder this job may not list would fail the whole run
  # (EPERM = permission-denied); refuse it here and say so instead.
  if [ -d "$real" ]; then ls -A "$real" >/dev/null 2>&1 || { echo permission-denied; return; }
  elif [ ! -r "$real" ]; then echo permission-denied; return; fi
}

# apply_approved: fetch (or fall back to the cached list), validate, and set
# APPROVED_SPEC (what resolve_paths adds to the module paths) plus the three
# status fields. Never fails the run.
apply_approved() {
  local host body p q d reason kind abs covered tmp skipped=""
  local -a ok=()
  host="$(server_user)"; [ -n "$host" ] || host="$(canonical_host)"
  if body="$(fetch_approved "$host")"; then
    APPROVED_SOURCE=control-plane
    if mkdir -p "$STATE_DIR" && tmp="$(mktemp "$STATE_DIR/.approved.XXXXXX")"; then
      # Stamped with the identity it was fetched for: after a re-setup under
      # another name the old host's approvals must not be reused.
      jq --arg h "$host" '. + {hostname: $h}' <<<"$body" >"$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$APPROVED_CACHE" || rm -f "$tmp"
    fi
  elif jq -e --arg h "$host" 'type == "object" and (.paths | type) == "array"
      and ((.hostname // "") | ascii_downcase) == ($h | ascii_downcase)' "$APPROVED_CACHE" >/dev/null 2>&1; then
    APPROVED_SOURCE=cache; body="$(cat "$APPROVED_CACHE")"
    log "approved paths: control plane unavailable — using the last good list (updated $(jq -r '.updated_at // "?"' <<<"$body"))"
  else
    APPROVED_SOURCE=none; body='{"paths":[]}'
    log "approved paths: control plane unavailable and no list cached for $host — module paths only"
  fi
  while IFS=$'\t' read -r kind p; do
    [ -n "$kind" ] || continue
    if [ "$kind" = BAD ]; then reason=control-character; else p="$(strip_slashes "$p")"; reason="$(approved_reason "$p")"; fi
    if [ -n "$reason" ]; then
      log "approved path skipped: $p ($reason)"
      skipped+="$(jq -cn --arg p "$p" --arg r "$reason" '{path: $p, reason: $r}')"$'\n'
      continue
    fi
    for q in "${ok[@]+"${ok[@]}"}"; do [ "$q" = "$p" ] && continue 2; done
    ok+=("$p")
  done < <(jq -r '.paths[] | select(type == "string")
    | if (explode | any(. < 32 or . == 127)) then "BAD\t" + tojson else "OK\t" + . end' <<<"$body" 2>/dev/null)
  # Already inside a module path, or inside another approved path: covered
  # by that root — listed as approved, not given to restic twice.
  APPROVED_SPEC=""
  for p in "${ok[@]+"${ok[@]}"}"; do
    abs="$(untilde "$p")"; covered=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="$(untilde "$d")"
      case "$abs" in "$d"|"$d"/*) covered=1 ;; esac
    done <<<"$PATHS_SPEC"
    for q in "${ok[@]}"; do
      case "$abs" in "$(untilde "$q")"/*) covered=1 ;; esac
    done
    [ "$covered" = 1 ] || APPROVED_SPEC+="$p"$'\n'
  done
  APPROVED_JSON="$(paths_json "${ok[@]+"${ok[@]}"}")"
  SKIPPED_JSON="$(printf '%s' "$skipped" | jq -cs .)"
  [ "${#ok[@]}" -eq 0 ] || log "approved by the owner ($APPROVED_SOURCE): ${ok[*]}"
}

# restic matches excludes against the paths it archives, i.e. a symlinked
# root's TARGET: an absolute exclude under the configured name is emitted a
# second time rebased onto the target, so caches and the credentials dir stay
# out either way.
exclude_line() {
  local i
  printf '%s\n' "$1"
  for i in "${!LINK_FROM[@]}"; do
    case "$1" in
      "${LINK_FROM[$i]}"|"${LINK_FROM[$i]}"/*) printf '%s%s\n' "${LINK_TO[$i]}" "${1#"${LINK_FROM[$i]}"}" ;;
    esac
  done
}

write_exclude_file() { # write_exclude_file <file>
  local e
  {
    # The credentials of this very repo: pointless inside it.
    exclude_line "$CONF_DIR"
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      exclude_line "$(untilde "$e")"
    done <<<"$EXCLUDES_SPEC"
  } >"$1"
}

# classify_failure <stderr-file> <stdout-file> <rc> -> reason token
classify_failure() {
  local text
  text="$(cat "$1" "$2" 2>/dev/null)"
  if [ "$3" = 12 ] || grep -qiE 'HTTP response \(401\)|401 Unauthorized|wrong password|no key found' <<<"$text"; then echo auth-failed
  elif [ "$3" = 11 ] || grep -qiE 'already locked|unable to create lock|repository is locked' <<<"$text"; then echo repo-locked
  elif grep -qiE 'operation not permitted' <<<"$text"; then echo permission-denied
  elif grep -qiE 'connection refused|no such host|i/o timeout|network is unreachable|host is down|no route to host|context deadline exceeded' <<<"$text"; then echo offline
  else echo unknown; fi
}

# Which credential an auth-failed run tripped on — the status token is shared,
# the fix is not. Logged; fleet-fix.sh reads it back from the log.
auth_detail() { # auth_detail <stderr-file> <rc>
  if [ "$2" = 12 ] || grep -qiE 'wrong password|no key found' "$1" 2>/dev/null; then
    echo "encryption key: repo-password does not open the repository — restore it from the 1Password escrow (never re-init)"
  else
    echo "REST token: the server rejected it — re-issue on the Studio (restic-server-add-host.sh <host> --rotate), then setup"
  fi
}

acquire_lock() {
  mkdir -p "$STATE_DIR" || return 1
  if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ >"$LOCK_DIR/pid"; return 0; fi
  local pid; pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo $$ >"$LOCK_DIR/pid"
}
release_lock() { [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"; }

# ── run ──────────────────────────────────────────────────────────────────────
cmd_run() {
  need_jq
  [ -n "$PATHS_SPEC" ] || die "RH7_RESTIC_PATHS is empty — run through the rh7-restic-backup wrapper (services.rh7.resticBackup)"
  resolve_paths
  local pj; pj="$(paths_json "${RUN_PATHS_TILDE[@]+"${RUN_PATHS_TILDE[@]}"}")"

  if ! configured; then
    log "not configured (no credentials in $(tilde "$CONF_DIR")) — run: rh7-restic-backup setup"
    write_status not-configured "" 0 "$pj"; return 0
  fi
  if ! acquire_lock; then log "another run holds $LOCK_DIR — exiting"; return 0; fi
  trap release_lock EXIT

  if battery_low; then
    log "skipped: on battery below ${MIN_BATTERY}%"
    write_status skipped on-battery 1 "$pj"; return 0
  fi
  if ! server_reachable; then
    log "skipped: $REPO_HOST:$PORT unreachable"
    write_status skipped offline 1 "$pj"; return 0
  fi
  apply_approved
  resolve_paths
  pj="$(paths_json "${RUN_PATHS_TILDE[@]+"${RUN_PATHS_TILDE[@]}"}")"
  if [ ${#RUN_PATHS[@]} -eq 0 ]; then
    log "failed: none of the configured paths exists"
    write_status failed unknown 1 "$pj"; return 1
  fi

  local user tmp rc started summary reason p
  user="$(server_user)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rh7-restic.XXXXXX")" || { write_status failed unknown 1 "$pj"; return 1; }
  write_exclude_file "$tmp/excludes"
  restic_env "$user"
  started="$(now_iso)"
  log "backup to $(repo_url "$user") of: ${RUN_PATHS_TILDE[*]}"
  # A stop (logout, launchctl unload) signals the whole job group: restic
  # releases its repository lock and exits, and this trap — a CAUGHT signal,
  # so restic still gets its own handling — lets the shell record the run.
  trap 'log "terminated by signal"' TERM INT
  "$RESTIC" backup --json --host "$user" --tag "$SNAPSHOT_TAG" \
    --exclude-file "$tmp/excludes" --exclude-caches --exclude-larger-than "$EXCLUDE_LARGER" \
    -- "${RUN_PATHS[@]}" </dev/null >"$tmp/out" 2>"$tmp/err"
  rc=$?
  summary="$(jq -c 'select(.message_type? == "summary")' "$tmp/out" 2>/dev/null | tail -1)"

  # A top-level path restic could not read at all is not backed up: keep it out
  # of `paths`, so coverage never credits it.
  local unreadable kept=() i
  unreadable="$(jq -r 'select(.message_type? == "error") | .item // empty' "$tmp/err" 2>/dev/null | sort -u)"
  for i in "${!RUN_PATHS[@]}"; do
    if grep -qxF -- "${RUN_PATHS[$i]}" <<<"$unreadable"; then log "unreadable, not covered: ${RUN_PATHS_TILDE[$i]}"
    else kept+=("${RUN_PATHS_TILDE[$i]}"); fi
  done
  pj="$(paths_json "${kept[@]+"${kept[@]}"}")"

  if [ "$rc" = 3 ]; then
    log "warning: $(grep -c '"message_type":"error"' "$tmp/err") item(s) could not be read:"
    jq -r 'select(.message_type? == "error") | "  \(.item // "?"): \(.error.message // "?")"' "$tmp/err" 2>/dev/null \
      | head -20 | while IFS= read -r p; do log "$p"; done
  fi
  if { [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && [ -n "$summary" ]; then
    # Exit 3 = snapshot made, some items unreadable. EPERM ("operation not
    # permitted") is macOS privacy (TCC) refusing the job — a real gap, so the
    # run fails; other read errors (a file vanished mid-run, a root-owned file:
    # EACCES) are logged above and the snapshot counts.
    local snap; snap="$(jq -r '.snapshot_id[0:8]' <<<"$summary")"
    if grep -qi 'operation not permitted' "$tmp/err"; then
      log "failed: permission-denied — snapshot $snap is incomplete (grant Full Disk Access, see modules/darwin/restic-backup.nix)"
      write_status failed permission-denied 1 "$pj" "$summary" "$started"; rc=1
    else
      log "ok: snapshot $snap, $(jq -r '.files_new' <<<"$summary") new file(s), $(jq -r '.data_added' <<<"$summary") byte(s) added"
      write_status ok "" 1 "$pj" "$summary" "$started"; rc=0
    fi
  else
    reason="$(classify_failure "$tmp/err" "$tmp/out" "$rc")"
    if [ "$reason" = auth-failed ]; then log "failed: auth-failed — $(auth_detail "$tmp/err" "$rc") (restic exit $rc)"
    else log "failed: $reason (restic exit $rc)"; fi
    [ "$rc" = 10 ] && log "  the repository does not exist on the server — run: rh7-restic-backup setup"
    grep -v '^{' "$tmp/err" | tail -5 | while IFS= read -r p; do log "  $p"; done
    write_status failed "$reason" 1 "$pj"; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# ── setup ────────────────────────────────────────────────────────────────────
write_secret() { # write_secret <name> <value> — 0600, atomic
  local tmp
  tmp="$(mktemp "$CONF_DIR/.$1.XXXXXX")" || return 1
  printf '%s' "$2" >"$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$CONF_DIR/$1"
}

gen_key() { head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-48; }

cmd_setup() {
  local force=0 token="" host pw rest local_h rc out
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) die "setup: unknown argument $1" ;;
    esac; shift
  done
  if [ -t 0 ]; then
    printf 'Paste the token from the Studio (rh7-restic:<host>:<password>): ' >&2
    IFS= read -rs token || true; echo >&2
  else
    IFS= read -r token || true
  fi
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  case "$token" in rh7-restic:*:?*) ;; *) die "setup: not a token (expected rh7-restic:<host>:<password>)" ;; esac
  rest="${token#rh7-restic:}"; host="${rest%%:*}"; pw="${rest#*:}"
  printf '%s' "$host" | grep -qE '^[a-z0-9][a-z0-9.-]*$' || die "setup: bad hostname in token: '$host'"
  [ -n "$pw" ] || die "setup: empty password in token"
  local_h="$(canonical_host)"
  if [ "$host" != "$local_h" ] && [ "$force" -ne 1 ]; then
    die "setup: token is for '$host' but this device is '$local_h' — a wrong token writes into another host's repo. Re-issue it, or pass --force if the registry name really is '$host'."
  fi

  umask 077
  mkdir -p "$CONF_DIR" && chmod 0700 "$CONF_DIR" || die "setup: cannot create $CONF_DIR"
  # The encryption key must be a file for restic; it is only ever CREATED,
  # never replaced. The REST credentials are tried in memory and stored only
  # once the repository opens (or was initialised), so a mistyped or rejected
  # token never replaces working credentials.
  local new_key=0
  if [ ! -s "$CONF_DIR/repo-password" ]; then
    write_secret repo-password "$(gen_key)" || die "setup: cannot write repo-password"
    new_key=1
    echo "created encryption key $(tilde "$CONF_DIR")/repo-password" >&2
  else
    echo "keeping existing encryption key $(tilde "$CONF_DIR")/repo-password" >&2
  fi

  server_reachable || die "setup: $REPO_HOST:$PORT is unreachable (Tailscale up?) — nothing changed; re-run setup when it is reachable."
  restic_env "$host" "$pw"
  out="$("$RESTIC" cat config </dev/null 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "repository $(repo_url "$host") already exists and this key opens it" >&2
  elif [ "$rc" -eq 12 ] || grep -qiE 'wrong password|no key found' <<<"$out"; then
    die "setup: the repository exists but $(tilde "$CONF_DIR")/repo-password does not open it. Restore the escrowed key from 1Password into that file (0600) and re-run setup — never re-init."
  elif grep -qiE 'HTTP response \(40[13]\)|Unauthorized|Forbidden' <<<"$out"; then
    die "setup: the server rejected the token — nothing changed. Re-issue it on the Studio: scripts/restic-server-add-host.sh $host --rotate"
  elif [ "$rc" -eq 10 ] || grep -qiE 'does not exist|no such file|Is there a repository' <<<"$out"; then
    [ "$new_key" -eq 0 ] && echo "repository not found — initialising it with the existing key" >&2
    "$RESTIC" init </dev/null >/dev/null || die "setup: restic init failed — nothing changed"
    echo "initialised $(repo_url "$host")" >&2
  else
    die "setup: cannot open the repository (restic exit $rc) — nothing changed: $(tail -1 <<<"$out")"
  fi
  write_secret server-user "$host" && write_secret server-password "$pw" || die "setup: cannot write credentials"

  cat >&2 <<EOF

ESCROW THE ENCRYPTION KEY NOW — without it every snapshot is unreadable:
  $ESCROW_CMD          # dry-run
  $ESCROW_CMD --apply  # needs an interactive 'op signin'
(no clone? gh repo clone rh7/rh-device-management ~/rh-device-management)

First backup now (else daily via org.rh7.restic-backup):  rh7-restic-backup run
EOF
}

# ── status / snapshots / restore-hint ────────────────────────────────────────
cmd_status() {
  if [ "${1:-}" = "--json" ]; then
    [ -f "$STATUS_FILE" ] || { echo '{}'; return 1; }
    cat "$STATUS_FILE"; return 0
  fi
  echo "credentials: $(configured && echo "configured (repo $(repo_url "$(server_user)"))" || echo "NOT configured — run: rh7-restic-backup setup")"
  if [ ! -f "$STATUS_FILE" ]; then echo "status: no run recorded yet ($STATUS_FILE)"; return 0; fi
  need_jq
  jq -r '"last run:      \(.last_run_at // "never") — \(.last_result)\(if .reason then " (\(.reason))" else "" end)",
         "last snapshot: \(.last_snapshot_time // "none")\(if .snapshot_id then " [\(.snapshot_id)] +\(.files_new) files, +\(.bytes_added) bytes" else "" end)",
         "paths:         \((.paths // []) | join(" "))"' "$STATUS_FILE"
}

cmd_snapshots() {
  configured || die "not configured — run: rh7-restic-backup setup"
  restic_env "$(server_user)"
  exec "$RESTIC" snapshots --host "$(server_user)" "$@"
}

cmd_restore_hint() {
  local u; u="$(server_user)"; [ -n "$u" ] || u="$(canonical_host)"
  cat <<EOF
Repository: $(repo_url "$u")   (append-only: the server refuses deletes)

List and restore (credentials stay in files; nothing goes on argv):
  export RESTIC_REPOSITORY=$(repo_url "$u")
  export RESTIC_REST_USERNAME=$u
  export RESTIC_REST_PASSWORD="\$(cat ~/.config/rh7-restic/server-password)"
  export RESTIC_PASSWORD_FILE=~/.config/rh7-restic/repo-password
  restic snapshots --host $u
  restic ls latest --host $u ~/code
  restic -r "\$RESTIC_REPOSITORY" restore latest --host $u --target ~/restore-\$(date +%Y%m%d)
  #   one folder only: add  --include ~/code/<project>   (restored under the target, full path kept)

New or wiped device: restore repo-password from its 1Password escrow item into
~/.config/rh7-restic/repo-password (0600), get a fresh token on the Studio
(scripts/restic-server-add-host.sh $u --rotate), then: rh7-restic-backup setup.
Never 'restic forget/prune' from here — retention runs on the server.
EOF
}

usage() { sed -n '6,13p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    setup) cmd_setup "$@" ;;
    run) [ $# -eq 0 ] || die "run takes no arguments"; cmd_run ;;
    status) cmd_status "$@" ;;
    snapshots) cmd_snapshots "$@" ;;
    restore-hint) cmd_restore_hint ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
