#!/usr/bin/env bash
# fleet-fix.sh — fix this device's fleet action items ON the device.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/fleet-fix.sh | bash -s -- <fix-id> [--apply]
#   ~/dotfiles/scripts/fleet-fix.sh <fix-id> [--apply] [--yes] [--force]
#
# Fix ids — the dashboard (GET /api/fleet/health action items) names one per item:
#   doctor           this host's open action items -> fix id + dry-run plan for each
#   backup           backup blockers: repos to push, secrets to escrow, Time Machine,
#                    iCloud Desktop & Documents (report-only: --apply changes nothing)
#   age-key          sops age key via setup-secrets.sh + the recipient-side step
#   audit            install/repair the collector-runner schedule, run one audit
#   firewall         macOS application firewall (rouvens-mac-studio is exempt, #93)
#   filevault        macOS FileVault (on Linux: same as disk-encryption)
#   disk-encryption  Linux LUKS report — cannot encrypt in place (on macOS: filevault)
#   resources        disk / swap; --apply = nix-collect-garbage 30d + brew cleanup
#   drift            run audit-config-drift.sh and summarise it (report-only)
#   fleet-update     rh7-fleet-update state, log tail and its --dry-run (report-only)
#
# Default is a DRY RUN: inspect, print every finding as OK / FIX / MANUAL with the
# exact command, change nothing. --apply performs only the safe, idempotent steps
# of THAT fix id, asking first (on /dev/tty) before anything that needs sudo, a
# GUI or 1Password; --yes answers those prompts. --force overrides the Studio's
# firewall exemption. Nothing here runs `op`, pushes git, or deletes user data.
#
# Exit: 0 nothing to fix, 1 items remain (dry-run) or --apply incomplete,
#       2 error (e.g. config service unreachable), 64 usage.
#
# Helpers are reused, not copied: the config-service resolver is loaded from
# scripts/lib/config-service.sh (+ the marked block in collector-runner.sh);
# age keys go through setup-secrets.sh; audits through collector-runner.sh.
# Run clone-free, those files are fetched from $FLEET_FIX_RAW_BASE (raw main).

# Paths are shown and matched as "~/…" (the audit reports them that way); those
# tildes are literal text, expanded explicitly by untilde().
# shellcheck disable=SC2088
set -o pipefail

FF_RAW_BASE="${FLEET_FIX_RAW_BASE:-https://raw.githubusercontent.com/rh7/dotfiles/main}"
FF_CURL="curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/fleet-fix.sh | bash -s --"
FF_STUDIO="rouvens-mac-studio"
SFW="${FLEET_FIX_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
FU_ROOT="${FLEET_FIX_FLEET_UPDATE_ROOT:-}"
FU_STATE="$FU_ROOT/var/lib/rh7-fleet-update/state.json"
FU_LOG="$FU_ROOT/var/log/rh7-fleet-update.log"
FU_STALE_HOURS=72       # = config-service FLEET_UPDATE_STALE_HOURS
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
RUNNER_LABEL="com.rh7.collector-runner"
STALE_AUDIT_HOURS=168   # = config-service src/audit-age.ts
DISK_PCT_WARN=80        # = /api/fleet/health "Disk N% full" (> 80)
SWAP_MB_WARN=1000       # = /api/fleet/health "High swap" (> 1000 MB)

OS="$(uname -s)"
# Same derivation as audit-device.sh (strip .local, keep case); the registry key
# is the lowercased form (config-service canonicalizeHostname, #62).
HOST_RAW="$(hostname | sed 's/\.local$//')"
HOST_LC="$(printf '%s' "$HOST_RAW" | tr '[:upper:]' '[:lower:]')"

