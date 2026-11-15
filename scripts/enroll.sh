#!/usr/bin/env bash
# Fleet enroll — one idempotent command to get any device (macOS or Linux) into
# the fleet and keep it there. Safe to run repeatedly on every device:
#
#   1. verifies the device can reach the config service over Tailscale
#   2. checks whether the VERIFIED daily audit (collector-runner) is scheduled
#      AND the host is reporting
#   3. runs a gated audit now + installs/repairs the schedule only if needed
#   4. reports role / age-key follow-ups (issues #208/#209)
#
# On any device (no clone required):
#   curl -fsSL config.rh7labs.com/enroll | bash
#
# Flags:
#   --status   check only; make no changes (report tailscale + audit state)
#   --force    (re)run the audit and reinstall the runner schedule even if healthy
#   --role R   set this device's fleet role so security posture is graded right
#              (personal|developer|server|ai-inference|smart-home|mobile);
#              also honors ROLE=R in the environment. Omit to leave it unchanged.
#
# The heavy lifting lives in collector-runner.sh: it fetches the collector
# (audit-device.sh) from the config service and runs it only after verifying
# sha256 + the server read-only scan + the serving ref, and `--install` schedules
# it daily (LaunchAgent / cron) from a stable on-disk copy — the clone's
# scripts/collector-runner.sh, else a self-installed ~/.cache/fleet-collector/
# collector-runner.sh. Installing it also retires the UNVERIFIED schedules it
# supersedes (the short-link `# fleet-audit` cron line, which ran whatever
# config.rh7labs.com/audit served, and the legacy com.rh7.audit LaunchAgent), so
# a plain re-run of enroll migrates a host that still has either.

set -uo pipefail

OS="$(uname -s)"
# Match audit-device.sh / setup.sh hostname handling: strip a trailing .local,
# preserve case (the config service keys devices by hostname; lowercasing here
# would create a duplicate row — #62).
HOST="$(hostname | sed 's/\.local$//')"
RUNNER_URL="https://config.rh7labs.com/collector-runner"
# Same fallback collector-runner.sh itself uses when the short link is
# undeployed/lagging (the #39 alias trap). TLS either way; the AUDIT the runner
# pulls is gated (sha256 + scan + ref) regardless of where the runner came from.
RUNNER_RAW_FALLBACK="https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/collector-runner.sh"
LOCAL_RUNNER="$HOME/dotfiles/scripts/collector-runner.sh"
LEGACY_AUDIT_LABEL="com.rh7.audit"
# Keep in sync with SHORTLINK_CRON_RE in collector-runner.sh (the line it removes).
SHORTLINK_CRON_RE='rh7labs\.com/audit([^[:alnum:]_.-]|$).*#[[:space:]]*fleet-audit([[:space:]]*$)'

# One positional mode (run|--status|--force) plus an optional role. Role may come
# from the environment (ROLE=server curl…|bash) or a flag (--role server); it's
# applied to the device record after the audit (see post-flight below), so
# posture is set at enroll instead of hand-PATCHed afterwards.
MODE="run"
ROLE="${ROLE:-}"
while [[ $# -gt 0 ]]; do
  arg="${1//[$'\t\r\n ']/}"   # tolerate paste artifacts on flags
  case "$arg" in
    --role=*) ROLE="${arg#--role=}"; shift ;;
    --role)   ROLE="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    run|--run|"") MODE="run"; shift ;;
    --status|status) MODE="status"; shift ;;
    --force|force) MODE="force"; shift ;;
    *) echo "usage: enroll.sh [--status | --force] [--role <role>]" >&2; exit 2 ;;
  esac
done

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

