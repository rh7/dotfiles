#!/usr/bin/env bash
# scripts/fleet-update.sh — unattended nightly config update for a nix-darwin Mac.
#
# Runs as ROOT from the org.rh7.fleet-update LaunchDaemon declared by
# modules/darwin/fleet-update.nix (read that header for the full design and for
# what an unattended run deliberately does NOT do). It is never run from
# ~/dotfiles: the module copies THIS file into the nix store and wraps it as
# /run/current-system/sw/bin/rh7-fleet-update, so the code, the pinned signer
# key and the git/gpg it uses all come from the ACTIVATED generation — never
# from the tree it is about to fetch.
#
# Per run, in order (first failing step decides the result):
#   1. preconditions  single-instance lock (lock-held: logged, state untouched);
#                     no darwin-rebuild / rebuild.sh running (checked again
#                     before activation); on AC power -> skipped
#   2. fetch          root-owned checkout /var/lib/rh7-fleet-update/dotfiles,
#                     fetch `main` + the channel     -> failed / fetch-failed
#   3. trust          channel tip T must
#                       - carry a signature that verifies against ONLY the
#                         pinned key                 -> refused / signature-invalid
#                                                       (signer-key-expired)
#                       - be ancestor-or-equal of origin/main
#                                                    -> refused / not-in-main
#                       - be descendant-or-equal of the last applied commit
#                                                    -> refused / not-fast-forward
#                       - be descendant-or-equal of the running generation's
#                         configurationRevision R (first run, manual rebuilds),
#                         EXCEPT when T is an ancestor of a clean R that is
#                         itself in origin/main (hand-rebuilt from NEWER merged
#                         main: wait for the channel)
#                                                    -> skipped / channel-behind
#                         R unmerged/local/-dirty, or T and R diverged
#                                                    -> refused / not-fast-forward
#   4. no-op          T already applied and the system is still that generation
#   5. dock-protect   evaluate T's system.defaults.dock.persistent-apps and
#                     persistent-others; each one that is set (that side of
#                     the Dock is managed) REPLACES that side of the primary
#                     user's Dock on activation, so every app, folder, stack,
#                     file or web link now in it that T does not declare would
#                     vanish -> skipped / dock-protect (with the list in
#                     state.dock_protect). An unreadable Dock plist holds too
#                     (fail safe). Additions only, or an unmanaged Dock,
#                     proceed. Only rebuild.sh, which shows the drift and
#                     asks, may remove Dock items. The Dock is compared again
#                     after the build, right before activation (step 7).
#                     evaluation fails             -> failed / build-failed
#   5b. brew user     T runs `brew bundle` as its homebrew.user. Refused when
#                     a cask not yet in the Caskroom would be installed while
#                     that user cannot write /Applications (a standard
#                     account: Homebrew falls back to its own sudo, which can
#                     only fail unattended), or when Homebrew's own prefix
#                     directories are not that user's (homebrew.user changed; only rebuild.sh
#                     migrates it) — either fails AFTER the profile switched
#                                                    -> failed / brew-failed
#                     (logged with the cause and the fix; nothing built —
#                     the same reason as a `brew bundle` failure in step 7)
#   6. build          darwinConfigurations.<attr>.system, <attr> baked in by
#                     the module, never derived from the runtime hostname
#                                                    -> failed / build-failed
#   7. activate       set the system profile, run <out>/activate, stdin closed
#                                                    -> failed / activation-failed
#                                                       (brew-failed)
#                     primary user logged out on a household Mac: agents
#                     installed for her next login -> applied, note logged
#   8. state          /var/lib/rh7-fleet-update/state.json, atomic (contract:
#                     rh7/rh-device-management, audit key `fleet_update`)
#
# REQUESTED RUNS ("deploy now", --requested <request-id>). Started by the
# org.rh7.deploy-request poller (scripts/deploy-request.sh) when the owner asked
# the config service to deploy this host now. Same lock, same trust checks,
# same build/activation and state reporting as the nightly run, with three
# differences:
#   - no jitter, and on battery it proceeds when the charge is at least
#     REQUEST_MIN_BATTERY (50%) — the owner is waiting, and half a charge
#     covers a build + activation; below that (or unknown) -> skipped /
#     on-battery and the poller retries on its next interval;
#   - with --fast-lane (the owner allowed it for this request) the target may
#     be the signed `origin/main` tip instead of the channel tip, ONLY when
#     the change from the channel tip is fast-lane eligible (choose_lane:
#     signed by the pinned key, a strict descendant of the channel tip, the
#     diff touches nothing but this host's own file — --fast-lane-file, baked
#     in by the module — and in it only adds cask/formula/package list
#     entries or comments, and CI is green on it per the public GitHub API).
#     Anything else, or any doubt, applies the channel tip (`lane: channel`,
#     `fast_lane_reason` says why). The channel itself is never moved: the host
#     is then ahead of it, and later channel runs record skipped /
#     channel-behind until the channel catches up (`applied_lane: fast`);
#   - state.json additionally carries `request_id`, `lane` and
#     `fast_lane_reason` (keys present only on a requested run's state).
#
# Exit status: 0 applied / no-op / skipped / dry-run, 1 failed (or unreadable
# state), 3 refused, 64 usage, 77 not root.
#
# FLEET_UPDATE_ROOT (tests only) prefixes every absolute path this script owns
# (state, lock, log, system profile, /run/current-system), so the suite in
# scripts/tests/fleet-update.test.sh runs unprivileged in a sandbox. Unset in
# production, where root is required.
set -euo pipefail

ROOT="${FLEET_UPDATE_ROOT:-}"
STATE_DIR="$ROOT/var/lib/rh7-fleet-update"
STATE_FILE="$STATE_DIR/state.json"
CHECKOUT="$STATE_DIR/dotfiles"
BUILD_LINK="$STATE_DIR/result"
LOCK_DIR="$ROOT/var/run/rh7-fleet-update.lock"
LOG_FILE="$ROOT/var/log/rh7-fleet-update.log"
LOG_MAX_BYTES=$((1024 * 1024))
SYSTEM_PROFILE="$ROOT/nix/var/nix/profiles/system"
CURRENT_SYSTEM="$ROOT/run/current-system"
REPO_URL="${FLEET_UPDATE_REPO_URL:-https://github.com/rh7/dotfiles}"

FETCH_TIMEOUT=600
BUILD_TIMEOUT=$((3 * 3600))
ACTIVATE_TIMEOUT=3600
EVAL_TIMEOUT=900
JITTER_MAX=1800
CI_TIMEOUT=30
REQUEST_MIN_BATTERY=50
# Public, unauthenticated GitHub API: CI state of a fast-lane candidate.
GITHUB_API="https://api.github.com"
GITHUB_REPO="rh7/dotfiles"

CHANNEL=""
FLAKE_ATTR=""
SIGNER_KEY=""
PRIMARY_USER=""
SCHEDULED=0
DRY_RUN=0
FORCE_CHECK=0
REQUEST_ID=""      # --requested: the config service's deploy-request id
FAST_LANE=0        # --fast-lane: the owner allowed the fast lane for it
FAST_LANE_FILE=""  # --fast-lane-file: this host's own file, baked by the module

usage() {
  cat <<'EOF'
Usage: rh7-fleet-update [--dry-run] [--force-check] [--requested <id> [--fast-lane]]
  (the module wrapper supplies --channel/--flake-attr/--signer-key/--primary-user
   and, on a host with its own host file, --fast-lane-file)

  --dry-run      run every precondition, trust and Dock check, report what
                 would be applied; never builds, activates or writes the
                 state file
  --force-check  run now even on battery power (no jitter). Never relaxes any
                 trust check.
  --scheduled    launchd entry point: random start delay of up to 30 minutes
  --requested <id>
                 an owner-requested deploy (org.rh7.deploy-request): no jitter,
                 on battery only with >= 50% charge; the id is recorded in
                 state.json for the poller's acknowledgement
  --fast-lane    with --requested: apply the signed main tip instead of the
                 channel tip when the change is fast-lane eligible
EOF
}