APPLY=0; FORCE=0; ASSUME_YES=0; FIX_ID=""
N_OK=0; N_FIX=0; N_MANUAL=0
REPO=""; HELPER_ROOT=""; CS_URL=""; CS_TRIED=0
FF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fix.XXXXXX")" || exit 2
trap 'rm -rf "$FF_TMP"' EXIT

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[0;34m'; C_R=$'\033[0;31m'; C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_N=$'\033[0m'
else
  C_G=""; C_Y=""; C_B=""; C_R=""; C_D=""; C_BOLD=""; C_N=""
fi

# ── output ───────────────────────────────────────────────────────────────────
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_N"; }
info()    { printf '           %s%s%s\n' "$C_D" "$*" "$C_N"; }
cmdline() { printf '           %s→ %s%s\n' "$C_B" "$*" "$C_N"; }
err()     { printf '%s[ERROR]%s %s\n' "$C_R" "$C_N" "$*" >&2; }
st_ok()     { N_OK=$((N_OK + 1));         printf '  %s[OK]%s     %s\n' "$C_G" "$C_N" "$1"; }
st_fix()    { N_FIX=$((N_FIX + 1));       printf '  %s[FIX]%s    %s\n' "$C_Y" "$C_N" "$1"; [ -z "${2:-}" ] || cmdline "$2"; }
st_manual() { N_MANUAL=$((N_MANUAL + 1)); printf '  %s[MANUAL]%s %s\n' "$C_B" "$C_N" "$1"; [ -z "${2:-}" ] || cmdline "$2"; }

usage() {
  cat <<EOF
Usage: fleet-fix.sh <fix-id> [--apply] [--yes] [--force]
  fix ids: doctor backup age-key audit firewall filevault disk-encryption
           resources drift fleet-update
  default dry-run; --apply = do the safe steps (prompts before sudo/GUI/1Password)
  clone-free: $FF_CURL <fix-id> [--apply]
EOF
}

# The command a user should run for a fix id — in the form they invoked us.
fix_cmd() {
  if [ -n "$REPO" ]; then printf '%s/scripts/fleet-fix.sh %s' "$(tilde "$REPO")" "$*"
  else printf '%s %s' "$FF_CURL" "$*"; fi
}
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
untilde() { case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac; }

# Ask on the terminal (stdin may be the piped script). No terminal -> no.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans=""
  { : </dev/tty; } 2>/dev/null || { info "no terminal to confirm on — skipped (re-run interactively or pass --yes)"; return 1; }
  printf '  %s?%s %s [y/N] ' "$C_Y" "$C_N" "$1" >/dev/tty
  read -r ans </dev/tty || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Interactive commands read the terminal, never stdin (under `curl | bash` stdin
# is the script itself).
with_tty() { if { : </dev/tty; } 2>/dev/null; then "$@" </dev/tty; else "$@" </dev/null; fi; }

run_timeout() { # same fallback chain as audit-device.sh
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; my $p=fork; if($p){$SIG{ALRM}=sub{kill "KILL",$p; exit 124}; alarm $s; waitpid $p,0; exit($?>>8)} else {exec @ARGV or exit 127}' "$secs" "$@"
  else "$@"; fi
}

# python3, but never the macOS CLT stub (it pops an install dialog).
have_python() {
  local p; p="$(command -v python3 2>/dev/null)" || return 1
  if [ "$OS" = "Darwin" ] && [ "$p" = "/usr/bin/python3" ]; then
    xcode-select -p >/dev/null 2>&1 || return 1
  fi
  return 0
}
# git, likewise (the /usr/bin/git stub also pops the CLT dialog).
have_git() {
  local p; p="$(command -v git 2>/dev/null)" || return 1
  if [ "$OS" = "Darwin" ] && [ "$p" = "/usr/bin/git" ]; then
    xcode-select -p >/dev/null 2>&1 || return 1
  fi
  return 0
}

# ── helpers: checkout or raw-main fetch ─────────────────────────────────────
locate_repo() {
  local self="${BASH_SOURCE[0]:-}" d
  if [ -n "$self" ] && [ -f "$self" ] && [ "$(basename "$self")" = "fleet-fix.sh" ]; then
    d="$(cd "$(dirname "$self")/.." && pwd)"
    [ -f "$d/scripts/lib/config-service.sh" ] && REPO="$d"
  fi
}

# Sets HELPER_ROOT to a tree holding scripts/lib/config-service.sh and
# scripts/collector-runner.sh: this checkout, else raw main, else ~/dotfiles.
resolve_helper_root() {
  [ -n "$HELPER_ROOT" ] && return 0
  if [ -n "$REPO" ]; then HELPER_ROOT="$REPO"; return 0; fi
  local h="$FF_TMP/helpers" f ok=1
  mkdir -p "$h/scripts/lib"
  for f in scripts/lib/config-service.sh scripts/collector-runner.sh; do
    curl -fsSL --max-time 20 "$FF_RAW_BASE/$f" -o "$h/$f" 2>/dev/null || { ok=0; break; }
  done
  if [ "$ok" -eq 1 ]; then HELPER_ROOT="$h"; return 0; fi
  if [ -f "$HOME/dotfiles/scripts/lib/config-service.sh" ]; then
    err "could not fetch helpers from $FF_RAW_BASE — using ~/dotfiles (may be behind main)"
    HELPER_ROOT="$HOME/dotfiles"; return 0
  fi
  err "could not fetch helpers from $FF_RAW_BASE and there is no ~/dotfiles checkout"
  return 1
}

# A real checkout (needed for setup-secrets.sh / audit-config-drift.sh).
dotfiles_dir() {
  if [ -n "$REPO" ]; then printf '%s' "$REPO"; return 0; fi
  [ -f "$HOME/dotfiles/scripts/setup-secrets.sh" ] && { printf '%s' "$HOME/dotfiles"; return 0; }
  return 1
}

# Resolve the config service once, through the fleet's one resolver.
resolve_cs() {
  [ "$CS_TRIED" -eq 1 ] && { [ -n "$CS_URL" ]; return; }
  CS_TRIED=1
  resolve_helper_root || return 1
  # shellcheck source=lib/config-service.sh
  . "$HELPER_ROOT/scripts/lib/config-service.sh" || return 1
  load_config_service_resolver "$HELPER_ROOT" || { err "could not load the config-service resolver"; return 1; }
  CS_URL="$(find_config_service)"
  [ -n "$CS_URL" ]
}
cs_get() { curl -sf --max-time 15 "${CS_URL}$1"; }
cs_offline_msg() {
  err "config service unreachable — cannot read this host's fleet state."
  info "check: tailscale status; cat /etc/rh7/config-service; or set CONFIG_SERVICE_URL=http://<host>:3456"
}

# ── doctor ───────────────────────────────────────────────────────────────────
# Pure: action item (kind, summary, os) -> fix id, or nothing (no device-side fix).
fix_id_for() {
  case "$1" in
    backup) echo backup ;;
    stale_audit|no_audit|unparseable_audit) echo audit ;;
    resource) echo resources ;;
    config-drift|config-drift-collection) echo drift ;;
    fleet-update|fleet-update-stale) echo fleet-update ;;
    security)
      case "$2" in
        "Age key missing"*) echo age-key ;;
        "Firewall OFF"*) echo firewall ;;
        "No disk encryption"*|"FileVault"*) if [ "$3" = "Darwin" ]; then echo filevault; else echo disk-encryption; fi ;;
      esac ;;
  esac
}