# ── 3. Is the VERIFIED daily audit scheduled? ──────────────────────────────
# Only the integrity-gated collector-runner counts as healthy. A legacy schedule
# that runs unverified bytes — the short-link `# fleet-audit` cron line or the
# direct-audit com.rh7.audit LaunchAgent — means "needs repair", so a plain
# `enroll` (no --force) migrates the host; `collector-runner.sh --install`
# retires both. Functions so we can re-check AFTER the run (post-flight) and
# catch a silently-failed install instead of reporting a false "enrolled".
runner_scheduled() {
  if [[ "$OS" == "Darwin" ]]; then
    launchctl list 2>/dev/null | grep -qE '(^|[[:space:]])com\.rh7\.collector-runner$'
  else
    crontab -l 2>/dev/null | grep -q '# fleet-collector-runner'
  fi
}
legacy_schedule() {  # prints what unverified schedule is present; false if none
  if command -v crontab >/dev/null 2>&1; then
    local ct rc=0
    ct="$(crontab -l 2>&1)" || rc=$?
    # An UNREADABLE crontab (macOS 15+ TCC without Full Disk Access, or any other
    # error — not "no crontab") cannot rule out the short-link line, so it never
    # reads as healthy.
    if [[ $rc -ne 0 && "$ct" != *"no crontab"* ]]; then
      echo "unreadable crontab (${ct:0:120}) — cannot rule out the short-link cron"; return 0
    fi
    if [[ $rc -eq 0 ]] && grep -qE "$SHORTLINK_CRON_RE" <<<"$ct"; then
      echo "unverified short-link cron (# fleet-audit → config.rh7labs.com/audit)"; return 0
    fi
  fi
  if [[ "$OS" == "Darwin" ]] && { [[ -f "$HOME/Library/LaunchAgents/${LEGACY_AUDIT_LABEL}.plist" ]] \
      || launchctl list 2>/dev/null | grep -qE '(^|[[:space:]])com\.rh7\.audit$'; }; then
    echo "legacy unverified ${LEGACY_AUDIT_LABEL} LaunchAgent"; return 0
  fi
  return 1
}
schedule_installed() { runner_scheduled && ! legacy_schedule >/dev/null; }
scheduled=false
schedule_installed && scheduled=true
legacy="$(legacy_schedule || true)"
if $scheduled; then
  ok "Daily audit schedule: verified collector-runner installed"
elif [[ -n "$legacy" ]]; then
  warn "Daily audit schedule: ${legacy} — needs migrating to the verified collector-runner"
else
  warn "Daily audit schedule: not installed"
fi

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
# The runner: the clone's copy when there is one, else fetched to a temp file
# (download-then-exec, never `curl … | bash` — see run_runner).
RUNNER=""; RUNNER_TMP=""
cleanup() { [[ -n "$RUNNER_TMP" ]] && rm -f "$RUNNER_TMP"; return 0; }
trap cleanup EXIT
fetch_runner() {
  [[ -n "$RUNNER" ]] && return 0
  if [[ -f "$LOCAL_RUNNER" ]]; then RUNNER="$LOCAL_RUNNER"; return 0; fi
  # Deliberately NOT named collector-runner.sh: the runner schedules its own $0
  # only when that is an on-disk collector-runner.sh, so a temp copy can never
  # end up as the daily schedule's target.
  RUNNER_TMP="$(mktemp "${TMPDIR:-/tmp}/rh7-enroll-runner.XXXXXX")" || { err "mktemp failed"; return 1; }
  local url
  for url in "$RUNNER_URL" "$RUNNER_RAW_FALLBACK"; do
    if curl -fsSL --max-time 30 "$url" -o "$RUNNER_TMP" 2>/dev/null && [[ -s "$RUNNER_TMP" ]]; then
      RUNNER="$RUNNER_TMP"; return 0
    fi
    warn "could not fetch collector-runner from ${url}"
  done
  err "Failed to download collector-runner.sh (${RUNNER_URL}, ${RUNNER_RAW_FALLBACK})"
  return 1
}

# run_runner [--install] — one gated audit (default) or install/repair the schedule.
# `</dev/null` on the run is load-bearing. The audit's collectors read stdin; when
# *enroll itself* is run via `curl … | bash`, the child inherits enroll's pipe as
# its stdin, so a collector would consume the rest of the ENROLL script —
# truncating enroll's own post-flight (the role apply and the #38 fail-loud
# registry read-back). Running from a file with stdin detached prevents it.
run_runner() {
  fetch_runner || return 1
  if [[ "${1:-}" == "--install" ]]; then
    if [[ "$RUNNER" == "$LOCAL_RUNNER" ]]; then
      info "Installing the verified daily schedule: collector-runner.sh --install (local checkout)"
      bash "$RUNNER" --install </dev/null
    else
      # Fed on stdin so the runner sees no on-disk $0 and self-installs a
      # persistent copy (~/.cache/fleet-collector/collector-runner.sh) for the
      # schedule to point at, instead of scheduling this temp file. --install
      # runs no collector, so nothing in it reads the script off stdin.
      info "Installing the verified daily schedule: collector-runner.sh --install (self-installs a persistent copy)"
      bash -s -- --install <"$RUNNER"
    fi
  else
    info "Running: collector-runner.sh (fetch → verify sha256 + scan → audit)"
    bash "$RUNNER" </dev/null
  fi
}

audit_now() {
  run_runner && return 0
  warn "The gated audit run failed — see ~/.cache/fleet-collector/runner.log"
  return 1
}
install_now() {
  run_runner --install && return 0
  err "collector-runner.sh --install failed — see the messages above / ~/.cache/fleet-collector/runner.log"
  return 1
}

