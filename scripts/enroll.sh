#!/usr/bin/env bash
# Fleet enroll — one idempotent command to get any device (macOS or Linux) into
# the fleet and keep it there. Safe to run repeatedly on every device:
#
#   1. verifies the device can reach the config service over Tailscale
#   2. checks whether the daily audit is already scheduled AND reporting
#   3. runs an audit now + installs the daily schedule only if needed
#   4. reports role / age-key follow-ups (issues #208/#209)
#
# On any device (no clone required):
#   curl -fsSL config.rh7labs.com/enroll | bash
#
# Flags:
#   --status   check only; make no changes (report tailscale + audit state)
#   --force    (re)run the audit and reinstall the schedule even if healthy
#
# The heavy lifting (inventory + registration + scheduling) lives in
# audit-device.sh; this is just the safe, idempotent front-door around it.

set -uo pipefail

OS="$(uname -s)"
# Match audit-device.sh / setup.sh hostname handling: strip a trailing .local,
# preserve case (the config service keys devices by hostname; lowercasing here
# would create a duplicate row — #62).
HOST="$(hostname | sed 's/\.local$//')"
AUDIT_URL="https://config.rh7labs.com/audit"
LOCAL_AUDIT="$HOME/dotfiles/scripts/audit-device.sh"

MODE="${1:-run}"
MODE="${MODE//[$'\t\r\n ']/}"   # tolerate paste artifacts on the flag
case "$MODE" in
  run|--run|"") MODE="run" ;;
  --status|status) MODE="status" ;;
  --force|force) MODE="force" ;;
  *) echo "usage: enroll.sh [--status | --force]" >&2; exit 2 ;;
esac

# ── Colors / helpers ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi
info() { echo "${BLUE}ℹ${NC}  $*"; }
ok()   { echo "${GREEN}✓${NC}  $*"; }
warn() { echo "${YELLOW}⚠${NC}  $*"; }
err()  { echo "${RED}✗${NC}  $*" >&2; }

# run_timeout SECS CMD… — hard timeout so a wedged daemon (e.g. a stuck
# tailscaled, #61) can't hang enroll. Prefers coreutils timeout; falls back to
# perl (ships on macOS, which has no `timeout`); worst case runs unbounded.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; my $p=fork; if($p){$SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm $s; waitpid $p,0; exit($?>>8)} else {exec @ARGV or exit 127}' "$secs" "$@"
  else "$@"; fi
}

# json_field KEY — pull a flat top-level string/scalar field out of a small JSON
# object on stdin. Deliberately dependency-free (no jq/python) so it works on a
# bare box before the audit toolchain exists. Returns "" for null/absent.
json_field() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
json_is_null() {  # json_is_null KEY  → true if "key": null
  local key="$1"
  grep -qE "\"${key}\"[[:space:]]*:[[:space:]]*null"
}

echo "${BOLD}Fleet enroll — ${HOST} (${OS})${NC}"

# ── 0. Validate our own identity up front ──────────────────────────────────
# The config service rejects placeholder identities (#150) — an unexpanded
# $(hostname), 'localhost', shell residue. Catch them here and fail with a clear
# fix instead of running a full audit the server then 400s (the box literally
# named 'hostname' that silently reported "enrolled", 2026-07-09).
host_lc="$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')"
case "$host_lc" in
  ""|hostname|localhost|localhost.localdomain|unknown|'$(hostname)'|'${hostname}')
    err "This machine reports its hostname as '${HOST}' — a placeholder, not a real name."
    err "The fleet rejects it (#150), so enrollment can't proceed. Set a real hostname first:"
    err "  Linux:  sudo hostnamectl set-hostname my-real-name   (then re-open the shell)"
    err "  macOS:  sudo scutil --set HostName my-real-name"
    exit 1 ;;
esac
if printf '%s' "$HOST" | grep -q '[[:space:]$`]'; then
  err "Hostname '${HOST}' contains whitespace/shell characters — looks like an unexpanded variable (#150)."
  err "Fix the machine's hostname before enrolling."
  exit 1