cmd_doctor() {
  # Read-only even when called with --apply: plans run in dry-run mode.
  [ "$APPLY" -eq 1 ] && info "doctor is read-only; --apply ignored (run each fix id with --apply)"
  APPLY=0
  section "fleet-fix doctor — $HOST_LC ($OS)"
  have_python || { err "python3 is required for doctor (macOS: xcode-select --install)"; return 2; }
  resolve_cs || { cs_offline_msg; return 2; }
  info "config service: $CS_URL"
  cs_get /api/fleet/health >"$FF_TMP/health.json" || { err "GET $CS_URL/api/fleet/health failed"; return 2; }
  python3 - "$FF_TMP/health.json" "$HOST_LC" >"$FF_TMP/items" <<'PY' || { err "unreadable /api/fleet/health payload"; return 2; }
import json, sys
d = json.load(open(sys.argv[1]))
for a in d.get("action_items") or []:
    if str(a.get("hostname", "")).lower() != sys.argv[2]:
        continue
    f = [a.get(k) or "" for k in ("severity", "kind", "summary", "next_action", "command")]
    print("\x1f".join(str(x).replace("\n", " ") for x in f))
PY
  if [ ! -s "$FF_TMP/items" ]; then st_ok "no open action items for $HOST_LC"; return 0; fi
  local sev kind summary next command fid ids=""
  while IFS=$'\x1f' read -r sev kind summary next command; do
    fid="$(fix_id_for "$kind" "$summary" "$OS")"
    if [ -z "$fid" ]; then
      st_manual "[$sev] $kind: $summary" "${command:-$next}"
      [ -n "$command" ] && [ -n "$next" ] && info "$next"
    elif [ "$fid" = "firewall" ] && [ "$HOST_LC" = "$FF_STUDIO" ] && [ "$FORCE" -eq 0 ]; then
      st_ok "[$sev] $kind: $summary — exempt on $FF_STUDIO by design (#93)"
    else
      st_fix "[$sev] $kind: $summary  (fix id: $fid)" "$(fix_cmd "$fid")"
      case " $ids " in *" $fid "*) ;; *) ids="$ids $fid" ;; esac
    fi
  done <"$FF_TMP/items"
  local prc=0
  for fid in $ids; do
    section "plan: $fid"
    run_fix "$fid" || { [ $? -eq 2 ] && prc=2; }
  done
  return "$prc"
}

# ── backup ───────────────────────────────────────────────────────────────────
backup_repo() { # live re-check of one at-risk repo from the audit
  local path="$1" adirty="$2" aunp="$3" branch="$4" p q dirty unp ns
  p="$(untilde "$path")"; q="$(printf '%q' "$p")"
  # New refs under a per-host namespace: never pushes onto an existing branch.
  ns="refs/heads/backup/$HOST_LC-$(date +%Y%m%d)"
  if [ ! -d "$p" ] || ! have_git; then
    st_manual "$path: audit saw $adirty dirty, $aunp unpushed (branch $branch) — cannot re-check here"
    return
  fi
  dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  # Same measure as the collector (audit-device.sh): commits on ANY local branch
  # that no remote-tracking ref contains — not just HEAD vs its upstream.
  unp="$(GIT_OPTIONAL_LOCKS=0 git -C "$p" rev-list --count --branches --not --remotes 2>/dev/null)" || unp="?"
  # Push to origin, else the repo's first remote; with none, say so instead of
  # printing a push that cannot work (the collector counts remote-less repos too).
  local remote
  remote="$(git -C "$p" remote 2>/dev/null | grep -qx origin && echo origin || git -C "$p" remote 2>/dev/null | head -1)"
  if [ "$dirty" = "0" ] && [ "$unp" = "0" ]; then
    st_ok "$path: clean, every local branch is on a remote (audit is older) — refresh with: $(fix_cmd audit) --apply"
    return
  fi
  if [ -z "$remote" ]; then
    st_manual "$path: $dirty uncommitted change(s), $unp commit(s), and NO git remote — create a private remote first (or rely on Time Machine)" \
      "gh repo create $(basename "$p" | tr ' ' '-') --private --source $q --remote origin && git -C $q push origin 'refs/heads/*:refs/heads/*'"
    [ "$dirty" != "0" ] && info "then commit the $dirty uncommitted change(s): git -C $q add -A && git -C $q commit -m 'wip' && git -C $q push origin HEAD"
  elif [ "$dirty" != "0" ]; then
    st_manual "$path: $dirty uncommitted change(s), $unp unpushed commit(s) — commit on a wip branch, push every branch to a backup namespace" \
      "git -C $q switch -c wip-backup-$(date +%Y%m%d) && git -C $q add -A && git -C $q commit -m 'wip: backup from $HOST_LC' && git -C $q push $remote 'refs/heads/*:$ns/*'"
  else
    st_manual "$path: $unp commit(s) on local branches no remote has — push every branch to a backup namespace (never onto main)" \
      "git -C $q push $remote 'refs/heads/*:$ns/*'"
  fi
}