# ── Generic helpers ──────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Logs go to stderr so functions whose stdout is captured can still log.
log() { printf '%s [fleet-update] %s\n' "$(now_iso)" "$*" >&2; }

# Bound every network/build step: an unattended job that hangs holds the lock
# forever and is indistinguishable from "nothing to do". coreutils `timeout` is
# on the wrapper's PATH; without it (never in production) run unbounded.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=60 "$secs" "$@"
  else
    "$@"
  fi
}

# Deterministic git: no user/system config (credential helpers, hooksPath,
# url rewrites, gpg.program) can reach the root daemon's trust decisions.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
g() { git -C "$CHECKOUT" "$@"; }

# Generation number of the system profile (system-N-link), or empty.
current_generation() {
  local target
  target=$(readlink "$SYSTEM_PROFILE" 2>/dev/null) || return 0
  target=${target##*/}
  if [[ "$target" =~ ^system-([0-9]+)-link$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# True when /run/current-system is exactly what the system profile points at,
# i.e. the profile's generation finished activating.
system_is_current() {
  local a b
  a=$(readlink -f "$CURRENT_SYSTEM" 2>/dev/null) || return 1
  b=$(readlink -f "$SYSTEM_PROFILE" 2>/dev/null) || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}

# system_is_out <out> — the profile AND /run/current-system are exactly <out>
# (not merely equal to each other: a manual rebuild finishing in between would
# make them agree on ITS generation).
system_is_out() {
  local want a b
  want=$(readlink -f "$1" 2>/dev/null) || return 1
  a=$(readlink -f "$CURRENT_SYSTEM" 2>/dev/null) || return 1
  b=$(readlink -f "$SYSTEM_PROFILE" 2>/dev/null) || return 1
  [[ -n "$want" && "$a" == "$want" && "$b" == "$want" ]]
}

# Commit the running generation was built from (system.configurationRevision,
# set by mkMac for auto-updated hosts), or empty. Printed with its "-dirty"
# suffix kept: the caller treats a dirty build as its HEAD commit for the
# rewind floor, but never as "built from merged main".
installed_revision() {
  local rev
  rev=$(jq -r '.configurationRevision // ""' "$CURRENT_SYSTEM/darwin-version.json" 2>/dev/null) || return 0
  if [[ "$rev" =~ ^[0-9a-f]{40}(-dirty)?$ ]]; then printf '%s' "$rev"; fi
}

# ── State file ───────────────────────────────────────────────────────────────
# PREV_* carry fields forward between runs; read once, at start. A file that
# is not EXACTLY the contract (the same rules the
# audit collector applies) fails closed: rewinding protection depends on
# applied_commit, and a bad field carried forward would leave the audit
# reporting state-unreadable forever.
#
# Optional keys, absent from a plain nightly run's state:
#   request_id, lane, fast_lane_reason — all three on a requested run's state
#     (lane null when the run ended before choosing a target);
#   applied_lane — "fast" while applied_commit came through the fast lane
#     (carried forward; cleared by the next channel apply).
# FAST_LANE_REASONS is the closed set of fast_lane_reason tokens (choose_lane).
FAST_LANE_REASONS='["not-requested", "channel-is-main", "no-host-file", "same-as-channel",
  "signature-invalid", "not-descendant", "other-files", "not-list-addition",
  "ci-not-green", "ci-unknown"]'
STATE_CONTRACT='
  def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  def reasons: {
    "applied": [null], "no-op": [null],
    "skipped": ["on-battery", "lock-held", "rebuild-in-progress", "channel-behind", "dock-protect"],
    "failed": ["fetch-failed", "build-failed", "activation-failed", "brew-failed", "unknown"],
    "refused": ["signature-invalid", "signer-key-expired", "not-fast-forward", "not-in-main"] };
  def dock_protect: type == "object"
    and ((keys - ["error"]) == ["checked_at", "would_remove"])
    and (if has("error") then .error == "unreadable" else true end)
    and (.checked_at | iso)
    and (.would_remove | type == "array" and length <= 30
         and all(.[]; type == "string" and (startswith("/") or startswith("web link: "))));
  type == "object"
  and ((keys - ["dock_protect", "request_id", "lane", "fast_lane_reason", "applied_lane"])
       == ["applied_commit", "channel", "consecutive_failures", "enabled",
                "generation", "last_result", "last_run_at", "last_success_at", "reason", "schema",
                "target_commit"])
  and .schema == 1 and .enabled == true
  and (.channel | IN("main", "fleet/stable"))
  and (.last_run_at | iso)
  and (.last_result | IN("applied", "no-op", "skipped", "failed", "refused"))
  and (.reason as $r | reasons[.last_result] | index([$r]) != null)
  and (has("dock_protect") == (.reason == "dock-protect"))
  and (if has("dock_protect") then (.dock_protect | dock_protect) else true end)
  and (.target_commit == null or (.target_commit | sha))
  and (.applied_commit == null or (.applied_commit | sha))
  and (.last_success_at == null or (.last_success_at | iso))
  and (.generation == null or (.generation | type == "number" and . >= 0 and floor == .))
  and (.consecutive_failures | type == "number" and . >= 0 and floor == .)
  and (has("request_id") == has("lane") and has("lane") == has("fast_lane_reason"))
  and (if has("request_id") then
         (.request_id | type == "string" and test("^[A-Za-z0-9-]{1,64}$"))
         and (.lane == null or (.lane | IN("fast", "channel")))
         and (.fast_lane_reason == null or (.fast_lane_reason as $f | $flr | index([$f]) != null))
       else true end)
  and (if has("applied_lane") then .applied_lane == "fast" and .applied_commit != null else true end)'
PREV_APPLIED=""
PREV_APPLIED_LANE=""
PREV_SUCCESS=""
PREV_GENERATION=""
PREV_FAILURES=0

read_state() {
  PREV_APPLIED=""; PREV_APPLIED_LANE=""; PREV_SUCCESS=""; PREV_GENERATION=""; PREV_FAILURES=0
  [[ -e "$STATE_FILE" ]] || return 0
  jq -e --argjson flr "$FAST_LANE_REASONS" "$STATE_CONTRACT" "$STATE_FILE" >/dev/null 2>&1 || return 1
  PREV_APPLIED=$(jq -r '.applied_commit // ""' "$STATE_FILE") || return 1
  PREV_APPLIED_LANE=$(jq -r '.applied_lane // ""' "$STATE_FILE") || return 1
  PREV_SUCCESS=$(jq -r '.last_success_at // ""' "$STATE_FILE") || return 1
  PREV_GENERATION=$(jq -r '(.generation // "") | tostring' "$STATE_FILE") || return 1
  PREV_FAILURES=$(jq -r '.consecutive_failures | tostring' "$STATE_FILE") || return 1
}

# write_state <result> <reason|""> <target|""> <applied|""> <success|""> <generation|""> <failures> <applied_lane|"">
# DOCK_PROTECT_JSON, when set (a dock-protect hold), becomes `dock_protect`;
# the key is absent from every other state. A requested run (REQUEST_ID) adds
# request_id / lane / fast_lane_reason; applied_lane is written only as "fast".
write_state() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.state.json.XXXXXX")
  jq -n \
    --arg channel "$CHANNEL" --arg now "$(now_iso)" --arg result "$1" \
    --arg reason "$2" --arg target "$3" --arg applied "$4" --arg success "$5" \
    --arg generation "$6" --argjson failures "$7" --arg alane "$8" --arg dock "$DOCK_PROTECT_JSON" \
    --arg rid "$REQUEST_ID" --arg lane "$LANE" --arg flr "$FAST_LANE_REASON" '
    def nullable: if . == "" then null else . end;
    { schema: 1, enabled: true, channel: $channel,
      last_run_at: $now, last_result: $result, reason: ($reason | nullable),
      target_commit: ($target | nullable), applied_commit: ($applied | nullable),
      last_success_at: ($success | nullable),
      generation: (if $generation == "" then null else ($generation | tonumber) end),
      consecutive_failures: $failures }
    + (if $dock == "" then {} else { dock_protect: ($dock | fromjson) } end)
    + (if $rid == "" then {} else
        { request_id: $rid, lane: ($lane | nullable), fast_lane_reason: ($flr | nullable) } end)
    + (if $alane == "fast" then { applied_lane: "fast" } else {} end)' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# ── Result handling ──────────────────────────────────────────────────────────
TARGET=""
CHANNEL_TIP=""
LANE=""             # requested runs: fast | channel, once the target is chosen
FAST_LANE_REASON="" # requested runs on the channel lane: why not the fast lane
NEW_GENERATION=""   # set once the system profile was switched this run
DOCK_PROTECT_JSON="" # set by check_dock when it holds the update

# finish <result> [reason] — record the outcome and exit. Never returns.
finish() {
  local result="$1" reason="${2:-}" rc applied applied_lane success generation failures
  # dock_protect belongs to a dock-protect hold only (the state contract).
  [[ "$reason" == dock-protect ]] || DOCK_PROTECT_JSON=""
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$result" == applied ]] && result="would-apply"
    log "dry-run result: ${result}${reason:+ ($reason)}${TARGET:+ target=$TARGET}${LANE:+ lane=$LANE} — state not written"
    case "$result" in failed) exit 1 ;; refused) exit 3 ;; *) exit 0 ;; esac
  fi
  # The lock holder is the only writer (a lock-held run never gets here), so
  # the values read at start are current.
  applied="$PREV_APPLIED"; applied_lane="$PREV_APPLIED_LANE"; success="$PREV_SUCCESS"
  generation="$PREV_GENERATION"; failures="$PREV_FAILURES"
  case "$result" in
    applied)
      applied="$TARGET"; success="$(now_iso)"; failures=0
      applied_lane=""; [[ "$LANE" == fast ]] && applied_lane=fast
      generation="$NEW_GENERATION"; rc=0 ;;
    no-op)
      success="$(now_iso)"; failures=0; rc=0 ;;
    skipped)
      rc=0 ;;
    failed)
      failures=$((failures + 1)); rc=1
      # The profile may already point at the new generation (activation or brew
      # failed after `nix-env --set`): record that the generation switched even
      # though applied_commit does not move.
      [[ -n "$NEW_GENERATION" ]] && generation="$NEW_GENERATION" ;;
    refused)
      failures=$((failures + 1)); rc=3 ;;
    *)
      log "internal error: unknown result '$result'"; result=failed; reason=unknown
      failures=$((failures + 1)); rc=1 ;;
  esac
  write_state "$result" "$reason" "$TARGET" "$applied" "$success" "$generation" "$failures" "$applied_lane"
  log "result: ${result}${reason:+ ($reason)}${TARGET:+ target=$TARGET}${applied:+ applied=$applied}${generation:+ generation=$generation}${REQUEST_ID:+ request=$REQUEST_ID lane=${LANE:-none}${FAST_LANE_REASON:+ ($FAST_LANE_REASON)}}"
  exit "$rc"
}

