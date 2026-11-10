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
#   4. no-op          T already applied and the system is still that generation
#   5. build          darwinConfigurations.<attr>.system, <attr> baked in by
#                     the module, never derived from the runtime hostname
#                                                    -> failed / build-failed
#   6. activate       set the system profile, run <out>/activate, stdin closed
#                                                    -> failed / activation-failed
#                                                       (brew-failed)
#   7. state          /var/lib/rh7-fleet-update/state.json, atomic (contract:
#                     rh7/rh-device-management, audit key `fleet_update`)
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
JITTER_MAX=1800

CHANNEL=""
FLAKE_ATTR=""
SIGNER_KEY=""
PRIMARY_USER=""
SCHEDULED=0
DRY_RUN=0
FORCE_CHECK=0

usage() {
  cat <<'EOF'
Usage: rh7-fleet-update [--dry-run] [--force-check]
  (the module wrapper supplies --channel/--flake-attr/--signer-key/--primary-user)

  --dry-run      run every precondition and trust check, report what would be
                 applied; never builds, activates or writes the state file
  --force-check  run now even on battery power (no jitter). Never relaxes any
                 trust check.
  --scheduled    launchd entry point: random start delay of up to 30 minutes
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

# ── State file ───────────────────────────────────────────────────────────────
# PREV_* carry fields forward between runs; read once, at start. A file that
# is not EXACTLY the contract (the same rules the
# audit collector applies) fails closed: rewinding protection depends on
# applied_commit, and a bad field carried forward would leave the audit
# reporting state-unreadable forever.
STATE_CONTRACT='
  def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  def reasons: {
    "applied": [null], "no-op": [null],
    "skipped": ["on-battery", "lock-held", "rebuild-in-progress"],
    "failed": ["fetch-failed", "build-failed", "activation-failed", "brew-failed", "unknown"],
    "refused": ["signature-invalid", "signer-key-expired", "not-fast-forward", "not-in-main"] };
  type == "object"
  and (keys == ["applied_commit", "channel", "consecutive_failures", "enabled", "generation",
                "last_result", "last_run_at", "last_success_at", "reason", "schema",
                "target_commit"])
  and .schema == 1 and .enabled == true
  and (.channel | IN("main", "fleet/stable"))
  and (.last_run_at | iso)
  and (.last_result | IN("applied", "no-op", "skipped", "failed", "refused"))
  and (.reason as $r | reasons[.last_result] | index([$r]) != null)
  and (.target_commit == null or (.target_commit | sha))
  and (.applied_commit == null or (.applied_commit | sha))
  and (.last_success_at == null or (.last_success_at | iso))
  and (.generation == null or (.generation | type == "number" and . >= 0 and floor == .))
  and (.consecutive_failures | type == "number" and . >= 0 and floor == .)'
PREV_APPLIED=""
PREV_SUCCESS=""
PREV_GENERATION=""
PREV_FAILURES=0

read_state() {
  PREV_APPLIED=""; PREV_SUCCESS=""; PREV_GENERATION=""; PREV_FAILURES=0
  [[ -e "$STATE_FILE" ]] || return 0
  jq -e "$STATE_CONTRACT" "$STATE_FILE" >/dev/null 2>&1 || return 1
  PREV_APPLIED=$(jq -r '.applied_commit // ""' "$STATE_FILE") || return 1
  PREV_SUCCESS=$(jq -r '.last_success_at // ""' "$STATE_FILE") || return 1
  PREV_GENERATION=$(jq -r '(.generation // "") | tostring' "$STATE_FILE") || return 1
  PREV_FAILURES=$(jq -r '.consecutive_failures | tostring' "$STATE_FILE") || return 1
}

# write_state <result> <reason|""> <target|""> <applied|""> <success|""> <generation|""> <failures>
write_state() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.state.json.XXXXXX")
  jq -n \
    --arg channel "$CHANNEL" --arg now "$(now_iso)" --arg result "$1" \
    --arg reason "$2" --arg target "$3" --arg applied "$4" --arg success "$5" \
    --arg generation "$6" --argjson failures "$7" '
    def nullable: if . == "" then null else . end;
    { schema: 1, enabled: true, channel: $channel,
      last_run_at: $now, last_result: $result, reason: ($reason | nullable),
      target_commit: ($target | nullable), applied_commit: ($applied | nullable),
      last_success_at: ($success | nullable),
      generation: (if $generation == "" then null else ($generation | tonumber) end),
      consecutive_failures: $failures }' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# ── Result handling ──────────────────────────────────────────────────────────
TARGET=""
NEW_GENERATION=""   # set once the system profile was switched this run

# finish <result> [reason] — record the outcome and exit. Never returns.
finish() {
  local result="$1" reason="${2:-}" rc applied success generation failures
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$result" == applied ]] && result="would-apply"
    log "dry-run result: ${result}${reason:+ ($reason)}${TARGET:+ target=$TARGET} — state not written"
    case "$result" in failed) exit 1 ;; refused) exit 3 ;; *) exit 0 ;; esac
  fi
  # The lock holder is the only writer (a lock-held run never gets here), so
  # the values read at start are current.
  applied="$PREV_APPLIED"; success="$PREV_SUCCESS"
  generation="$PREV_GENERATION"; failures="$PREV_FAILURES"
  case "$result" in
    applied)
      applied="$TARGET"; success="$(now_iso)"; failures=0
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
  write_state "$result" "$reason" "$TARGET" "$applied" "$success" "$generation" "$failures"
  log "result: ${result}${reason:+ ($reason)}${TARGET:+ target=$TARGET}${applied:+ applied=$applied}${generation:+ generation=$generation}"
  exit "$rc"
}