backup_local_darwin() {
  local tm
  tm="$(tmutil destinationinfo 2>&1)"
  case "$tm" in
    *"No destinations"*|"")
      st_manual "Time Machine: no destination configured — add an ENCRYPTED external disk (needs GUI)" \
        "open 'x-apple.systempreferences:com.apple.Time-Machine-Settings.extension'"
      info "System Settings → General → Time Machine → Add Backup Disk → tick 'Encrypt Backup'"
      info "CLI alternative (no encryption choice): sudo tmutil setdestination -a /Volumes/<Disk> && sudo tmutil enable" ;;
    *) st_ok "Time Machine: destination configured"
       info "$(printf '%s' "$tm" | grep -m1 -E '^Name' || true)" ;;
  esac
  local desk docs
  desk="$(defaults read com.apple.finder FXICloudDriveDesktop 2>/dev/null)"
  docs="$(defaults read com.apple.finder FXICloudDriveDocuments 2>/dev/null)"
  if [ "$desk" = "1" ] || [ "$docs" = "1" ]; then
    st_ok "iCloud Desktop & Documents: on (~/Desktop, ~/Documents replicated)"
  else
    info "iCloud Desktop & Documents: off — optional cover for ~/Documents: System Settings → Apple Account → iCloud → iCloud Drive → Desktop & Documents Folders"
  fi
}

fix_backup() {
  [ "$APPLY" -eq 1 ] && info "backup is report-only: nothing is pushed, escrowed or enabled automatically"
  local rc=0
  if ! have_python; then err "python3 is required to read backup posture"; rc=2
  elif ! resolve_cs; then cs_offline_msg; rc=2
  elif ! cs_get "/api/fleet/backup/$HOST_LC" >"$FF_TMP/backup.json"; then
    err "GET /api/fleet/backup/$HOST_LC failed (device not registered, or never audited?)"; rc=2
  fi
  if [ "$rc" -eq 0 ]; then
    local code
    code="$(curl -s -o "$FF_TMP/retire.json" -w '%{http_code}' --max-time 15 "$CS_URL/api/fleet/retirement/$HOST_LC" 2>/dev/null)"
    [ "$code" = "200" ] || : >"$FF_TMP/retire.json"
    python3 - "$FF_TMP/backup.json" "$FF_TMP/retire.json" >"$FF_TMP/backup.lines" <<'PY' || { err "unreadable backup payload"; rc=2; }
import json, sys
b = json.load(open(sys.argv[1]))
try:
    r = json.load(open(sys.argv[2]))
except Exception:
    r = None
S = "\x1f"
print(S.join(["meta", str(b.get("audited_at") or "?"), str(b.get("audit_age_hours") or "?"),
              "1" if r else "0", str((r or {}).get("summary") or "")]))
for p in b.get("paths") or []:
    print(S.join(["path", p.get("path", ""), p.get("status", ""), p.get("why", "")]))
for g in b.get("at_risk_repos") or []:
    print(S.join(["repo", g.get("path", ""), str(g.get("dirty", 0)), str(g.get("unpushed", 0)), g.get("branch") or "?"]))
for x in (r or {}).get("blockers") or []:
    if x.get("kind", "").startswith("secret_"):
        print(S.join(["secret", x.get("kind", ""), x.get("detail", "")]))
for x in (r or {}).get("warnings") or []:
    if x.get("kind", "").startswith("secret_"):
        print(S.join(["secret", x.get("kind", ""), x.get("detail", "")]))
PY
  fi
  if [ "$rc" -eq 0 ]; then
    local t a b c d secrets="" other=""
    while IFS=$'\x1f' read -r t a b c d; do
      case "$t" in
        meta)
          info "backup posture from the audit of $a (${b}h old); live checks below re-verify on this device"
          if [ "$c" = "1" ]; then info "retirement verdict: $d"; else info "retirement verdict is admin-gated for this caller — showing backup coverage only"; fi
          section "repos with unreplicated work" ;;
        repo) backup_repo "$a" "$b" "$c" "$d" ;;
        path)
          case "$b" in
            protected|absent) ;;
            *) case "$a" in
                 "~/.ssh"|"~/.ssh/"*|"~/.config/sops"*|"~/.gnupg"*) secrets="$secrets$a ($c) is $b"$'\n' ;;
                 *) other="$other$a ($c) is $b"$'\n' ;;
               esac ;;
          esac ;;
        secret) secrets="$secrets$b"$'\n' ;;
      esac
    done <"$FF_TMP/backup.lines"
    grep -q '^repo' "$FF_TMP/backup.lines" || st_ok "no at-risk repos in the last audit"
    section "secrets to escrow (1Password)"
    if [ -n "$secrets" ]; then
      printf '%s' "$secrets" | while IFS= read -r line; do info "$line"; done
      st_manual "escrow single-copy secrets into 1Password — interactive, run it yourself (dry-run first; never unattended)" \
        "~/rh-device-management/scripts/escrow-secrets-1password.sh   # then: … --apply"
      info "needs an interactive 'op signin'; no clone? gh repo clone rh7/rh-device-management ~/rh-device-management"
    else
      st_ok "no unescrowed secret paths reported"
    fi
    section "other unprotected paths"
    if [ -n "$other" ]; then
      printf '%s' "$other" | while IFS= read -r line; do info "$line"; done
      st_manual "cover these with Time Machine (or move code into a pushed git repo)"
    else
      st_ok "none"
    fi
  fi
  if [ "$OS" = "Darwin" ]; then
    section "Time Machine / iCloud (live)"
    backup_local_darwin
  fi
  return "$rc"
}

# ── age-key ──────────────────────────────────────────────────────────────────
age_pub() { command -v age-keygen >/dev/null 2>&1 && age-keygen -y "$AGE_KEY_FILE" 2>/dev/null; }