# ── Lock ─────────────────────────────────────────────────────────────────────
# $LOCK_DIR/pid holds "<pid> <epoch-at-acquire>". A lock is live only while
# that pid exists AND it is younger than LOCK_MAX_AGE: every step is bounded by
# a timeout (worst case well under 5 h), so an older lock is stale even if its
# pid was since reused by an unrelated process.
LOCK_MAX_AGE=$((6 * 3600))

release_lock() {
  local owner
  owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ "${owner%% *}" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

write_lock_owner() {
  echo "$$ $(date +%s)" >"$LOCK_DIR/pid"
  trap release_lock EXIT
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    write_lock_owner
    return 0
  fi
  local owner pid started
  owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  read -r pid started <<<"$owner" || true
  # No owner yet = the holder is between mkdir and writing it: treat as held.
  [[ -n "${pid:-}" ]] || return 1
  if kill -0 "$pid" 2>/dev/null && [[ "${started:-}" =~ ^[0-9]+$ ]] \
     && (( $(date +%s) - started < LOCK_MAX_AGE )); then
    return 1
  fi
  # Stale lock. Take it over under a second mkdir mutex and RE-CHECK inside it:
  # two runs that both saw it stale must not both remove-and-recreate (the
  # second would delete the first's fresh lock and both would activate).
  mkdir "$LOCK_DIR.takeover" 2>/dev/null || return 1
  if [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" != "$owner" ]]; then
    rmdir "$LOCK_DIR.takeover"
    return 1
  fi
  log "removing stale lock ($owner)"
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    rmdir "$LOCK_DIR.takeover"
    return 1
  fi
  write_lock_owner
  rmdir "$LOCK_DIR.takeover"
}

# ── Preconditions ────────────────────────────────────────────────────────────
rebuild_in_progress() {
  # A human (or setup.sh) is switching this machine right now; two activations
  # racing on the same profile is exactly what this daemon must never cause.
  pgrep -f 'darwin-rebuild|rebuild\.sh' >/dev/null 2>&1
}

on_ac_power() {
  # Unknown power state counts as battery: a build + activation on a draining
  # laptop at 3 a.m. is the failure we are guarding against.
  local batt
  batt=$(pmset -g batt 2>/dev/null) || return 1
  [[ "$batt" == *"'AC Power'"* ]]
}

# battery_at_least <percent> — the internal battery reports at least that
# charge ("-InternalBattery-0 (id=…)	87%; discharging; …"). Unknown = no.
battery_at_least() {
  local batt pct re=$'InternalBattery[^\n]*[^0-9]([0-9]{1,3})%;'
  batt=$(pmset -g batt 2>/dev/null) || return 1
  [[ "$batt" =~ $re ]] || return 1
  pct=${BASH_REMATCH[1]}
  (( 10#$pct >= $1 ))
}

# ── Checkout ─────────────────────────────────────────────────────────────────
sync_checkout() {
  umask 022   # world-readable, writable by root only
  mkdir -p "$STATE_DIR"
  chmod 0755 "$STATE_DIR"
  if [[ ! -d "$CHECKOUT/.git" ]]; then
    rm -rf "$CHECKOUT"
    log "cloning $REPO_URL into $CHECKOUT"
    run_timeout "$FETCH_TIMEOUT" git clone --quiet --no-checkout "$REPO_URL" "$CHECKOUT" </dev/null || return 1
  fi
  g remote set-url origin "$REPO_URL"
  local specs=("+refs/heads/main:refs/remotes/origin/main")
  if [[ "$CHANNEL" != main ]]; then
    specs+=("+refs/heads/$CHANNEL:refs/remotes/origin/$CHANNEL")
  fi
  run_timeout "$FETCH_TIMEOUT" git -C "$CHECKOUT" fetch --quiet --no-tags origin "${specs[@]}" </dev/null
}

# ── Trust ────────────────────────────────────────────────────────────────────
# verify_signature <commit> — 0 good, 1 invalid, 2 signer key expired.
# The keyring is a throwaway GNUPGHOME holding ONLY the pinned key, so no key
# in root's or anyone's keyring can vouch for a commit; the signing primary
# key's fingerprint is additionally checked against the pinned file's.
verify_signature() {
  local commit="$1" gnupghome="" status rc=0 pinned signers fpr
  # Fail closed: an empty GNUPGHOME would silently fall back to root's keyring.
  gnupghome=$(mktemp -d "${TMPDIR:-/tmp}/rh7fu-gpg.XXXXXX") || gnupghome=""
  if [[ -z "$gnupghome" || ! -d "$gnupghome" ]] || ! chmod 0700 "$gnupghome"; then
    log "could not create an isolated GNUPGHOME — refusing"
    [[ -n "$gnupghome" ]] && rm -rf "$gnupghome"
    return 1
  fi
  if ! GNUPGHOME="$gnupghome" gpg --batch --quiet --no-autostart --import "$SIGNER_KEY" >/dev/null 2>&1; then
    log "could not import the pinned signer key $SIGNER_KEY"
    rm -rf "$gnupghome"
    return 1
  fi
  pinned=$(GNUPGHOME="$gnupghome" gpg --batch --with-colons --list-keys 2>/dev/null \
    | awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0} /^sub:/ {p = 0}') || pinned=""
  status=$(GNUPGHOME="$gnupghome" g -c gpg.format=openpgp -c gpg.program=gpg \
    verify-commit --raw "$commit" 2>&1) || rc=$?
  GNUPGHOME="$gnupghome" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$gnupghome"
  if [[ -z "$pinned" ]]; then
    log "pinned signer key file $SIGNER_KEY holds no usable key — refusing"
    return 1
  fi
  # Decide on gpg's status lines, not on git's exit code alone: git (2.55)
  # exits 0 for a good signature by an EXPIRED key (EXPKEYSIG + VALIDSIG).
  # Accept only GOODSIG + VALIDSIG with no expiry/revocation/bad marker, made
  # by (a subkey of) a pinned primary key — VALIDSIG field 12 is the primary
  # key fingerprint.
  signers=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $12}' <<<"$status")
  if [[ $rc -eq 0 && -n "$signers" ]] \
     && grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status" \
     && ! grep -qE '^\[GNUPG:\] (EXPKEYSIG|KEYEXPIRED|EXPSIG|REVKEYSIG|KEYREVOKED|BADSIG|ERRSIG) ' <<<"$status"; then
    for fpr in $signers; do
      grep -qxF "$fpr" <<<"$pinned" || { log "signer $fpr is not a pinned key"; return 1; }
    done
    return 0
  fi
  printf '%s\n' "$status" | sed 's/^/  verify-commit: /' >&2
  if grep -qE '^\[GNUPG:\] (EXPKEYSIG|KEYEXPIRED) ' <<<"$status" \
     && ! grep -qE '^\[GNUPG:\] (BADSIG|REVKEYSIG|KEYREVOKED) ' <<<"$status"; then
    return 2
  fi
  return 1
}

is_ancestor() { g merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# ── Fast lane (requested runs only) ──────────────────────────────────────────
# A requested run may apply the signed main tip M instead of the channel tip S
# when S..M is a change only this host sees and that cannot do more than
# install software: list entries added to this host's OWN file. Every check
# fails closed to the channel lane; main()'s trust checks (signature, in main,
# no rewind) then run on whichever target was chosen, unchanged.
#
# Line shapes, matched per line of the diff and of M's file:
FL_NOTE_RE=$'^[ \t]*(#.*)?$'                                          # blank / comment
FL_TOKEN_RE=$'^[ \t]*"[A-Za-z0-9][A-Za-z0-9@+._/-]*"[ \t]*(#.*)?$'   # "cask" / "tap/x/formula"
FL_PKGS_RE=$'^[ \t]*pkgs([.][A-Za-z_][A-Za-z0-9_-]*)+[ \t]*(#.*)?$'  # pkgs.name
FL_TOKEN_LIST_RE=$'^[ \t]*(homebrew[.])?(casks|brews)[ \t]*=[ \t]*[[][ \t]*(#.*)?$'
FL_PKGS_LIST_RE=$'^[ \t]*(environment[.]systemPackages|home[.]packages)[ \t]*=[ \t]*[[][ \t]*(#.*)?$'

# github_api <path> — GET from the public GitHub API: unauthenticated, bounded.
github_api() {
  run_timeout "$CI_TIMEOUT" curl -fsS --proto =https --connect-timeout 5 --max-time 20 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: rh7-fleet-update' \
    "$GITHUB_API/$1" </dev/null 2>/dev/null
}

# ci_green <sha> — 0: every check run completed successfully and the combined
# status is success (or has no statuses); 1: red, pending or no CI at all;
# 2: unknown (network, rate limit, malformed or truncated answer). The same
# rule rh-device-management's promote-fleet-stable.sh applies to the channel.
ci_green() {
  local runs status
  runs=$(github_api "repos/$GITHUB_REPO/commits/$1/check-runs?per_page=100") || return 2
  status=$(github_api "repos/$GITHUB_REPO/commits/$1/status") || return 2
  jq -e '(.total_count | type) == "number" and (.check_runs | type) == "array"
         and .total_count == (.check_runs | length)
         and all(.check_runs[]; type == "object" and (.status | type) == "string")' \
    <<<"$runs" >/dev/null 2>&1 || return 2
  jq -e '(.total_count | type) == "number" and (.total_count == 0 or (.state | type) == "string")' \
    <<<"$status" >/dev/null 2>&1 || return 2
  jq -e --argjson s "$status" '
    .total_count > 0
    and all(.check_runs[]; .status == "completed" and (.conclusion | IN("success", "neutral", "skipped")))
    and ($s.total_count == 0 or $s.state == "success")' <<<"$runs" >/dev/null 2>&1 || return 1
}

# fast_lane_change <base> <cand> — 0: base..cand only adds list entries (or
# comments) to FAST_LANE_FILE. Otherwise prints the fast_lane_reason token
# (other-files | not-list-addition) and returns 1. Rules:
#   - the diff is exactly one in-place modification of FAST_LANE_FILE, mode
#     unchanged (no other path, no add/delete/rename/mode change);
#   - removed lines are blank or comments only;
#   - added lines are blank, comments, a quoted cask/formula token or a
#     pkgs.<name> entry;
#   - in cand's file, each added entry sits in a list opened by
#     `[homebrew.]casks|brews = [` (tokens) or `environment.systemPackages |
#     home.packages = [` (pkgs.<name>), with only entries of the same shape,
#     comments or blank lines between the opener and it — so "reboot" added to
#     ProgramArguments, or any other list, is not eligible;
#   - the file has no indented string ('') at all: a line inside one is shell
#     or text, not a list entry, and is not worth parsing Nix to tell apart.
fast_lane_change() {
  local base="$1" cand="$2" raw re diff content line n=0 hunk=0 i e k s
  local -a lines=() entries=() kinds=()
  raw=$(g diff --raw --no-abbrev --no-renames "$base" "$cand") || { echo other-files; return 1; }
  re=$'^:100644 100644 [0-9a-f]+ [0-9a-f]+ M\t(.+)$'
  if [[ "$raw" == *$'\n'* || ! "$raw" =~ $re || "${BASH_REMATCH[1]}" != "$FAST_LANE_FILE" ]]; then
    log "fast lane: $base..$cand is not just an edit of $FAST_LANE_FILE: $(printf '%s\n' "$raw" | cut -f2 | paste -sd ' ' -)"
    echo other-files; return 1
  fi
  content=$(g show "$cand:$FAST_LANE_FILE") || { echo not-list-addition; return 1; }
  if [[ "$content" == *"''"* ]]; then
    log "fast lane: $FAST_LANE_FILE contains an indented string ('') — not eligible"
    echo not-list-addition; return 1
  fi
  diff=$(g diff -U0 --no-color --no-ext-diff --no-textconv --no-renames "$base" "$cand" -- "$FAST_LANE_FILE") \
    || { echo not-list-addition; return 1; }
  re='^@@ -[0-9]+(,[0-9]+)? [+]([0-9]+)(,[0-9]+)? @@'
  while IFS= read -r line; do
    if [[ $hunk -eq 0 && "$line" != '@@ '* ]]; then continue; fi   # file header
    case "$line" in
      '@@ '*)
        hunk=1
        [[ "$line" =~ $re ]] || { log "fast lane: unparseable hunk header: $line"; echo not-list-addition; return 1; }
        n=${BASH_REMATCH[2]} ;;
      '\'*) ;;   # "\ No newline at end of file"
      -*)
        [[ "${line:1}" =~ $FL_NOTE_RE ]] \
          || { log "fast lane: removes or changes a line that is not a comment: ${line:1}"; echo not-list-addition; return 1; } ;;
      +*)
        s=${line:1}
        if [[ "$s" =~ $FL_TOKEN_RE ]]; then entries+=("$n"); kinds+=(token)
        elif [[ "$s" =~ $FL_PKGS_RE ]]; then entries+=("$n"); kinds+=(pkgs)
        elif ! [[ "$s" =~ $FL_NOTE_RE ]]; then
          log "fast lane: adds a line that is not a list entry or comment: $s"; echo not-list-addition; return 1
        fi
        n=$((n + 1)) ;;
      *) log "fast lane: unexpected diff line: $line"; echo not-list-addition; return 1 ;;
    esac
  done <<<"$diff"
  while IFS= read -r line; do lines+=("$line"); done <<<"$content"
  for i in "${!entries[@]}"; do
    e=${entries[$i]}; k=${kinds[$i]}
    # The added line itself, in cand's file (guards the hunk arithmetic).
    s=${lines[$((e - 1))]:-}
    if [[ $k == token ]]; then [[ "$s" =~ $FL_TOKEN_RE ]]; else [[ "$s" =~ $FL_PKGS_RE ]]; fi \
      || { log "fast lane: line $e of $FAST_LANE_FILE is not the added entry"; echo not-list-addition; return 1; }
    # Walk up over same-shape entries, comments and blank lines to the opener.
    for ((e = e - 1; e >= 1; e--)); do
      s=${lines[$((e - 1))]}
      [[ "$s" =~ $FL_NOTE_RE ]] && continue
      [[ $k == token && "$s" =~ $FL_TOKEN_RE ]] && continue
      [[ $k == pkgs && "$s" =~ $FL_PKGS_RE ]] && continue
      break
    done
    if [[ $e -lt 1 ]] || { [[ $k == token ]] && ! [[ "$s" =~ $FL_TOKEN_LIST_RE ]]; } \
       || { [[ $k == pkgs ]] && ! [[ "$s" =~ $FL_PKGS_LIST_RE ]]; }; then
      log "fast lane: $k entry on line ${entries[$i]} of $FAST_LANE_FILE is not in a casks/brews (token) or package (pkgs) list (opened by: ${s:-nothing})"
      echo not-list-addition; return 1
    fi
  done
  log "fast lane: $base..$cand only adds ${#entries[@]} list entr$([[ ${#entries[@]} -eq 1 ]] && echo y || echo ies) (or comments) to $FAST_LANE_FILE"
}