# ── Lock ─────────────────────────────────────────────────────────────────────
release_lock() {
  if [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local pid
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    # No pid yet = the holder is between mkdir and writing it: treat as held.
    if [[ -z "$pid" ]] || kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    log "removing stale lock left by pid $pid"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  echo "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT
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

# ── Build + activate ─────────────────────────────────────────────────────────
build_system() {
  local out
  out=$(run_timeout "$BUILD_TIMEOUT" nix --extra-experimental-features 'nix-command flakes' \
      --option accept-flake-config false \
      build --out-link "$BUILD_LINK" --print-out-paths \
      "$CHECKOUT#darwinConfigurations.\"$FLAKE_ATTR\".system" </dev/null) || return 1
  out=$(printf '%s\n' "$out" | tail -n 1)
  [[ -n "$out" && -x "$out/activate" ]] || { log "build produced no activatable system ($out)"; return 1; }
  printf '%s' "$out"
}

# Close the primary user's sudo window before activation. nix-darwin runs
# `brew bundle` as that user, and modules/darwin/sudo-rebuild.nix makes their
# sudo timestamp user-global: a cask installer could otherwise silently reuse a
# window a human opened minutes earlier. With it closed (and no tty), every
# sudo that brew or mas attempts fails fast instead of escalating or prompting.
close_user_sudo_window() {
  [[ -n "$PRIMARY_USER" ]] || return 0
  sudo -n -u "$PRIMARY_USER" -- sudo -K </dev/null >/dev/null 2>&1 \
    || log "warning: could not invalidate $PRIMARY_USER's sudo timestamp"
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
  log "start channel=$CHANNEL attr=$FLAKE_ATTR dry_run=$DRY_RUN force_check=$FORCE_CHECK scheduled=$SCHEDULED"

  if ! read_state; then
    # Not overwritten on purpose: the audit then reports state-unreadable, and
    # the rewind guard is never silently reset by a blank applied_commit.
    log "state file $STATE_FILE is unreadable or not schema 1 — refusing to run; inspect and remove it"
    exit 1
  fi

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
  if rebuild_in_progress; then finish skipped rebuild-in-progress; fi
  if [[ $FORCE_CHECK -eq 0 ]] && ! on_ac_power; then finish skipped on-battery; fi

  sync_checkout || finish failed fetch-failed
  TARGET=$(g rev-parse --verify --quiet "refs/remotes/origin/$CHANNEL^{commit}") \
    || finish failed fetch-failed
  log "channel $CHANNEL tip: $TARGET"

  local vrc=0
  verify_signature "$TARGET" || vrc=$?
  case $vrc in
    0) ;;
    2) finish refused signer-key-expired ;;
    *) finish refused signature-invalid ;;
  esac
  is_ancestor "$TARGET" refs/remotes/origin/main || finish refused not-in-main
  if [[ -n "$PREV_APPLIED" ]]; then
    if ! g cat-file -e "$PREV_APPLIED^{commit}" 2>/dev/null || ! is_ancestor "$PREV_APPLIED" "$TARGET"; then
      log "channel tip $TARGET does not descend from applied $PREV_APPLIED"
      finish refused not-fast-forward
    fi
  fi

  if [[ "$TARGET" == "$PREV_APPLIED" && -n "$PREV_GENERATION" \
        && "$(current_generation)" == "$PREV_GENERATION" ]] && system_is_current; then
    finish no-op
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "would build darwinConfigurations.\"$FLAKE_ATTR\".system at $TARGET and activate it"
    finish applied
  fi

  g checkout --quiet --force --detach "$TARGET" || finish failed unknown
  g clean -ffdxq || finish failed unknown
  [[ "$(g rev-parse HEAD)" == "$TARGET" && -z "$(g status --porcelain)" ]] \
    || { log "checkout is not a clean $TARGET"; finish failed unknown; }

  local out
  log "building darwinConfigurations.\"$FLAKE_ATTR\".system"
  out=$(build_system) || finish failed build-failed
  log "built $out"

  # Re-check right before touching the system profile: a manual rebuild may
  # have started during the (possibly hours-long) build. This narrows the race
  # to the activation itself; closing it fully needs rebuild.sh to honour
  # $LOCK_DIR (follow-up — rebuild.sh is outside this change).
  if rebuild_in_progress; then finish skipped rebuild-in-progress; fi
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