# The runner (unlike the raw audit script) needs python3 to read the collector
# manifest; without it every run — enroll's and the daily one — refuses.
if [[ "$MODE" != "status" ]] && ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required by the verified collector-runner (manifest check) and is not installed."
  err "Install it (e.g. sudo apt-get install -y python3) and re-run."
  exit 1
fi

if [[ "$MODE" == "status" ]]; then
  info "Status-only (no changes made)."
elif [[ "$MODE" == "force" ]]; then
  echo; info "Forcing a fresh audit + schedule reinstall…"
  audit_now; install_now
elif $scheduled && $reporting; then
  echo; ok "${BOLD}Already enrolled and healthy.${NC} Refreshing once to confirm…"
  audit_now
elif $scheduled; then
  echo; info "Scheduled but not reporting — running an audit now to confirm the pipe…"
  audit_now
elif [[ -n "$legacy" ]]; then
  echo; info "Migrating the daily audit to the verified collector-runner (retires the ${legacy})…"
  audit_now; install_now
else
  echo; info "Not yet enrolled — running the first audit and installing the daily schedule…"
  audit_now; install_now
fi
# Re-check the schedule after the run: a failed or partial `--install` (or a
# legacy schedule it could not retire) must NOT be reported as a healthy
# enrollment (see #6).
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

# If a role was supplied (--role / ROLE=…), apply it now that the audit has
# created the device row. Validated against the roles the config service actually
# grades on; applied via PATCH (404s only if the device is absent, which it isn't
# post-audit). No role supplied → the stored role is left untouched (the audit
# preserves it), and the unknown-role hint below still fires.
if [[ -n "$ROLE" && "$MODE" != "status" ]]; then
  role_want="$(printf '%s' "$ROLE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$role_want" in
    personal|developer|server|ai-inference|smart-home|mobile)
      if curl -sf -X PATCH "${CONFIG_URL}/api/devices/${HOST}" \
           -H 'content-type: application/json' \
           -d "{\"role\":\"${role_want}\"}" --max-time 5 >/dev/null 2>&1; then
        ok "role set to '${role_want}'"
        dev_json="$(read_device)"   # refresh so the summary reflects it
      else
        warn "could not set role to '${role_want}' (PATCH failed) — set it later by hand"
      fi ;;
    *)
      warn "ignoring role '${ROLE}': not one of personal/developer/server/ai-inference/smart-home/mobile" ;;
  esac
fi

role="$(printf '%s' "$dev_json" | json_field role)"
echo "${BOLD}Fleet status for ${HOST}:${NC}"
case "$role" in
  ""|unknown)
    warn "role=${role:-unknown} — set it so security posture is graded correctly (e.g. server):"
    echo "     curl -fsSL config.rh7labs.com/enroll | bash -s -- --role server   (or PATCH /api/devices/${HOST})" ;;
  *) ok "role=${role}" ;;
esac
if printf '%s' "$dev_json" | json_is_null age_public_key; then
  warn "no age key registered — secrets/retirement are blind for this host (follow-up: issue #209)"
else
  ok "age key registered"
fi
echo
if $scheduled; then
  ok "${BOLD}Done.${NC} ${HOST} is enrolled and reporting; the verified daily audit (collector-runner) keeps it current."
elif [[ "$MODE" == "status" ]]; then
  warn "${BOLD}Enrolled, but no verified daily audit schedule is installed${legacy:+ (found: ${legacy})}.${NC} Re-run without --status to install/migrate it."
else
  # The schedule did NOT install (or a legacy unverified one is still there) —
  # don't claim "the daily audit keeps it current", or the host silently goes stale.
  err "${BOLD}Enrolled, but the verified daily audit schedule did NOT install.${NC} ${HOST} is in the registry,"
  err "but without the collector-runner schedule it will go stale (or keep running unverified bytes)."
  legacy_left="$(legacy_schedule || true)"
  [[ -n "$legacy_left" ]] && err "Still present: ${legacy_left}"
  err "See the collector-runner messages above / ~/.cache/fleet-collector/runner.log for the cause."
  if [[ "$OS" == "Darwin" ]]; then
    [[ "$legacy_left" == *cron* ]] && err "macOS blocks crontab without Full Disk Access: grant it to this terminal (System Settings → Privacy & Security → Full Disk Access), or remove the '# fleet-audit' line with: crontab -e"
  else
    err "Check cron:  command -v crontab || echo 'cron not installed'; systemctl status cron 2>/dev/null || true"
  fi
  err "Then retry:  curl -fsSL config.rh7labs.com/enroll | bash"
  exit 1
fi