# choose_lane — requested runs: sets LANE and FAST_LANE_REASON, and TARGET to
# the main tip on the fast lane (else it stays the channel tip).
choose_lane() {
  local cand why crc=0
  LANE=channel
  if [[ $FAST_LANE -eq 0 ]]; then FAST_LANE_REASON=not-requested; return 0; fi
  if [[ "$CHANNEL" == main ]]; then
    FAST_LANE_REASON=channel-is-main; log "fast lane: this host follows main already"; return 0
  fi
  if [[ -z "$FAST_LANE_FILE" ]]; then
    FAST_LANE_REASON=no-host-file; log "fast lane: this host has no host file of its own — channel only"; return 0
  fi
  if ! cand=$(g rev-parse --verify --quiet "refs/remotes/origin/main^{commit}"); then
    FAST_LANE_REASON=not-descendant; log "fast lane: origin/main does not resolve"; return 0
  fi
  if [[ "$cand" == "$CHANNEL_TIP" ]]; then
    FAST_LANE_REASON=same-as-channel; log "fast lane: main is the channel tip — nothing extra to apply"; return 0
  fi
  if ! verify_signature "$cand"; then
    FAST_LANE_REASON=signature-invalid; log "fast lane: main tip $cand is not signed by the pinned key"; return 0
  fi
  if ! is_ancestor "$CHANNEL_TIP" "$cand"; then
    FAST_LANE_REASON=not-descendant; log "fast lane: main tip $cand does not descend from the channel tip"; return 0
  fi
  if ! why=$(fast_lane_change "$CHANNEL_TIP" "$cand"); then
    FAST_LANE_REASON=${why:-not-list-addition}; return 0
  fi
  ci_green "$cand" || crc=$?
  case $crc in
    0) ;;
    1) FAST_LANE_REASON=ci-not-green; log "fast lane: CI is not green on $cand"; return 0 ;;
    *) FAST_LANE_REASON=ci-unknown; log "fast lane: CI state of $cand unknown (GitHub API unreachable or unexpected)"; return 0 ;;
  esac
  LANE=fast; FAST_LANE_REASON=""; TARGET="$cand"
  log "fast lane: applying main tip $cand (channel $CHANNEL stays at $CHANNEL_TIP)"
}