fix_age_key() {
  local dot pub rc
  if [ -f "$AGE_KEY_FILE" ]; then
    pub="$(age_pub)"
    st_ok "age key present: $(tilde "$AGE_KEY_FILE")${pub:+ ($pub)}"
    info "dashboard still says 'Age key missing'? the audit predates the key: $(fix_cmd audit) --apply"
    return 0
  fi
  if ! dot="$(dotfiles_dir)"; then
    st_manual "no age key, and no dotfiles checkout to run setup-secrets.sh from" \
      "git clone https://github.com/rh7/dotfiles ~/dotfiles && ~/dotfiles/scripts/setup-secrets.sh"
    st_manual "then, on an existing recipient (rouvens-mac-studio or m5-air)" "scripts/sops-add-host.sh $HOST_RAW"
    return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    st_fix "no age key at $(tilde "$AGE_KEY_FILE")" "$(fix_cmd age-key) --apply"
    info "--apply runs $(tilde "$dot")/scripts/setup-secrets.sh: generates the key, registers its public key"
    st_manual "then, on an existing recipient (rouvens-mac-studio or m5-air)" "scripts/sops-add-host.sh $HOST_RAW"
    return 0
  fi
  bash "$dot/scripts/setup-secrets.sh" </dev/null; rc=$?
  if [ ! -f "$AGE_KEY_FILE" ]; then
    st_fix "setup-secrets.sh exited $rc without creating $(tilde "$AGE_KEY_FILE")" "bash $(tilde "$dot")/scripts/setup-secrets.sh"
    return 0
  fi
  pub="$(age_pub)"
  st_ok "age key created: $(tilde "$AGE_KEY_FILE")${pub:+ ($pub)}"
  if [ "$rc" -eq 0 ]; then st_ok "this device can decrypt (or needs no secrets)"
  else st_manual "not a sops recipient yet — on an existing recipient (rouvens-mac-studio or m5-air)" "scripts/sops-add-host.sh $HOST_RAW${pub:+ $pub}"; fi
  info "refresh the dashboard: $(fix_cmd audit) --apply"
}

# ── audit ────────────────────────────────────────────────────────────────────
schedule_state() { # prints a description and returns 0 when a schedule exists
  if [ "$OS" = "Darwin" ]; then
    launchctl print "gui/$(id -u)/$RUNNER_LABEL" >/dev/null 2>&1 && { echo "LaunchAgent $RUNNER_LABEL loaded"; return 0; }
  else
    systemctl --user is-enabled fleet-audit.timer >/dev/null 2>&1 && { echo "systemd user timer fleet-audit.timer (nix-declared)"; return 0; }
    crontab -l 2>/dev/null | grep -q 'fleet-collector-runner' && { echo "cron (fleet-collector-runner)"; return 0; }
  fi
  return 1
}

audit_age_hours() { # prints hours, "never", or nothing (unknown)
  resolve_cs >/dev/null 2>&1 || return 0
  have_python || return 0
  if ! cs_get "/api/audit/$HOST_LC" >"$FF_TMP/audit.json"; then echo never; return 0; fi
  python3 - "$FF_TMP/audit.json" <<'PY' 2>/dev/null
import json, sys, datetime
a = json.load(open(sys.argv[1]))
t = datetime.datetime.strptime(a["audited_at"][:19], "%Y-%m-%d %H:%M:%S")
print(int((datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - t).total_seconds() // 3600))
PY
}

# Run collector-runner.sh: the checkout's copy, else the fetched one fed on
# stdin so it self-installs a persistent copy instead of scheduling a temp file.
run_runner() {
  if [ -n "$REPO" ]; then bash "$REPO/scripts/collector-runner.sh" "$@" </dev/null; return; fi
  if [ $# -eq 0 ] && [ -f "$HOME/.cache/fleet-collector/collector-runner.sh" ]; then
    bash "$HOME/.cache/fleet-collector/collector-runner.sh" </dev/null; return
  fi
  resolve_helper_root || return 1
  bash -s -- "$@" <"$HELPER_ROOT/scripts/collector-runner.sh"
}

fix_audit() {
  local sched age need=0 stale=0
  if sched="$(schedule_state)"; then st_ok "collector scheduled: $sched"; else need=1; fi
  resolve_cs >/dev/null || true   # in this shell, so audit_age_hours' subshells reuse it
  age="$(audit_age_hours)"
  if [ "$APPLY" -eq 0 ]; then
    [ "$need" -eq 1 ] && st_fix "no collector-runner schedule on this host" "$(fix_cmd audit) --apply"
    case "$age" in
      "") st_manual "last audit age unknown (config service unreachable)" "$(fix_cmd audit) --apply" ;;
      never) stale=1; st_fix "this host has never uploaded an audit" "$(fix_cmd audit) --apply" ;;
      *) if [ "$age" -gt "$STALE_AUDIT_HOURS" ]; then stale=1; st_fix "last audit is ${age}h old (> ${STALE_AUDIT_HOURS}h)" "$(fix_cmd audit) --apply"
         else st_ok "last audit ${age}h ago"; fi ;;
    esac
    [ $((need + stale)) -gt 0 ] && info "--apply runs: collector-runner.sh --install (reloads the nix-declared agent where one exists), then one gated audit"
    return 0
  fi
  if [ "$need" -eq 1 ]; then
    if run_runner --install && sched="$(schedule_state)"; then st_ok "collector scheduled: $sched"
    else st_fix "collector-runner --install did not leave a schedule" "$(fix_cmd audit) --apply"; fi
  fi
  case "$age" in
    [0-9]*) [ "$age" -le "$STALE_AUDIT_HOURS" ] && [ "$need" -eq 0 ] && return 0 ;;
  esac
  if run_runner; then
    age="$(audit_age_hours)"
    case "$age" in
      [0-9]*) [ "$age" -le 1 ] && { st_ok "audit uploaded (${age}h old)"; return 0; } ;;
    esac
    st_fix "audit ran but the config service has no fresh audit (age: ${age:-unknown})" "$(fix_cmd audit) --apply"
  else
    st_fix "collector-runner failed — see ~/.cache/fleet-collector/runner.log" "$(fix_cmd audit) --apply"
  fi
}