fi

# ── 1. Tailscale ───────────────────────────────────────────────────────────
TS=""
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/bin/tailscale; do
  command -v "$c" >/dev/null 2>&1 && { TS="$c"; break; }
  [[ -x "$c" ]] && { TS="$c"; break; }
done

if [[ -n "$TS" ]]; then
  ts_state="$(run_timeout 5 "$TS" status --json 2>/dev/null | json_field BackendState)"
  case "$ts_state" in
    Running) ok "Tailscale: connected" ;;
    "")      warn "Tailscale: installed but state unknown (daemon slow?) — continuing" ;;
    *)       warn "Tailscale: not connected (state: ${ts_state}) — run: ${BOLD}tailscale up${NC}" ;;
  esac
else
  warn "Tailscale CLI not found — will still test reachability (userspace/other install?)"
fi

# ── 2. Reach the config service (authoritative connectivity gate) ──────────
CONFIG_URL=""
for h in 100.100.241.110 rouvens-mac-studio-1 localhost rouvens-mac-studio Rouvens-Mac-Studio.local; do
  if curl -sf "http://${h}:3456/api/health" --max-time 3 >/dev/null 2>&1; then
    CONFIG_URL="http://${h}:3456"; break
  fi
done
if [[ -z "$CONFIG_URL" ]]; then
  err "Config service unreachable on the tailnet (tried rouvens-mac-studio-1:3456 / 100.100.241.110:3456)."
  err "Make sure Tailscale is up (${BOLD}tailscale up${NC}) and this device is on the tailnet, then re-run."
  exit 1
fi
ok "Config service reachable: ${CONFIG_URL}"

# ── 3. Is the daily audit already scheduled? ───────────────────────────────
# A function so we can re-check AFTER the audit run (post-flight #6) and catch a
# silently-failed schedule install instead of reporting a false "enrolled".
schedule_installed() {
  if [[ "$OS" == "Darwin" ]]; then
    # collector-runner supersedes the direct audit agent; either counts as scheduled
    launchctl list 2>/dev/null | grep -qE 'com\.rh7\.(collector-runner|audit)'
  else
    crontab -l 2>/dev/null | grep -qE 'fleet-audit|collector-runner|audit-device\.sh'
  fi
}
scheduled=false
schedule_installed && scheduled=true
$scheduled && ok "Daily audit schedule: installed" || warn "Daily audit schedule: not installed"

# ── 4. Is this host already reporting? ─────────────────────────────────────
dev_json="$(curl -sf "${CONFIG_URL}/api/devices/${HOST}" --max-time 5 2>/dev/null || true)"
last_seen=""; age_h=""
if [[ -n "$dev_json" && "$dev_json" != *'"error"'* ]]; then
  last_seen="$(printf '%s' "$dev_json" | json_field last_seen)"
  if [[ -n "$last_seen" ]] && command -v python3 >/dev/null 2>&1; then
    age_h="$(python3 - "$last_seen" <<'PY' 2>/dev/null || true
import sys, datetime as d
try:
    t = d.datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")
    print(round((d.datetime.utcnow() - t).total_seconds()/3600, 1))
except Exception:
    pass
PY
)"
  fi
fi
reporting=false
if [[ -n "$last_seen" ]]; then
  if [[ -n "$age_h" ]]; then
    # under 30h ≈ within the daily-audit cadence (online threshold is 26h)
    awk "BEGIN{exit !($age_h < 30)}" && reporting=true
    $reporting && ok "Reporting: last audit ${age_h}h ago" || warn "Reporting: stale (last audit ${age_h}h ago)"
  else
    reporting=true; ok "Reporting: last audit ${last_seen} UTC"
  fi
else
  warn "Reporting: this host has never uploaded an audit"
fi

# ── Decide ─────────────────────────────────────────────────────────────────
run_audit() {  # run_audit MODE_FLAG
  local flag="$1"
  if [[ -f "$LOCAL_AUDIT" ]]; then
    info "Running: audit-device.sh ${flag} (local checkout)"
    bash "$LOCAL_AUDIT" "$flag"
  else
    info "Running: curl config.rh7labs.com/audit | bash -s -- ${flag}"
    curl -fsSL "$AUDIT_URL" | bash -s -- "$flag"
  fi
}