# ── Dock protection ──────────────────────────────────────────────────────────
# nix-darwin's system.defaults.dock.persistent-apps (left side) and
# persistent-others (right side: folders, stacks, files) each REPLACE that part
# of the primary user's Dock on activation, so anything she added by hand
# silently disappears. Unattended, that is never acceptable: a run that would
# remove anything is held (skipped / dock-protect) until a human either
# declares the item or confirms the removal through rebuild.sh (which shows
# the drift and asks).
DOCK_MAX_REPORTED=30

# dock_path <_CFURLString> — one Dock entry as a POSIX path: file:// (or
# file://localhost) stripped, percent-decoded, trailing slashes dropped, so
# the Dock's "file:///Applications/Google%20Chrome.app/" equals nix-darwin's
# "/Applications/Google Chrome.app".
dock_path() {
  local s="$1"
  s=${s#file://localhost}
  s=${s#file://}
  if [[ "$s" == *%* ]]; then
    s=${s//\\/\\\\}               # a literal backslash must survive %b
    s=$(printf '%b' "${s//%/\\x}")
  fi
  while [[ "$s" == */ && "$s" != / ]]; do s=${s%/}; done
  printf '%s\n' "$s"
}

# target_declaration — what the checked-out commit declares that this run
# checks before building, as {"user", "apps": [...] | null, "others": [...] |
# null, "brew": {"enable", "user", "prefix", "casks": [names]}}: the primary
# user and Dock (check_dock), and who runs Homebrew and which casks
# (check_brew_target). Evaluated once per run, not built.
target_declaration() {
  run_timeout "$EVAL_TIMEOUT" nix --extra-experimental-features 'nix-command flakes' \
    --option accept-flake-config false \
    eval --json --no-update-lock-file \
    "$CHECKOUT#darwinConfigurations.\"$FLAKE_ATTR\".config" \
    --apply 'c: { user = c.system.primaryUser; apps = c.system.defaults.dock.persistent-apps; others = c.system.defaults.dock.persistent-others; brew = { enable = c.homebrew.enable; user = c.homebrew.user; prefix = c.homebrew.prefix; casks = map (k: k.name) c.homebrew.casks; }; }' </dev/null
}

# load_target_declaration — TARGET_DECL, evaluated on first use.
TARGET_DECL=""
load_target_declaration() {
  [[ -z "$TARGET_DECL" ]] || return 0
  TARGET_DECL=$(target_declaration) || { TARGET_DECL=""; log "could not evaluate the declaration of $TARGET"; return 1; }
}

# current_dock <user> <persistent-apps|persistent-others> — that side of the
# user's current Dock, one entry per line: file/folder tiles as paths, web
# links as "web link: <host>". Read from the plist FILE (read-only; root needs
# no GUI session or cfprefsd). An entry that is none of those nor a spacer
# makes the Dock unreadable. A missing persistent-others key is an empty
# right side; a missing persistent-apps key is unreadable.
current_dock() {
  local plist="$ROOT/Users/$1/Library/Preferences/com.apple.dock.plist" key="$2" n i url type host
  [[ -f "$plist" && -r "$plist" ]] || return 1
  if ! n=$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null); then
    [[ "$key" == persistent-others ]] && plutil -extract persistent-apps raw -o - "$plist" >/dev/null 2>&1 \
      && return 0
    return 1
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i < n; i++)); do
    if url=$(plutil -extract "$key.$i.tile-data.file-data._CFURLString" raw -o - "$plist" 2>/dev/null); then
      dock_path "$url"
      continue
    fi
    type=$(plutil -extract "$key.$i.tile-type" raw -o - "$plist" 2>/dev/null) || return 1
    case "$type" in
      *spacer*) ;;
      url-tile)
        # A web link; nix-darwin cannot declare one. Report its host only.
        url=$(plutil -extract "$key.$i.tile-data.url._CFURLString" raw -o - "$plist" 2>/dev/null) || return 1
        host=${url#*://}; host=${host%%[/?#]*}; host=${host##*@}
        [[ "$host" =~ ^[A-Za-z0-9.:-]{1,253}$ ]] || host="?"
        printf 'web link: %s\n' "$host" ;;
      *) return 1 ;;
    esac
  done
}