# ── firewall ─────────────────────────────────────────────────────────────────
fw_state() {
  local out; out="$("$SFW" --getglobalstate 2>/dev/null)"
  case "$out" in
    *disabled*|*"State = 0"*) echo off ;;
    *enabled*|*"State = 1"*|*"State = 2"*) echo on ;;
    *) echo unknown ;;
  esac
}

fix_firewall() {
  if [ "$OS" != "Darwin" ]; then
    st_manual "Linux firewalls are host policy (nftables / ufw), not a device toggle — review it on the host" "sudo nft list ruleset | less   # or: sudo ufw status verbose"
    return 0
  fi
  if [ "$HOST_LC" = "$FF_STUDIO" ] && [ "$FORCE" -eq 0 ]; then
    st_ok "firewall exempt on $FF_STUDIO by design (#93) — not checked or changed (--force overrides)"
    return 0
  fi
  local s; s="$(fw_state)"
  case "$s" in
    on) st_ok "application firewall is on"; return 0 ;;
    unknown) st_manual "could not read the firewall state" "$SFW --getglobalstate"; return 0 ;;
  esac
  if [ "$APPLY" -eq 0 ]; then
    st_fix "application firewall is OFF" "$(fix_cmd firewall) --apply"
    info "--apply runs: sudo $SFW --setglobalstate on  (then re-verifies; on macOS 15+ may need the System Settings toggle)"
    return 0
  fi
  if confirm "Enable the macOS firewall (sudo)?"; then
    with_tty sudo "$SFW" --setglobalstate on
  fi
  if [ "$(fw_state)" = "on" ]; then st_ok "application firewall enabled (verified)"; return 0; fi
  # macOS 15+/26: the CLI can silently no-op under TCC/MDM — hand off to the pane.
  info "still off — the CLI can no-op on macOS 15+ (TCC/MDM); the System Settings toggle works"
  if confirm "Open System Settings → Network → Firewall to switch it on?"; then
    open "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall" 2>/dev/null \
      || open "x-apple.systempreferences:com.apple.preference.security?Firewall" 2>/dev/null
    confirm "Turned the Firewall toggle on? (re-verifies)" || true
  fi
  if [ "$(fw_state)" = "on" ]; then st_ok "application firewall enabled (verified)"
  else st_fix "application firewall is still OFF" "System Settings → Network → Firewall → On"; fi
}

# ── filevault / disk-encryption ──────────────────────────────────────────────
fix_disk_encryption() {
  if [ "$OS" != "Darwin" ]; then
    if lsblk -o NAME,FSTYPE 2>/dev/null | grep -q crypto_LUKS; then st_ok "LUKS volume present"; return 0; fi
    st_manual "no LUKS volume — Linux cannot be encrypted in place; this is report-only"
    info "accepted-risk path: Ack the item on the dashboard (issue-state ack) and note why (e.g. server in a locked room / VPS)"
    info "or re-provision with LUKS at the next reinstall (NixOS installer: encrypt the root partition)"
    return 0
  fi
  local s; s="$(fdesetup status 2>/dev/null)"
  case "$s" in
    *"FileVault is On"*|*"Encryption in progress"*) st_ok "FileVault: ${s%%$'\n'*}"; return 0 ;;
    "") st_manual "could not read FileVault status" "fdesetup status"; return 0 ;;
  esac
  if [ "$APPLY" -eq 0 ]; then
    st_fix "FileVault is Off" "$(fix_cmd filevault) --apply"
    info "--apply runs: sudo fdesetup enable  (interactive; prints a personal recovery key)"
    return 0
  fi
  if confirm "Enable FileVault now (sudo fdesetup enable; you'll type your login password)?"; then
    with_tty sudo fdesetup enable
  fi
  s="$(fdesetup status 2>/dev/null)"
  case "$s" in
    *"FileVault is On"*|*"Encryption in progress"*|*"Deferred enablement"*)
      st_ok "FileVault: ${s%%$'\n'*}"
      st_manual "store the recovery key in 1Password NOW (item: \"FileVault recovery key — $HOST_LC\")" ;;
    *) st_fix "FileVault is still Off" "sudo fdesetup enable" ;;
  esac
}

# ── resources ────────────────────────────────────────────────────────────────
# macOS: the Data volume is what fills (`/` is the sealed system snapshot).
disk_pct() {
  local v=/; [ "$OS" = "Darwin" ] && [ -d /System/Volumes/Data ] && v=/System/Volumes/Data
  df -Pk "$v" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}
swap_mb() {
  if [ "$OS" = "Darwin" ]; then sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9]*\).*/\1/p'
  else free -m 2>/dev/null | awk '/^Swap:/ {print $3}'; fi
}

