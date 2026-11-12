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
#   5. dock-protect   evaluate T's system.defaults.dock.persistent-apps; when it
#                     is set (the Dock is managed), activation REPLACES the
#                     primary user's Dock, so every app now in it that T does
#                     not declare would vanish -> skipped / dock-protect (with
#                     the list in state.dock_protect). An unreadable Dock plist
#                     holds too (fail safe). Additions only, or an unmanaged
#                     Dock, proceed. Only rebuild.sh, which shows the drift and
#                     asks, may remove Dock items.
#                     evaluation fails             -> failed / build-failed
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

  --dry-run      run every precondition, trust and Dock check, report what
                 would be applied; never builds, activates or writes the
                 state file
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
         and all(.[]; type == "string" and startswith("/")));
  type == "object"
  and ((keys - ["dock_protect"]) == ["applied_commit", "channel", "consecutive_failures", "enabled",
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
# DOCK_PROTECT_JSON, when set (a dock-protect hold), becomes `dock_protect`;
# the key is absent from every other state.
write_state() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.state.json.XXXXXX")
  jq -n \
    --arg channel "$CHANNEL" --arg now "$(now_iso)" --arg result "$1" \
    --arg reason "$2" --arg target "$3" --arg applied "$4" --arg success "$5" \
    --arg generation "$6" --argjson failures "$7" --arg dock "$DOCK_PROTECT_JSON" '
    def nullable: if . == "" then null else . end;
    { schema: 1, enabled: true, channel: $channel,
      last_run_at: $now, last_result: $result, reason: ($reason | nullable),
      target_commit: ($target | nullable), applied_commit: ($applied | nullable),
      last_success_at: ($success | nullable),
      generation: (if $generation == "" then null else ($generation | tonumber) end),
      consecutive_failures: $failures }
    + (if $dock == "" then {} else { dock_protect: ($dock | fromjson) } end)' >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# ── Result handling ──────────────────────────────────────────────────────────
TARGET=""
NEW_GENERATION=""   # set once the system profile was switched this run
DOCK_PROTECT_JSON="" # set by check_dock when it holds the update

# finish <result> [reason] — record the outcome and exit. Never returns.
finish() {
  local result="$1" reason="${2:-}" rc applied success generation failures
  # dock_protect belongs to a dock-protect hold only (the state contract).
  [[ "$reason" == dock-protect ]] || DOCK_PROTECT_JSON=""
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

# ── Dock protection ──────────────────────────────────────────────────────────
# nix-darwin's system.defaults.dock.persistent-apps REPLACES the primary user's
# whole Dock on activation, so an app she pinned by hand silently disappears.
# Unattended, that is never acceptable: a run that would remove anything is
# held (skipped / dock-protect) until a human either declares the app or
# confirms the removal through rebuild.sh (which shows the drift and asks).
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

# dock_declaration — the checked-out commit's primary user and Dock
# declaration as {"user": ..., "apps": [...] | null}. Evaluated, not built.
dock_declaration() {
  run_timeout "$EVAL_TIMEOUT" nix --extra-experimental-features 'nix-command flakes' \
    --option accept-flake-config false \
    eval --json --no-update-lock-file \
    "$CHECKOUT#darwinConfigurations.\"$FLAKE_ATTR\".config" \
    --apply 'c: { user = c.system.primaryUser; apps = c.system.defaults.dock.persistent-apps; }' </dev/null
}

# current_dock <user> — the user's current Dock app paths, one per line, read
# from the plist FILE (read-only; root needs no GUI session or cfprefsd). Any
# entry that is neither an app URL nor a spacer makes the Dock unreadable.
current_dock() {
  local plist="$ROOT/Users/$1/Library/Preferences/com.apple.dock.plist" n i url type
  [[ -f "$plist" && -r "$plist" ]] || return 1
  n=$(plutil -extract persistent-apps raw -o - "$plist" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i < n; i++)); do
    if url=$(plutil -extract "persistent-apps.$i.tile-data.file-data._CFURLString" raw -o - "$plist" 2>/dev/null); then
      dock_path "$url"
    else
      type=$(plutil -extract "persistent-apps.$i.tile-type" raw -o - "$plist" 2>/dev/null) || return 1
      [[ "$type" == *spacer* ]] || return 1
    fi
  done
}

# check_dock — 0: activation removes nothing from the primary user's Dock
# (unmanaged, or additions/reorders only). 1: hold; DOCK_PROTECT_JSON is set.
# 2: the declaration could not be evaluated.
check_dock() {
  local decl user declared current removals
  decl=$(dock_declaration) || { log "could not evaluate the Dock declaration of $TARGET"; return 2; }
  jq -e 'type == "object" and has("apps") and (.apps == null or (.apps | type == "array"))' \
    <<<"$decl" >/dev/null 2>&1 || { log "unexpected Dock declaration: $decl"; return 2; }
  if jq -e '.apps == null' <<<"$decl" >/dev/null; then
    log "dock: persistent-apps unset in $TARGET — Dock unmanaged, nothing to protect"
    return 0
  fi
  # Spacers carry no URL; entries are nix-darwin tiles (or plain paths).
  declared=$(jq -r '.apps[] | if type == "string" then .
    else (.["tile-data"]?["file-data"]?["_CFURLString"]? // empty) end' <<<"$decl") || return 2
  declared=$(while IFS= read -r p; do [[ -n "$p" ]] && dock_path "$p"; done <<<"$declared")
  user=$(jq -r '.user // ""' <<<"$decl")
  if [[ ! "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || ! current=$(current_dock "$user"); then
    log "dock-protect: cannot read ${user:-the primary user}'s Dock ($ROOT/Users/${user:-?}/Library/Preferences/com.apple.dock.plist) — holding (fail safe)"
    DOCK_PROTECT_JSON=$(jq -cn --arg now "$(now_iso)" \
      '{would_remove: [], error: "unreadable", checked_at: $now}')
    return 1
  fi
  # current − declared, in Dock order, each path once.
  removals=$(awk 'NR == FNR { d[$0]; next } $0 != "" && !($0 in d) && !s[$0]++' \
    <(printf '%s\n' "$declared") <(printf '%s\n' "$current"))
  if [[ -z "$removals" ]]; then
    log "dock: $TARGET removes nothing from $user's Dock"
    return 0
  fi
  log "dock-protect: activating $TARGET would remove from $user's Dock: $(paste -sd ',' - <<<"$removals" | sed 's/,/, /g')"
  DOCK_PROTECT_JSON=$(jq -cRn --arg now "$(now_iso)" --argjson max "$DOCK_MAX_REPORTED" \
    '{would_remove: ([inputs | select(length > 0)] | .[:$max]), checked_at: $now}' <<<"$removals")
  return 1
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
  # The primary user was logged out: home-manager's household guard
  # (configurations/macos/home-household.nix) installed her LaunchAgents
  # without loading them. A success — they load at her next GUI login — so
  # the run stays `applied`; the note is for whoever reads the log.
  if grep -q 'LaunchAgents installed; they load at the next login' "$act_log"; then
    log "note: ${PRIMARY_USER:-the primary user} had no GUI login session — LaunchAgents installed, they load at the next login (applied)"
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
  # No rewinds. T must descend from the last commit this daemon applied: a tip
  # below it means the signed channel itself went backwards -> refused.
  if [[ -n "$PREV_APPLIED" ]] && ! is_ancestor "$PREV_APPLIED" "$TARGET"; then
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

  if [[ $DRY_RUN -eq 1 ]]; then
    log "would build darwinConfigurations.\"$FLAKE_ATTR\".system at $TARGET and activate it"
    finish applied
  fi

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
