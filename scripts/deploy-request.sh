#!/usr/bin/env bash
# scripts/deploy-request.sh — "deploy now" poller for a nix-darwin Mac.
#
# Runs as ROOT every 15 minutes from the org.rh7.deploy-request LaunchDaemon
# declared by modules/darwin/fleet-update.nix (read its DEPLOY NOW section).
# Like the update itself it is never run from ~/dotfiles: the module wraps
# this file as /run/current-system/sw/bin/rh7-deploy-request and bakes in this
# host's flake attribute (--hostname) and the store path of the SAME
# generation's rh7-fleet-update (--fleet-update).
#
# Per run:
#   1. read the config-service pin (/etc/rh7/config-service, first
#      non-comment line, the same rule as the collector's resolver). No pin ->
#      one log line, exit 0. Never probes for another instance.
#   2. GET /api/fleet/deploy-request/<host>. Unreachable, non-200 or not the
#      contract -> one log line, exit 0 (fail-soft: the next poll retries).
#      `requested: false` -> exit 0 without a word.
#   3. requested: if the update's request-result.json (the last requested
#      run's state; state.json itself is overwritten by the next nightly run)
#      already holds the FINAL result of this request_id (an earlier poll ran
#      it but its ack was lost, or this poller was unloaded mid-run by the
#      activation it started), only that result is acked — the update is not
#      run twice. Otherwise ack `started` (once per
#      request; rejected with a 4xx = cancelled or replaced since the GET ->
#      not run) and run `rh7-fleet-update --requested <id> [--fast-lane]`.
#   4. ack the final result read back from request-result.json — only if it
#      carries THIS request_id and a final result:
#        applied | no-op | refused | failed  -> the same status
#        skipped / channel-behind            -> no-op (nothing newer to apply)
#        skipped / dock-protect              -> failed (a human must decide)
#        skipped / on-battery, rebuild-in-progress, or no state from this run
#        (lock-held: the nightly run holds the lock)
#                                            -> no final ack; the request
#                                               stays pending and the next
#                                               poll runs it again
#      commit = applied_commit for applied / no-op, else target_commit;
#      lane = state lane; reason = state reason plus "fast-lane:<token>" when
#      a fast lane the owner allowed was not taken.
#   A rejected ack (4xx: the request was cancelled or replaced meanwhile) is
#   logged and dropped; a transport error or 5xx is retried by the next poll
#   (step 3), because the GET keeps returning the request until it is acked.
#
# Exit status: always 0 except 64 usage, 77 not root — launchd must not
# throttle a poller over a config-service outage.
#
# DEPLOY_REQUEST_ROOT (tests only) prefixes every absolute path this script
# owns, like FLEET_UPDATE_ROOT for the update; scripts/tests/
# deploy-request.test.sh runs it unprivileged.
set -uo pipefail

ROOT="${DEPLOY_REQUEST_ROOT:-}"
PIN_FILE="$ROOT/etc/rh7/config-service"
STATE_DIR="$ROOT/var/lib/rh7-fleet-update"
RESULT_FILE="$STATE_DIR/request-result.json"
STARTED_FILE="$STATE_DIR/deploy-request.started"
LOG_FILE="$ROOT/var/log/rh7-deploy-request.log"
LOG_MAX_BYTES=$((256 * 1024))

HOST=""
FLEET_UPDATE=""
BASE=""
HTTP_CODE=""
HTTP_BODY=""