space_report() {
  section "space users (read-only)"
  if [ "$OS" = "Darwin" ]; then
    info "data volume: $(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $3" used of "$2" ("$5")"}')"
    info "nix store volume: $(df -h /nix 2>/dev/null | awk 'NR==2 {print $3" used"}')"
  else
    info "nix store: $(run_timeout 30 du -sh /nix/store 2>/dev/null | cut -f1)"
  fi
  if command -v nix-collect-garbage >/dev/null 2>&1; then
    info "nix-collect-garbage --dry-run: $(run_timeout 120 nix-collect-garbage --dry-run 2>&1 | grep -c '/nix/store/') dead store paths"
  fi
  if command -v brew >/dev/null 2>&1; then
    info "brew cache: $(du -sh "$(brew --cache 2>/dev/null)" 2>/dev/null | cut -f1)"
  fi
  if [ "$OS" = "Darwin" ] && [ -d "$HOME/Library/Caches" ]; then
    info "~/Library/Caches top 5:"
    run_timeout 30 du -sk "$HOME"/Library/Caches/* 2>/dev/null | sort -rn | awk 'NR<=5 {printf "             %6d MB  %s\n", $1/1024, $2}' | sed "s|$HOME|~|"
  fi
  if command -v docker >/dev/null 2>&1; then
    info "docker / OrbStack:"
    run_timeout 15 docker system df 2>/dev/null | sed 's/^/             /'
  fi
}

fix_resources() {
  local pct swap
  pct="$(disk_pct)"; swap="$(swap_mb)"
  if [ -z "$pct" ]; then st_manual "could not read disk usage" "df -h /"
  elif [ "$pct" -gt "$DISK_PCT_WARN" ]; then
    if [ "$APPLY" -eq 0 ]; then
      st_fix "disk is ${pct}% full (> ${DISK_PCT_WARN}%)" "$(fix_cmd resources) --apply"
      info "--apply runs: nix-collect-garbage --delete-older-than 30d; brew cleanup  (never touches user data)"
    fi
  else st_ok "disk is ${pct}% full"; fi
  if [ -n "$swap" ] && [ "$swap" -gt "$SWAP_MB_WARN" ]; then
    st_manual "swap in use: ${swap} MB — find and restart/close the heavy workload (or add RAM)" "ps -Ao rss,pid,comm | sort -rn | head -5"
    ps -Ao rss,comm 2>/dev/null | sort -rn | awk 'NR<=5 {printf "             %6d MB  %s\n", $1/1024, $2}'
  elif [ -n "$swap" ]; then st_ok "swap in use: ${swap} MB"; fi
  space_report
  if [ "$APPLY" -eq 1 ] && [ -n "$pct" ] && [ "$pct" -gt "$DISK_PCT_WARN" ]; then
    section "cleanup"
    command -v nix-collect-garbage >/dev/null 2>&1 && nix-collect-garbage --delete-older-than 30d </dev/null 2>&1 | tail -3
    command -v brew >/dev/null 2>&1 && brew cleanup </dev/null 2>&1 | tail -3
    info "system generations are root's: sudo nix-collect-garbage --delete-older-than 30d (not run)"
    pct="$(disk_pct)"
    if [ -n "$pct" ] && [ "$pct" -gt "$DISK_PCT_WARN" ]; then
      st_fix "disk still ${pct}% full after cleanup — remove data by hand (see space users above)"
    else st_ok "disk now ${pct}% full"; fi
  fi
}

# ── drift ────────────────────────────────────────────────────────────────────
fix_drift() {
  local dot rc
  if ! dot="$(dotfiles_dir)" || [ ! -f "$dot/scripts/audit-config-drift.sh" ]; then
    st_manual "drift is measured against a dotfiles checkout; none here" "git clone https://github.com/rh7/dotfiles ~/dotfiles"
    return 0
  fi
  [ "$APPLY" -eq 1 ] && info "drift is report-only: fold changes into the flake (branch → PR) or run rebuild.sh"
  run_timeout 300 bash "$dot/scripts/audit-config-drift.sh" </dev/null >"$FF_TMP/drift.out" 2>&1; rc=$?
  sed 's/^/           /' "$FF_TMP/drift.out" | tail -20
  case "$rc" in
    0) st_ok "no configuration drift" ;;
    1) st_manual "drift found — fold real changes into the flake (branch → PR), or rebuild to reset them" "$(tilde "$dot")/scripts/rebuild.sh" ;;
    *) st_manual "drift collection failed (exit $rc) — fix the cause above (e.g. 'nix not found' = not a nix host yet)" "bash $(tilde "$dot")/scripts/audit-config-drift.sh --json" ;;
  esac
}

# ── fleet-update ─────────────────────────────────────────────────────────────
fu_success_age_hours() { # prints hours, "never", or nothing (unreadable)
  have_python || return 0
  python3 - "$FU_STATE" <<'PY' 2>/dev/null
import json, sys, datetime
s = json.load(open(sys.argv[1])).get("last_success_at")
if not s:
    print("never"); sys.exit()
t = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
if t.tzinfo is None:
    t = t.replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 3600))
PY
}

fix_fleet_update() {
  if [ "$OS" != "Darwin" ]; then st_ok "fleet-update is nix-darwin only — not applicable on $OS"; return 0; fi
  if ! command -v rh7-fleet-update >/dev/null 2>&1 && [ ! -e "$FU_STATE" ]; then
    st_ok "fleet-update is not enabled on this host (no rh7-fleet-update, no state.json) — nothing to check"
    info "hosts opt in via modules/darwin/fleet-update.nix (its header explains the daemon)"
    return 0
  fi
  [ "$APPLY" -eq 1 ] && info "fleet-update is report-only; --apply only lets the dry-run prompt for sudo"
  section "state ($FU_STATE)"
  if [ -r "$FU_STATE" ]; then
    sed 's/^/           /' "$FU_STATE"; echo
    case "$(tr -d ' \n' <"$FU_STATE")" in
      *'"last_result":"refused"'*) st_manual "last run REFUSED a commit (trust check) — treat as a security event; inspect the log" ;;
      *'"last_result":"applied"'*|*'"last_result":"no-op"'*|*'"last_result":"skipped"'*)
        local sage; sage="$(fu_success_age_hours)"
        case "$sage" in
          never) st_manual "no successful fleet update ever recorded — read the log below" ;;
          [0-9]*) if [ "$sage" -gt "$FU_STALE_HOURS" ]; then st_manual "last successful fleet update ${sage}h ago (> ${FU_STALE_HOURS}h) — check power/sleep schedule and the log"
                  else st_ok "last run ok; last success ${sage}h ago"; fi ;;
          *) st_manual "last run ok, but last_success_at is unreadable — inspect state.json above" ;;
        esac ;;
      *) st_manual "last run failed — read the log below; fix the build/activation in rh7/dotfiles" ;;
    esac
  elif [ -e "$FU_STATE" ]; then st_manual "state.json not readable" "sudo cat $FU_STATE"
  else st_manual "no state.json — the daemon has never completed a run" "sudo launchctl print system/org.rh7.fleet-update"; fi
  section "log (last 50 lines)"
  if [ -r "$FU_LOG" ]; then tail -50 "$FU_LOG" | sed 's/^/           /'
  elif [ -e "$FU_LOG" ]; then info "not readable: sudo tail -50 $FU_LOG"
  else info "no log at $FU_LOG"; fi
  section "rh7-fleet-update --dry-run"
  if ! command -v rh7-fleet-update >/dev/null 2>&1; then
    st_manual "rh7-fleet-update is not on PATH but state.json exists — the module was removed or the system profile is broken" "darwin-rebuild --list-generations | tail -3"
    return 0
  fi
  local rc
  if sudo -n true 2>/dev/null; then
    sudo -n rh7-fleet-update --dry-run </dev/null 2>&1 | tail -30 | sed 's/^/           /'; rc=${PIPESTATUS[0]}
  elif [ "$APPLY" -eq 1 ] && confirm "Run 'sudo rh7-fleet-update --dry-run' (read-only trust/build check)?"; then
    with_tty sudo rh7-fleet-update --dry-run 2>&1 | tail -30 | sed 's/^/           /'; rc=${PIPESTATUS[0]}
  else
    st_manual "the dry-run needs root (it reads the daemon's checkout) — run it yourself" "sudo rh7-fleet-update --dry-run"
    return 0
  fi
  case "$rc" in
    0) st_ok "rh7-fleet-update --dry-run: ok" ;;
    3) st_manual "rh7-fleet-update --dry-run: REFUSED (exit 3) — see output above" ;;
    *) st_manual "rh7-fleet-update --dry-run exited $rc — see output above" ;;
  esac
}

# ── main ─────────────────────────────────────────────────────────────────────
run_fix() {
  case "$1" in
    doctor) cmd_doctor ;;
    backup) fix_backup ;;
    age-key) fix_age_key ;;
    audit) fix_audit ;;
    firewall) fix_firewall ;;
    filevault|disk-encryption) fix_disk_encryption ;;
    resources) fix_resources ;;
    drift) fix_drift ;;
    fleet-update) fix_fleet_update ;;
    *) return 64 ;;
  esac
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1 ;;
      --force) FORCE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) usage; return 0 ;;
      -*) err "unknown option: $1"; usage >&2; return 64 ;;
      *) [ -z "$FIX_ID" ] || { err "one fix id at a time (got '$FIX_ID' and '$1')"; return 64; }; FIX_ID="$1" ;;
    esac
    shift
  done
  case "$FIX_ID" in
    doctor|backup|age-key|audit|firewall|filevault|disk-encryption|resources|drift|fleet-update) ;;
    "") usage >&2; return 64 ;;
    *) err "unknown fix id: $FIX_ID"; usage >&2; return 64 ;;
  esac
  locate_repo
  [ "$FIX_ID" = "doctor" ] || section "fleet-fix $FIX_ID — $HOST_LC ($OS)$([ "$APPLY" -eq 1 ] && echo ' — APPLY' || echo ' — dry-run')"
  local rc=0
  run_fix "$FIX_ID" || rc=$?
  echo
  printf '%s%d OK, %d FIX, %d MANUAL%s\n' "$C_BOLD" "$N_OK" "$N_FIX" "$N_MANUAL" "$C_N"
  [ "$rc" -ne 0 ] && return "$rc"
  if [ $((N_FIX + N_MANUAL)) -gt 0 ]; then
    [ "$APPLY" -eq 0 ] && [ "$N_FIX" -gt 0 ] && [ "$FIX_ID" != "doctor" ] && info "dry-run: nothing was changed. Re-run with --apply to perform the FIX steps."
    return 1
  fi
  return 0
}

# Everything above is definitions, so under `curl | bash` the whole script is
# parsed before anything runs; commands that read stdin get EOF, not script text.
main "$@"
exit $?