# declared_dock <apps|others> — the declared paths of that side (spacers carry
# no URL; entries are nix-darwin tiles, or plain paths).
declared_dock() {
  local raw
  raw=$(jq -r --arg k "$1" '.[$k][] | if type == "string" then .
    else (.["tile-data"]?["file-data"]?["_CFURLString"]? // empty) end' <<<"$TARGET_DECL") || return 1
  while IFS= read -r p; do [[ -z "$p" ]] || dock_path "$p"; done <<<"$raw"
}

# check_dock — 0: activation removes nothing from the primary user's Dock
# (unmanaged, or additions/reorders only). 1: hold; DOCK_PROTECT_JSON is set.
# 2: the declaration could not be evaluated. Run twice: before the build and
# again right before activation (she may add an item during an hours-long
# build); the declaration is evaluated once, the Dock re-read each time.
check_dock() {
  local user side key declared current removals="" managed=0
  load_target_declaration || return 2
  jq -e 'type == "object" and has("apps") and has("others")
         and all(.apps, .others; . == null or type == "array")' \
    <<<"$TARGET_DECL" >/dev/null 2>&1 || { log "unexpected Dock declaration: $TARGET_DECL"; TARGET_DECL=""; return 2; }
  user=$(jq -r '.user // ""' <<<"$TARGET_DECL")
  for side in apps others; do
    # null = that side of the Dock is unmanaged: activation leaves it alone.
    jq -e --arg k "$side" '.[$k] == null' <<<"$TARGET_DECL" >/dev/null && continue
    managed=1
    key="persistent-$side"
    declared=$(declared_dock "$side") || return 2
    if [[ ! "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || ! current=$(current_dock "$user" "$key"); then
      log "dock-protect: cannot read ${user:-the primary user}'s Dock ($key in $ROOT/Users/${user:-?}/Library/Preferences/com.apple.dock.plist) — holding (fail safe)"
      DOCK_PROTECT_JSON=$(jq -cn --arg now "$(now_iso)" \
        '{would_remove: [], error: "unreadable", checked_at: $now}')
      return 1
    fi
    # current − declared, in Dock order, each entry once.
    removals+=$(awk 'NR == FNR { d[$0]; next } $0 != "" && !($0 in d) && !s[$0]++' \
      <(printf '%s\n' "$declared") <(printf '%s\n' "$current"))$'\n'
  done
  if [[ $managed -eq 0 ]]; then
    log "dock: persistent-apps and persistent-others unset in $TARGET — Dock unmanaged, nothing to protect"
    return 0
  fi
  removals=$(grep -v '^$' <<<"$removals" || true)
  if [[ -z "$removals" ]]; then
    log "dock: $TARGET removes nothing from $user's Dock"
    return 0
  fi
  log "dock-protect: activating $TARGET would remove from $user's Dock: $(paste -sd ',' - <<<"$removals" | sed 's/,/, /g')"
  DOCK_PROTECT_JSON=$(jq -cRn --arg now "$(now_iso)" --argjson max "$DOCK_MAX_REPORTED" \
    '{would_remove: ([inputs | select(length > 0)] | .[:$max]), checked_at: $now}' <<<"$removals")
  return 1
}

# brew_user_writes_applications <user> — root asks: can <user> create a bundle
# in /Applications? (A standard account cannot; an admin can.)
brew_user_writes_applications() {
  sudo -n -u "$1" test -w "$ROOT/Applications" </dev/null >/dev/null 2>&1
}

# brew_prefix_foreign <user> <prefix> — the first of Homebrew's own top-level
# directories (the prefix itself on Apple Silicon — it is the Homebrew
# repository — or <prefix>/Homebrew on Intel, plus Caskroom, Cellar and
# var/homebrew) not owned by <user>, or the reason it cannot tell; nothing
# when they are theirs. Only those directories themselves, not the tree: a
# prefix still owned by the PREVIOUS homebrew.user shows there, while
# root-owned files deeper down (e.g. a `sudo brew services` formula's logs)
# are legitimate and must not hold every update.
brew_prefix_foreign() {
  local uid d dirs=()
  uid=$(id -u "$1" 2>/dev/null) || { echo "(no such user: $1)"; return 0; }
  if [[ "$2" == */usr/local ]]; then dirs+=("$2/Homebrew"); else dirs+=("$2"); fi
  dirs+=("$2/Caskroom" "$2/Cellar" "$2/var/homebrew")
  for d in "${dirs[@]}"; do
    [[ -e "$d" ]] || continue
    if [[ -z "$(find "$d" -maxdepth 0 -uid "$uid" 2>/dev/null)" ]]; then
      printf '%s' "$d"; return 0
    fi
  done
}

# check_brew_target — 0: activation's `brew bundle` can run as the target's
# homebrew.user without a password. 1: it cannot, either because
#   - a cask new to this Mac's Caskroom would be installed and that user
#     cannot write /Applications: Homebrew moves a new cask's app there as
#     homebrew.user and otherwise falls back to its own `sudo cp` as that
#     user — a password prompt no unattended run can answer; or
#   - the prefix is not (wholly) that user's: a commit that changes
#     homebrew.user reaches the Mac before anybody migrated the prefix (only
#     rebuild.sh offers that chown), and brew run as the new user fails on it.
# Both would fail activation after the system profile already switched.
# 2: unknown. Sets BREW_USER (close_user_sudo_window) from the target, which
# decides who `brew bundle` runs as.
BREW_USER=""
check_brew_target() {
  local user prefix new="" cask foreign
  load_target_declaration || return 2
  jq -e '.brew | type == "object" and (.enable | type == "boolean")
         and (.user | type == "string") and (.prefix | type == "string")
         and (.casks | type == "array" and all(.[]; type == "string"))' \
    <<<"$TARGET_DECL" >/dev/null 2>&1 || { log "unexpected Homebrew declaration: $TARGET_DECL"; TARGET_DECL=""; return 2; }
  if [[ "$(jq -r '.brew.enable' <<<"$TARGET_DECL")" != true ]]; then
    log "brew: homebrew.enable = false in $TARGET — no casks installed"
    return 0
  fi
  user=$(jq -r '.brew.user' <<<"$TARGET_DECL")
  prefix=$(jq -r '.brew.prefix' <<<"$TARGET_DECL")
  [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ && "$prefix" == /* ]] \
    || { log "unexpected homebrew.user / homebrew.prefix in $TARGET: '$user' / '$prefix'"; return 2; }
  BREW_USER="$user"
  # A cask is installed when its token (the last part of a tap-qualified
  # name) has a Caskroom directory. Read as root; no Homebrew command runs.
  while IFS= read -r cask; do
    [[ -n "$cask" ]] || continue
    [[ -d "$ROOT$prefix/Caskroom/${cask##*/}" ]] || new+=" ${cask##*/}"
  done < <(jq -r '.brew.casks[]' <<<"$TARGET_DECL")
  new="${new# }"
  if [[ -n "$new" ]] && ! brew_user_writes_applications "$user"; then
    log "brew-user: $TARGET would install $new as homebrew.user '$user', who cannot write /Applications (not an admin) — Homebrew would fall back to its own sudo as $user, which an unattended run cannot answer. Not building. Fix: set homebrew.user to an admin account (or make $user an admin); or install them with rebuild.sh."
    return 1
  fi
  if [[ -d "$ROOT$prefix" ]]; then
    foreign=$(brew_prefix_foreign "$user" "$ROOT$prefix")
    if [[ -n "$foreign" ]]; then
      log "brew-user: $TARGET runs Homebrew as homebrew.user '$user', but $foreign is not $user's (the prefix was not migrated) — brew would fail on it mid-activation. Not building. Fix: run rebuild.sh from an admin account; it offers the chown to $user."
      return 1
    fi
  fi
  if [[ -z "$new" ]]; then
    log "brew: $TARGET installs no new cask (homebrew.user $user)"
  else
    log "brew: $TARGET installs $new as homebrew.user $user (can write /Applications)"
  fi
  return 0
}

# ── Build + activate ─────────────────────────────────────────────────────────
build_system() {
  local out
  # --no-update-lock-file: a commit whose flake.lock is missing or stale must
  # FAIL, not resolve fresh input revisions the signature never covered.
  out=$(run_timeout "$BUILD_TIMEOUT" nix --extra-experimental-features 'nix-command flakes' \
      --option accept-flake-config false \
      build --no-update-lock-file --out-link "$BUILD_LINK" --print-out-paths \
      "$CHECKOUT#darwinConfigurations.\"$FLAKE_ATTR\".system" </dev/null) || return 1
  out=$(printf '%s\n' "$out" | tail -n 1)
  [[ -n "$out" && -x "$out/activate" ]] || { log "build produced no activatable system ($out)"; return 1; }
  printf '%s' "$out"
}

# Close the brew user's (and the primary user's) sudo window before
# activation. nix-darwin runs `brew bundle` as homebrew.user and mas_install
# as the primary user, and modules/darwin/sudo-rebuild.nix makes the brew
# user's sudo timestamp user-global: a cask installer could otherwise silently
# reuse a window a human opened minutes earlier. With them closed (and no
# tty), every sudo that brew or mas attempts fails fast instead of escalating
# or prompting.
close_user_sudo_window() {
  local u seen=" "
  for u in "$BREW_USER" "$PRIMARY_USER"; do
    [[ -n "$u" && "$seen" != *" $u "* ]] || continue
    seen+="$u "
    sudo -n -u "$u" -- sudo -K </dev/null >/dev/null 2>&1 \
      || log "warning: could not invalidate $u's sudo timestamp"
  done
}

# activate <out> — sets the profile, runs activation; reason on stdout on failure.
activate_system() {
  local out="$1" act_log rc=0
  if ! run_timeout 300 nix-env -p "$SYSTEM_PROFILE" --set "$out" </dev/null >&2; then
    echo activation-failed; return 1
  fi
  log "system profile switched to generation $(current_generation) ($out); activating"
  act_log=$(mktemp "${TMPDIR:-/tmp}/rh7fu-activate.XXXXXX")
  run_timeout "$ACTIVATE_TIMEOUT" "$out/activate" </dev/null >"$act_log" 2>&1 || rc=$?
  sed 's/^/  activate: /' "$act_log" >&2
  if [[ $rc -ne 0 ]]; then
    # nix-darwin prints "Homebrew bundle..." before `brew bundle` and Homebrew
    # prints "`brew bundle` complete!" on success. Marker seen without the
    # completion line = activation died inside (or was timed out in) the brew
    # step. Activation runs under `set -e`, so postActivation (mas_install,
    # home-manager) and the /run/current-system flip did NOT happen.
    if grep -q '^Homebrew bundle\.\.\.' "$act_log" && ! grep -qiE 'bundle`? complete!' "$act_log"; then
      echo brew-failed
    else
      echo activation-failed
    fi
    rm -f "$act_log"
    return 1
  fi
  rm -f "$act_log"
  if ! system_is_out "$out"; then
    log "activation exited 0 but the profile / $CURRENT_SYSTEM are not $out"
    echo activation-failed; return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel)      CHANNEL="${2:-}"; shift 2 ;;
      --flake-attr)   FLAKE_ATTR="${2:-}"; shift 2 ;;
      --signer-key)   SIGNER_KEY="${2:-}"; shift 2 ;;
      --primary-user) PRIMARY_USER="${2:-}"; shift 2 ;;
      --scheduled)    SCHEDULED=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --force-check)  FORCE_CHECK=1; shift ;;
      --requested)    REQUEST_ID="${2:-}"; shift 2 ;;
      --fast-lane)    FAST_LANE=1; shift ;;
      --fast-lane-file) FAST_LANE_FILE="${2:-}"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
  done
  case "$CHANNEL" in
    main|fleet/stable) ;;
    *) echo "--channel must be 'main' or 'fleet/stable' (got '$CHANNEL')" >&2; exit 64 ;;
  esac
  [[ -n "$FLAKE_ATTR" ]] || { echo "--flake-attr is required" >&2; exit 64; }
  [[ -r "$SIGNER_KEY" ]] || { echo "--signer-key must be a readable key file" >&2; exit 64; }
  if [[ -n "$REQUEST_ID" && ! "$REQUEST_ID" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
    echo "--requested needs a request id ([A-Za-z0-9-], at most 64)" >&2; exit 64
  fi
  if [[ $FAST_LANE -eq 1 && -z "$REQUEST_ID" ]]; then
    echo "--fast-lane only applies to a --requested run" >&2; exit 64
  fi
  if [[ -n "$REQUEST_ID" && $SCHEDULED -eq 1 ]]; then
    echo "--requested and --scheduled are different entry points" >&2; exit 64
  fi
  if [[ -n "$FAST_LANE_FILE" && ! "$FAST_LANE_FILE" =~ ^configurations/macos/[A-Za-z0-9._-]+\.nix$ ]]; then
    echo "--fast-lane-file must be configurations/macos/<file>.nix (got '$FAST_LANE_FILE')" >&2; exit 64
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  if [[ -f "$LOG_FILE" ]] && [[ $(wc -c <"$LOG_FILE") -gt $LOG_MAX_BYTES ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
  if [[ $SCHEDULED -eq 1 ]]; then
    exec >>"$LOG_FILE" 2>&1
  else
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

main() {
  parse_args "$@"
  if [[ -z "$ROOT" && $(id -u) -ne 0 ]]; then
    echo "rh7-fleet-update must run as root (it is the org.rh7.fleet-update LaunchDaemon)" >&2
    exit 77
  fi
  setup_logging
  log "start channel=$CHANNEL attr=$FLAKE_ATTR dry_run=$DRY_RUN force_check=$FORCE_CHECK scheduled=$SCHEDULED${REQUEST_ID:+ requested=$REQUEST_ID fast_lane=$FAST_LANE}"

  # Jitter first, then the lock, THEN the state read: values read before
  # holding the lock could be stale by the time this run writes.
  if [[ $SCHEDULED -eq 1 && $FORCE_CHECK -eq 0 && $DRY_RUN -eq 0 ]]; then
    local delay=$((RANDOM % JITTER_MAX))
    log "scheduled run: sleeping ${delay}s"
    sleep "$delay"
  fi

  if ! acquire_lock; then
    # Logged only, NOT recorded: the holder owns state.json for its whole run.
    # A read-modify-write from here could land after the holder's final write
    # and resurrect a stale applied_commit, weakening the rewind guard.
    log "skipped (lock-held): another fleet-update run holds $LOCK_DIR — state not written"
    exit 0
  fi

  if ! read_state; then
    # Not overwritten on purpose: the audit then reports state-unreadable, and
    # the rewind guard is never silently reset by a blank applied_commit.
    log "state file $STATE_FILE does not match the contract — refusing to run; inspect and remove it"
    exit 1
  fi

  if rebuild_in_progress; then finish skipped rebuild-in-progress; fi
  if [[ $FORCE_CHECK -eq 0 ]] && ! on_ac_power; then
    # The owner asked for this run and is waiting for it: half a charge covers
    # a build + activation. The nightly run still never runs on battery.
    if [[ -n "$REQUEST_ID" ]] && battery_at_least "$REQUEST_MIN_BATTERY"; then
      log "requested run on battery power with at least ${REQUEST_MIN_BATTERY}% charge — proceeding"
    else
      finish skipped on-battery
    fi
  fi

  sync_checkout || finish failed fetch-failed
  CHANNEL_TIP=$(g rev-parse --verify --quiet "refs/remotes/origin/$CHANNEL^{commit}") \
    || finish failed fetch-failed
  TARGET="$CHANNEL_TIP"
  log "channel $CHANNEL tip: $TARGET"

  # The channel tip is verified even when a requested run then takes the fast
  # lane: a bad channel is refused, never routed around.
  local vrc=0
  verify_signature "$TARGET" || vrc=$?
  case $vrc in
    0) ;;
    2) finish refused signer-key-expired ;;
    *) finish refused signature-invalid ;;
  esac
  if [[ -n "$REQUEST_ID" ]]; then
    choose_lane
    log "requested run: lane $LANE${FAST_LANE_REASON:+ ($FAST_LANE_REASON)}, target $TARGET"
  fi
  is_ancestor "$TARGET" refs/remotes/origin/main || finish refused not-in-main
  # No rewinds. T must descend from the last commit this daemon applied: a tip
  # below it means the signed channel itself went backwards -> refused —
  # unless that commit came through the fast lane (applied_lane), is in main,
  # and T is behind it: the channel has simply not caught up with what a
  # requested run applied -> skipped / channel-behind until it does.
  if [[ -n "$PREV_APPLIED" ]] && ! is_ancestor "$PREV_APPLIED" "$TARGET"; then
    if [[ "$PREV_APPLIED_LANE" == fast ]] && is_ancestor "$TARGET" "$PREV_APPLIED" \
       && is_ancestor "$PREV_APPLIED" refs/remotes/origin/main; then
      log "applied commit $PREV_APPLIED came through the fast lane (in main, ahead of $TARGET) — waiting for the channel to catch up"
      finish skipped channel-behind
    fi
    log "channel tip $TARGET does not descend from the applied commit $PREV_APPLIED"
    finish refused not-fast-forward
  fi
  # Nor may it roll back the commit the running generation was built from (R).
  # This floor covers a host's first run (no state yet: a lagging channel must
  # not roll it back, possibly to before this daemon existed) and a manual
  # rebuild.sh. A clean R that is in origin/main with T behind it means a human
  # rebuilt from NEWER merged main: nothing to apply until the channel catches
  # up -> skipped / channel-behind, not a trust failure. An R the checkout does
  # not know or main does not contain (an unmerged/local build), a -dirty R,
  # or a T that diverged from R refuses until the channel contains R.
  local installed rev
  installed=$(installed_revision)
  rev=${installed%-dirty}
  if [[ -n "$rev" ]] && ! is_ancestor "$rev" "$TARGET"; then
    if [[ "$installed" == "$rev" ]] && is_ancestor "$TARGET" "$rev" \
       && is_ancestor "$rev" refs/remotes/origin/main; then
      log "running generation was built from $rev (in main, ahead of channel tip $TARGET) — waiting for the channel to catch up"
      finish skipped channel-behind
    fi
    log "channel tip $TARGET does not descend from the running revision $installed (not in main, -dirty, or diverged)"
    finish refused not-fast-forward
  fi
  [[ -n "$PREV_APPLIED$rev" ]] || log "warning: no applied commit and no configurationRevision in $CURRENT_SYSTEM — no rewind floor for this run"

  if [[ "$TARGET" == "$PREV_APPLIED" && -n "$PREV_GENERATION" \
        && "$(current_generation)" == "$PREV_GENERATION" ]] && system_is_current; then
    finish no-op
  fi

  # The checkout and the Dock check run in a dry-run too: evaluating is
  # read-only, and "would this be held" is exactly what a dry-run is asked.
  g checkout --quiet --force --detach "$TARGET" || finish failed unknown
  g clean -ffdxq || finish failed unknown
  [[ "$(g rev-parse HEAD)" == "$TARGET" && -z "$(g status --porcelain)" ]] \
    || { log "checkout is not a clean $TARGET"; finish failed unknown; }

  local drc=0
  check_dock || drc=$?
  case $drc in
    0) ;;
    1) finish skipped dock-protect ;;
    *) finish failed build-failed ;;
  esac
  # Who runs `brew bundle`, and can it install the new casks without a
  # password? Checked before building: the answer only depends on the
  # declaration and this Mac, and a run that can only fail at the Homebrew
  # step must not switch the system profile first.
  drc=0
  check_brew_target || drc=$?
  case $drc in
    0) ;;
    1) finish failed brew-failed ;;
    *) finish failed build-failed ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    log "would build darwinConfigurations.\"$FLAKE_ATTR\".system at $TARGET and activate it"
    finish applied
  fi

  local out
  log "building darwinConfigurations.\"$FLAKE_ATTR\".system"
  out=$(build_system) || finish failed build-failed
  log "built $out"

  # Re-check right before touching the system profile: a manual rebuild may
  # have started, or the user pinned an app, during the (possibly hours-long)
  # build. This narrows the race to the activation itself; closing it fully
  # needs rebuild.sh to honour $LOCK_DIR (follow-up — rebuild.sh is outside
  # this change).
  if rebuild_in_progress; then finish skipped rebuild-in-progress; fi
  drc=0
  check_dock || drc=$?
  case $drc in
    0) ;;
    1) finish skipped dock-protect ;;
    *) finish failed build-failed ;;
  esac
  close_user_sudo_window
  local reason gen_before
  gen_before=$(current_generation)
  # activate_system runs in a subshell (its stdout is the failure reason), so
  # whether the profile switched is read back from the profile itself.
  reason=$(activate_system "$out") || {
    if [[ "$(current_generation)" != "$gen_before" ]]; then
      NEW_GENERATION=$(current_generation)
      log "nix generation $NEW_GENERATION is the system profile but did not finish activating"
    fi
    finish failed "${reason:-activation-failed}"
  }
  NEW_GENERATION=$(current_generation)
  finish applied
}

main "$@"
