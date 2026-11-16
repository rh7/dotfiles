#!/usr/bin/env bash
# Coverage for scripts/deploy-request.sh (the org.rh7.deploy-request poller).
#
# Run: ./scripts/tests/deploy-request.test.sh   (needs jq)
#
# The poller is the only way a household Mac learns that the owner wants it
# deployed now, and its acknowledgement is the only way he learns how it went.
# Pinned here: it is silent and does nothing when nothing is requested or the
# service is away; it runs the update once per request and never twice for the
# same request; the final ack carries THIS request_id and the result mapped
# from state.json; transient holds (lock held by the nightly run, battery,
# manual rebuild) leave the request pending for the next poll.
#
# curl and rh7-fleet-update are stubs. The end-to-end path through the real
# scripts/fleet-update.sh (lock contention included) is in
# scripts/tests/fleet-update.test.sh.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
POLLER="$HERE/../deploy-request.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { # check <description> <actual> <expected>
  if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

W=$(mktemp -d /tmp/dr.XXXXXX)
trap 'rm -rf "$W"' EXIT

SHA_A=$(printf 'a%.0s' $(seq 1 40))
SHA_B=$(printf 'b%.0s' $(seq 1 40))

# ── Stubs ────────────────────────────────────────────────────────────────────
STUBS="$W/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
# The config service. GET -> $STUB_GET_BODY with $STUB_GET_CODE (default 200;
# "down" = transport error); POST -> body appended to $STUB_ACKS, answered
# with the next code from $STUB_ACK_CODES (space-separated; default 200).
url="" out="" fmt="" method=GET data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "curl $method $url" >>"$STUB_LOG"
if [[ "$method" == GET ]]; then
  [[ "${STUB_GET_CODE:-200}" != down ]] || exit 7
  code=${STUB_GET_CODE:-200}; body=${STUB_GET_BODY:-}