usage() {
  cat <<'EOF'
Usage: rh7-deploy-request
  (the module wrapper supplies --hostname <flake attr> --fleet-update <path>)
Polls the config service once for an owner-requested deploy of this host and,
if there is one, runs rh7-fleet-update --requested and acknowledges the result.
EOF
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s [deploy-request] %s\n' "$(now_iso)" "$*" >>"$LOG_FILE"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)     HOST="${2:-}"; shift 2 ;;
      --fleet-update) FLEET_UPDATE="${2:-}"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
  done
  [[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || { echo "--hostname must be a flake attribute / host name" >&2; exit 64; }
  # The registry's key is the canonical, lower-case host name (the service
  # canonicalizes every write path the same way); Kassie-M5-Air13 polls as
  # kassie-m5-air13.
  HOST=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
  [[ -x "$FLEET_UPDATE" ]] || { echo "--fleet-update must be the rh7-fleet-update executable" >&2; exit 64; }
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  if [[ -f "$LOG_FILE" ]] && [[ $(wc -c <"$LOG_FILE") -gt $LOG_MAX_BYTES ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

# read_pin — the config-service base URL from the pin file, or 1.
read_pin() {
  local value
  [[ -r "$PIN_FILE" ]] || return 1
  value=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PIN_FILE" 2>/dev/null | grep -m1 . || true)
  [[ "$value" =~ ^https?://[^[:space:]/#]+(:[0-9]+)?/?$ ]] || return 1
  printf '%s' "${value%/}"
}

# http <GET|POST> <path> [json-body] — sets HTTP_CODE and HTTP_BODY; 1 on a
# transport error. Short timeouts: this runs every 15 minutes, and a hung
# poll would only delay the next one.
http() {
  local method="$1" url="$BASE$2" tmp rc=0
  local -a args=(-sS --connect-timeout 5 --max-time 15 -X "$method" -H 'Accept: application/json')
  tmp=$(mktemp "${TMPDIR:-/tmp}/rh7dr.XXXXXX") || return 1
  if [[ $# -ge 3 ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$3")
  fi
  HTTP_CODE=$(curl "${args[@]}" -o "$tmp" -w '%{http_code}' "$url" </dev/null 2>/dev/null) || rc=$?
  HTTP_BODY=$(cat "$tmp" 2>/dev/null || true)
  rm -f "$tmp"
  [[ $rc -eq 0 && "$HTTP_CODE" =~ ^[0-9]{3}$ ]]
}

# final_ack <request_id> — the final ack body for this request from
# RESULT_FILE, on stdout; 1 when it holds no final result for it.
final_ack() {
  [[ -r "$RESULT_FILE" ]] || return 1
  jq -ce --arg rid "$1" '
    select(type == "object" and .request_id == $rid)
    | (if .last_result == "skipped" then
         (if .reason == "channel-behind" then "no-op" elif .reason == "dock-protect" then "failed" else null end)
       else .last_result end) as $status
    | select($status != null and ($status | IN("applied", "no-op", "refused", "failed")))
    | { request_id: $rid, status: $status,
        commit: (if $status == "applied" or $status == "no-op" then .applied_commit else .target_commit end),
        lane: (if .lane == "fast" or .lane == "channel" then .lane else null end),
        reason: ([ .reason,
                   (if .fast_lane_reason != null and .fast_lane_reason != "not-requested"
                    then "fast-lane:" + .fast_lane_reason else null end) ]
                 | map(select(type == "string")) | if length == 0 then null else join("; ") end) }' \
    "$RESULT_FILE" 2>/dev/null
}

# state_has_request <request_id> — RESULT_FILE was written by a run of it.
state_has_request() {
  [[ -r "$RESULT_FILE" ]] && jq -e --arg rid "$1" '.request_id == $rid' "$RESULT_FILE" >/dev/null 2>&1
}

# ack <json> — POST it; logs the outcome. 0 accepted, 1 not delivered
# (transport error or 5xx: the next poll retries), 2 rejected (4xx: the
# request was cancelled or replaced, or the body refused — dropped).
ack() {
  local body="$1" status
  status=$(jq -r '.status' <<<"$body")
  if ! http POST "/api/fleet/deploy-request/$HOST/ack" "$body"; then
    log "ack $status: config service unreachable — retried on the next poll"
    return 1
  fi
  case "$HTTP_CODE" in
    2??) log "ack $status accepted: $body"; return 0 ;;
    4??) log "ack $status rejected (HTTP $HTTP_CODE) — the request was cancelled or replaced; dropped"; return 2 ;;
    *)   log "ack $status: HTTP $HTTP_CODE — retried on the next poll"; return 1 ;;
  esac
}

main() {
  parse_args "$@"
  if [[ -z "$ROOT" && $(id -u) -ne 0 ]]; then
    echo "rh7-deploy-request must run as root (it is the org.rh7.deploy-request LaunchDaemon)" >&2
    exit 77
  fi
  setup_logging

  BASE=$(read_pin) || { log "no usable config-service pin in $PIN_FILE — not polling"; exit 0; }
  if ! http GET "/api/fleet/deploy-request/$HOST"; then
    log "GET $BASE/api/fleet/deploy-request/$HOST: unreachable — next poll in 15 min"; exit 0
  fi
  if [[ "$HTTP_CODE" != 200 ]]; then
    log "GET $BASE/api/fleet/deploy-request/$HOST: HTTP $HTTP_CODE — next poll in 15 min"; exit 0
  fi
  # The contract, strictly: anything else is not a request.
  local requested rid fast
  requested=$(jq -r --arg host "$HOST" '
    if type == "object" and (.requested | type) == "boolean"
       and (.hostname | type) == "string" and (.hostname | ascii_downcase) == ($host | ascii_downcase)
    then .requested else "invalid" end' <<<"$HTTP_BODY" 2>/dev/null) || requested=invalid
  case "$requested" in
    false) exit 0 ;;
    true) ;;
    *) log "GET answer is not the deploy-request contract for $HOST — ignored"; exit 0 ;;
  esac
  rid=$(jq -r '.request_id // ""' <<<"$HTTP_BODY")
  [[ "$rid" =~ ^[A-Za-z0-9-]{1,64}$ ]] || { log "requested, but request_id '$rid' is not an id — ignored"; exit 0; }
  fast=$(jq -r 'if .fast_lane == true then 1 else 0 end' <<<"$HTTP_BODY")

  local body
  if body=$(final_ack "$rid"); then
    log "request $rid already ran ($RESULT_FILE) — acknowledging its result"
    ack "$body"
    exit 0
  fi

  # `started` once per request, not on every retry of a pending one. A
  # rejected `started` means the request was cancelled or replaced between the
  # GET and now: do not run it. An undelivered one does not stop the run —
  # the owner asked, and the final ack carries the outcome.
  if [[ "$(cat "$STARTED_FILE" 2>/dev/null || true)" != "$rid" ]] && ! state_has_request "$rid"; then
    local arc=0
    ack "$(jq -cn --arg rid "$rid" '{request_id: $rid, status: "started", commit: null, lane: null, reason: null}')" || arc=$?
    case $arc in
      0) mkdir -p "$STATE_DIR" && printf '%s\n' "$rid" >"$STARTED_FILE" ;;
      2) log "request $rid no longer pending — not run"; exit 0 ;;
    esac
  fi

  local -a args=(--requested "$rid")
  [[ "$fast" == 1 ]] && args+=(--fast-lane)
  log "deploy requested (request $rid, fast lane allowed: $([[ "$fast" == 1 ]] && echo yes || echo no)) — running rh7-fleet-update ${args[*]}"
  local rc=0
  # Its own log is /var/log/rh7-fleet-update.log; the result is RESULT_FILE.
  "$FLEET_UPDATE" "${args[@]}" </dev/null >/dev/null 2>&1 || rc=$?
  if body=$(final_ack "$rid"); then
    ack "$body"
  elif state_has_request "$rid"; then
    log "request $rid not done: $(jq -r '"\(.last_result) (\(.reason // "-"))"' "$RESULT_FILE" 2>/dev/null) — retried on the next poll"
  else
    log "request $rid not run (rh7-fleet-update exit $rc, no state from this request: another run holds the lock, or it stopped early) — retried on the next poll"
  fi
  exit 0
}

main "$@"