if [[ "$MODE" == "status" ]]; then
  info "Status-only (no changes made)."
elif [[ "$MODE" == "force" ]]; then
  echo; info "Forcing a fresh audit + schedule reinstall…"
  run_audit --run-and-install
elif $scheduled && $reporting; then
  echo; ok "${BOLD}Already enrolled and healthy.${NC} Refreshing once to confirm…"
  run_audit --run
elif $scheduled; then
  echo; info "Scheduled but not reporting — running an audit now to confirm the pipe…"
  run_audit --run
else
  echo; info "Not yet enrolled — running the first audit and installing the daily schedule…"
  run_audit --run-and-install
fi
# Re-check the schedule after the run: the audit script installs cron at the end,
# and a failure there must NOT be reported as a healthy enrollment (see #6).
scheduled=false
schedule_installed && scheduled=true

# ── 5. Post-flight: confirm the device actually landed, then role/age follow-ups ──
# The read-back is authoritative: if the host isn't in the registry after the
# audit run, the upload/registration was rejected (e.g. an invalid hostname the
# server 400s, #150) — so FAIL LOUD, never print a false "enrolled".
echo
read_device() { curl -sf "${CONFIG_URL}/api/devices/${HOST}" --max-time 5 2>/dev/null || true; }
dev_json="$(read_device)"
if [[ -z "$dev_json" || "$dev_json" == *'"error"'* ]]; then
  sleep 2; dev_json="$(read_device)"   # one retry in case the ingest is still committing
fi

if [[ -z "$dev_json" || "$dev_json" == *'"error"'* ]]; then
  if [[ "$MODE" == "status" ]]; then
    warn "${HOST} is not in the fleet registry (never enrolled). Re-run without --status to enroll."
    exit 0
  fi
  err "${BOLD}Enrollment did NOT complete.${NC} ${HOST} is not in the fleet registry after the audit run."
  err "The audit upload / registration was rejected — most likely an invalid hostname (#150) or a"
  err "service-side error. Confirm the hostname is a real name (not 'hostname'/'localhost'), then"
  err "re-run. If it persists, check the config-service logs on the Studio."
  exit 1
fi

role="$(printf '%s' "$dev_json" | json_field role)"
echo "${BOLD}Fleet status for ${HOST}:${NC}"
case "$role" in
  ""|unknown)
    warn "role=${role:-unknown} — set it so security posture is graded correctly (e.g. server):"
    echo "     curl -X PATCH ${CONFIG_URL}/api/devices/${HOST} -H 'content-type: application/json' -d '{\"role\":\"server\"}'" ;;
  *) ok "role=${role}" ;;
esac
if printf '%s' "$dev_json" | json_is_null age_public_key; then
  warn "no age key registered — secrets/retirement are blind for this host (follow-up: issue #209)"
else
  ok "age key registered"
fi
echo
if $scheduled; then
  ok "${BOLD}Done.${NC} ${HOST} is enrolled and reporting; the daily audit keeps it current."
elif [[ "$MODE" == "status" ]]; then
  warn "${BOLD}Enrolled, but no daily audit schedule is installed.${NC} Re-run without --status to install it."
else
  # The audit uploaded, but the recurring schedule did NOT install — don't claim
  # "the daily audit keeps it current", or the host silently goes stale.
  err "${BOLD}Enrolled, but the daily audit schedule did NOT install.${NC} ${HOST} uploaded an audit,"
  err "but without a schedule it will go stale. See the audit run's messages above for the cause."
  [[ "$OS" != "Darwin" ]] && err "Check cron:  command -v crontab || echo 'cron not installed'; systemctl status cron 2>/dev/null || true"
  err "Then retry:  curl -fsSL config.rh7labs.com/enroll | bash -s -- --force"
  exit 1
fi