else
  [[ "$url" == */ack ]] || exit 2
  echo "$data" >>"$STUB_ACKS"
  n=$(wc -l <"$STUB_ACKS" | tr -d ' ')
  read -r -a codes <<<"${STUB_ACK_CODES:-200}"
  code=${codes[$((n - 1))]:-${codes[${#codes[@]}-1]}}
  [[ "$code" != down ]] || exit 7
  body='{}'
fi
if [[ -n "$out" ]]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
[[ -z "$fmt" ]] || printf '%s' "$code"
EOF
cat >"$STUBS/rh7-fleet-update" <<'EOF'
#!/usr/bin/env bash
# Records its arguments; writes $STUB_STATE (a jq program over the request id,
# $rid) as state.json unless it is "none" (lock held: nothing written).
echo "fleet-update $*" >>"$STUB_LOG"
rid=""; while [[ $# -gt 0 ]]; do [[ "$1" == --requested ]] && rid="$2"; shift; done
[[ "${STUB_STATE:-none}" == none ]] && exit 0
mkdir -p "$DEPLOY_REQUEST_ROOT/var/lib/rh7-fleet-update"
jq -n --arg rid "$rid" "$STUB_STATE" >"$DEPLOY_REQUEST_ROOT/var/lib/rh7-fleet-update/state.json"
EOF
chmod +x "$STUBS"/*

# state <result> <reason|null> <lane|null> <fast_lane_reason|null> — a jq
# program building a requested run's state.json.
state() {
  printf '{schema: 1, enabled: true, channel: "fleet/stable", last_run_at: "2026-11-16T10:00:00Z",
    last_result: "%s", reason: %s, target_commit: "%s", applied_commit: "%s",
    last_success_at: null, generation: 3, consecutive_failures: 0,
    request_id: $rid, lane: %s, fast_lane_reason: %s}' \
    "$1" "$(q "$2")" "$SHA_B" "$SHA_A" "$(q "$3")" "$(q "$4")"
}
q() { if [[ "$1" == null ]]; then echo null; else printf '"%s"' "$1"; fi; }
request() { # request <id> <fast_lane true|false> — the GET body of a pending request
  printf '{"hostname":"Test-Host","requested":true,"request_id":"%s","requested_at":"2026-11-16T09:58:00Z","fast_lane":%s,"last_result":null}' "$1" "$2"
}
IDLE='{"hostname":"test-host","requested":false,"request_id":null,"requested_at":null,"fast_lane":false,"last_result":null}'

# ── Harness ──────────────────────────────────────────────────────────────────
CASE=0
fresh() {
  CASE=$((CASE+1))
  ROOT="$W/case$CASE"
  mkdir -p "$ROOT/etc/rh7"
  printf '# pinned by nix\nhttp://100.100.241.110:3456\n' >"$ROOT/etc/rh7/config-service"
  : >"$ROOT/stub.log"; : >"$ROOT/acks"
}
run_dr() {
  OUT=$(env DEPLOY_REQUEST_ROOT="$ROOT" PATH="$STUBS:$PATH" STUB_LOG="$ROOT/stub.log" STUB_ACKS="$ROOT/acks" \
        bash "$POLLER" --hostname test-host --fleet-update "$STUBS/rh7-fleet-update" 2>&1)
  RC=$?
}
runs() { grep -c '^fleet-update ' "$ROOT/stub.log" || true; }
acks() { jq -c . "$ROOT/acks" 2>/dev/null | paste -sd '|' -; }
ack_n() { sed -n "${1}p" "$ROOT/acks"; }
logf() { cat "$ROOT/var/log/rh7-deploy-request.log" 2>/dev/null; }

# ── Cases ────────────────────────────────────────────────────────────────────
echo ""
echo "deploy-request — nothing requested / service away (silent, nothing run)"
fresh
STUB_GET_BODY="$IDLE" run_dr
check "nothing requested: exit 0" "$RC" "0"
check "nothing requested: update not run" "$(runs)" "0"
check "nothing requested: no ack" "$(acks)" ""
check "nothing requested: nothing logged" "$(logf)" ""
grep -q 'curl GET http://100.100.241.110:3456/api/fleet/deploy-request/test-host$' "$ROOT/stub.log" \
  && good "polls the pinned service for its baked-in host" || bad "polls the pinned service" "$(cat "$ROOT/stub.log")"

fresh
STUB_GET_CODE=down run_dr
check "service unreachable: exit 0" "$RC" "0"
check "service unreachable: update not run" "$(runs)" "0"
grep -q 'unreachable' <<<"$(logf)" && good "service unreachable: one log line" || bad "unreachable logged" "$(logf)"

fresh
STUB_GET_CODE=404 STUB_GET_BODY='{"error":"unknown host"}' run_dr
check "HTTP 404: exit 0, nothing run" "$RC/$(runs)" "0/0"

fresh; rm "$ROOT/etc/rh7/config-service"
STUB_GET_BODY="$(request r1 true)" run_dr
check "no pin: nothing polled" "$(grep -c curl "$ROOT/stub.log")" "0"
check "no pin: exit 0" "$RC" "0"

fresh
for body in 'not json' '{"requested":"yes","hostname":"test-host"}' \
            "$(request r1 true | jq -c '.hostname = "other-host"')" \
            "$(request 'r1;rm -rf' true)" "$(request r1 true | jq -c 'del(.request_id)')"; do
  STUB_GET_BODY="$body" run_dr
done
check "malformed / other host / bad request_id: never runs" "$(runs)" "0"
check "malformed / other host / bad request_id: never acks" "$(acks)" ""

echo ""
echo "deploy-request — a request runs once and is acknowledged with its own id"
fresh
STUB_GET_BODY="$(request 3f2c-req-1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "requested: exit 0" "$RC" "0"
check "requested: update run once" "$(runs)" "1"
grep -q '^fleet-update --requested 3f2c-req-1 --fast-lane$' "$ROOT/stub.log" \
  && good "runs rh7-fleet-update --requested <id> --fast-lane" || bad "fleet-update args" "$(cat "$ROOT/stub.log")"
check "first ack: started, with the request id" "$(ack_n 1 | jq -c .)" \
  '{"request_id":"3f2c-req-1","status":"started","commit":null,"lane":null,"reason":null}'
check "final ack: applied, commit, lane fast, same id" "$(ack_n 2 | jq -c .)" \
  "{\"request_id\":\"3f2c-req-1\",\"status\":\"applied\",\"commit\":\"$SHA_A\",\"lane\":\"fast\",\"reason\":null}"
grep -q 'POST http://100.100.241.110:3456/api/fleet/deploy-request/test-host/ack$' "$ROOT/stub.log" \
  && good "acks to /api/fleet/deploy-request/<host>/ack" || bad "ack url" "$(cat "$ROOT/stub.log")"

# The server keeps returning it until the ack lands; once acked it would not,
# but if it still does (ack response lost), the result is re-sent, not re-run.
STUB_GET_BODY="$(request 3f2c-req-1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "same request again: update not re-run" "$(runs)" "1"
check "same request again: only the final ack re-sent" "$(ack_n 3 | jq -r .status)" "applied"
check "same request again: no second started" "$(grep -c started "$ROOT/acks")" "1"

fresh
STUB_ACK_CODES="409" STUB_GET_BODY="$(request gone-1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "started rejected (cancelled/replaced since the GET): update not run" "$(runs)" "0"
grep -q 'request gone-1 no longer pending — not run' <<<"$(logf)" && good "started rejected: logged" || bad "started rejected log" "$(logf)"

fresh
STUB_ACK_CODES="down 200" STUB_GET_BODY="$(request down-1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "started undelivered (transport): still runs and acks the result" "$(runs)/$(ack_n 2 | jq -r .status)" "1/applied"

fresh
env DEPLOY_REQUEST_ROOT="$ROOT" PATH="$STUBS:$PATH" STUB_LOG="$ROOT/stub.log" STUB_ACKS="$ROOT/acks" \
  STUB_GET_BODY="$IDLE" bash "$POLLER" --hostname Test-Host --fleet-update "$STUBS/rh7-fleet-update" >/dev/null 2>&1
grep -q 'curl GET http://100.100.241.110:3456/api/fleet/deploy-request/test-host$' "$ROOT/stub.log" \
  && good "mixed-case flake attr polls the canonical lower-case host" || bad "lower-case host" "$(cat "$ROOT/stub.log")"

fresh
STUB_GET_BODY="$(request r2 false)" STUB_STATE="$(state applied null channel not-requested)" run_dr
grep -q '^fleet-update --requested r2$' "$ROOT/stub.log" \
  && good "fast_lane false: no --fast-lane" || bad "fast_lane false args" "$(cat "$ROOT/stub.log")"
check "channel lane, fast lane not asked: reason null" "$(ack_n 2 | jq -c '{status, lane, reason}')" \
  '{"status":"applied","lane":"channel","reason":null}'

fresh
STUB_GET_BODY="$(request r3 true)" STUB_STATE="$(state applied null channel other-files)" run_dr
check "fast lane not eligible: reason names it" "$(ack_n 2 | jq -c '{status, lane, reason}')" \
  '{"status":"applied","lane":"channel","reason":"fast-lane:other-files"}'

echo ""
echo "deploy-request — result mapping"
map_case() { # map_case <label> <result> <reason> <expected status> <expected commit> [expected reason]
  fresh
  STUB_GET_BODY="$(request m1 true)" STUB_STATE="$(state "$2" "$3" channel ci-unknown)" run_dr
  check "$1 -> $4" "$(ack_n 2 | jq -r '"\(.status) \(.commit)"')" "$4 $5"
  [[ -z "${6:-}" ]] || check "$1: reason" "$(ack_n 2 | jq -r .reason)" "$6"
}
map_case "no-op" no-op null no-op "$SHA_A"
map_case "refused" refused signature-invalid refused "$SHA_B" "signature-invalid; fast-lane:ci-unknown"
map_case "failed" failed build-failed failed "$SHA_B" "build-failed; fast-lane:ci-unknown"
map_case "skipped/channel-behind" skipped channel-behind no-op "$SHA_A" "channel-behind; fast-lane:ci-unknown"
map_case "skipped/dock-protect" skipped dock-protect failed "$SHA_B" "dock-protect; fast-lane:ci-unknown"

echo ""
echo "deploy-request — transient holds keep the request pending"
fresh
STUB_GET_BODY="$(request t1 true)" STUB_STATE="$(state skipped on-battery null null)" run_dr
check "on battery: only started acked" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started"
grep -q 'request t1 not done: skipped (on-battery)' <<<"$(logf)" && good "on battery: logged as pending" || bad "on-battery log" "$(logf)"
STUB_GET_BODY="$(request t1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "next poll: run again" "$(runs)" "2"
check "next poll: no second started, then applied" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started applied"

fresh
STUB_GET_BODY="$(request l1 true)" STUB_STATE=none run_dr
check "lock held by the nightly run (no state written): only started" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started"
grep -q 'another run holds the lock' <<<"$(logf)" && good "lock held: logged as pending" || bad "lock-held log" "$(logf)"
STUB_GET_BODY="$(request l1 true)" STUB_STATE=none run_dr
check "still locked: started not repeated" "$(grep -c started "$ROOT/acks")" "1"
STUB_GET_BODY="$(request l1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "lock free: applied acked" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started applied"

fresh
STUB_GET_BODY="$(request s1 true)" STUB_STATE="$(state skipped rebuild-in-progress null null)" run_dr
check "manual rebuild running: no final ack" "$(jq -r .status "$ROOT/acks" | paste -sd ' ' -)" "started"

echo ""
echo "deploy-request — ack delivery"
fresh
STUB_ACK_CODES="200 down 200" STUB_GET_BODY="$(request d1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "final ack lost in transit: run once" "$(runs)" "1"
grep -q 'ack applied: config service unreachable' <<<"$(logf)" && good "lost ack: logged" || bad "lost ack logged" "$(logf)"
STUB_ACK_CODES="200 down 200" STUB_GET_BODY="$(request d1 true)" STUB_STATE="$(state applied null fast null)" run_dr
check "next poll: re-sends the result from state.json, no re-run" "$(runs)/$(ack_n 3 | jq -r '"\(.request_id) \(.status)"')" "1/d1 applied"

fresh
STUB_ACK_CODES="200 409" STUB_GET_BODY="$(request x1 true)" STUB_STATE="$(state applied null fast null)" run_dr
grep -q 'ack applied rejected (HTTP 409)' <<<"$(logf)" && good "409 (cancelled/replaced): logged and dropped" || bad "409 log" "$(logf)"
check "409: exit 0" "$RC" "0"

fresh
STUB_GET_BODY="$(request new-2 true)" STUB_STATE="$(state applied null fast null)" run_dr
mkdir -p "$ROOT/var/lib/rh7-fleet-update"
jq '.request_id = "old-1"' "$ROOT/var/lib/rh7-fleet-update/state.json" >"$W/s" && mv "$W/s" "$ROOT/var/lib/rh7-fleet-update/state.json"
: >"$ROOT/acks"
STUB_GET_BODY="$(request new-3 true)" STUB_STATE="$(state no-op null channel same-as-channel)" run_dr
check "a newer request id: runs again, acks with ITS id" "$(runs)/$(ack_n 2 | jq -r .request_id)" "2/new-3"

echo ""
echo "deploy-request — usage"
fresh
OUT=$(env DEPLOY_REQUEST_ROOT="$ROOT" bash "$POLLER" --hostname 'bad host' --fleet-update "$STUBS/rh7-fleet-update" 2>&1); RC=$?
check "bad --hostname rejected" "$RC" "64"
OUT=$(env DEPLOY_REQUEST_ROOT="$ROOT" bash "$POLLER" --hostname test-host --fleet-update /nonexistent 2>&1); RC=$?
check "missing --fleet-update rejected" "$RC" "64"
grep -q -- '--fleet-update must be' <<<"$OUT" && good "missing --fleet-update: says so" || bad "missing --fleet-update message" "$OUT"

echo ""
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
