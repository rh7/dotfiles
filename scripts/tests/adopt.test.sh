#!/usr/bin/env bash
# Phase logic of scripts/adopt.sh, with every probe and action stubbed.
#
# adopt.sh keeps each read-only check in a probe_* function and each change in
# an act_* function, and runs `main` only when not sourced with
# ADOPT_SOURCE_ONLY=1. Each scenario sources it in a fresh bash, replaces the
# probes with scenario values and the actions with recorders, and runs main.
# So nothing here touches the machine; the assertions are about which actions
# a scenario reaches, what it prints, and what the state file says.
#
# Run: bash scripts/tests/adopt.test.sh   (any OS; needs only bash)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADOPT="$REPO_ROOT/scripts/adopt.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0

ok()   { echo "  ok   — $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL — $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /' | head -40; fail=$((fail + 1)); }
check()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:  $2"$'\n'"want: $3"; fi; }
has()      { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing: $3"$'\n'"$2"; fi; }
hasnt()    { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected: $3"$'\n'"$2"; else ok "$1"; fi; }

cat >"$T/flake.nix" <<'EOF'
{
  outputs = { self, ... }: let mkMac = a: a; in {
    darwinConfigurations = {
      "test-mac" = mkMac {
        hostname = "test-mac";
        username = "tester";
        autoUpdate = "fleet/stable";
        role = ./modules/roles/household-mac.nix;
        homeProfile = "household";
        needsSecrets = false;
        extraModules = [ ./configurations/macos/test-mac.nix ];
      };

      "secret-mac" = mkMac {
        hostname = "secret-mac";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "Case-Mac" = mkMac {
        hostname = "Case-Mac";
      };
    };
  };
}
EOF

REV=1111111111111111111111111111111111111111

cat >"$T/driver.sh" <<'DRIVER'
ADOPT_SOURCE_ONLY=1 . "$ADOPT"
rec() { echo "$*" >>"$CALLS"; }
probe_os()              { echo "${S_OS:-Darwin}"; }
probe_arch()            { echo "${S_ARCH:-arm64}"; }
probe_macos_version()   { echo 15.1; }
probe_euid()            { echo 501; }
probe_hostname()        { echo "${S_HOST:-test-mac}"; }
probe_is_admin()        { return 0; }
probe_user_exists()     { return 0; }
probe_gui_session()     { [ "${S_GUI:-1}" = 1 ]; }
probe_free_gb()         { echo 100; }
probe_filevault()       { return 0; }
probe_clt()             { [ "${S_CLT:-1}" = 1 ]; }
probe_nix()             { [ "${S_NIX:-1}" = 1 ]; }
probe_determinate()     { return 1; }
probe_tailscale_cli()   { echo /bin/true; }
probe_tailscale_running() { return 0; }
probe_config_service()  { echo http://cs.test:3456; }
probe_pin_present()     { return 0; }
probe_managed()         { [ "${S_MANAGED:-0}" = 1 ]; }
probe_origin_rev()      { echo "$S_REV"; }
probe_local_origin_rev() { echo "$S_REV"; }
probe_dotfiles()        { echo "${S_DOTFILES:-$S_REV}"; }
probe_is_ancestor()     { return 0; }
probe_age_key()         { return 0; }
probe_fleet_update()    { return 0; }
probe_firewall()        { return 0; }
probe_launcher()        { return 0; }
probe_restic_configured() { return 0; }
probe_registry_role()   { echo household; }
probe_homebrew()        { [ "${S_BREW:-1}" = 1 ] || [ -e "$CALLS.brew" ]; }
# The audit "lands" unless S_AUDIT_LOST=1 (the collector exits 0 on a failed POST).
probe_audit_at()        { [ "${S_AUDIT_LOST:-0}" = 1 ] && echo "2000-01-01 00:00:00" || echo "2999-01-01 00:00:00"; }
act_install_brew()      { rec install_brew; : >"$CALLS.brew"; }
user_home()             { echo "/Users/$1"; }
source_nix()            { return 0; }
act_write_pin()         { rec write_pin "$@"; }
act_install_clt()       { rec install_clt; }
act_install_nix()       { rec install_nix; return "${S_NIX_RC:-0}"; }
act_clone()             { rec clone; }
act_fetch()             { rec fetch; }
act_ff()                { rec ff; }
act_setup_secrets()     { rec setup_secrets; return "${S_SECRETS_RC:-0}"; }
act_rebuild()           { shift; rec rebuild "$@"; return "${S_REBUILD_RC:-0}"; }
act_prewipe()           { rec prewipe; }
act_audit_remote()      { rec audit_remote; }
act_audit()             { rec audit; }
act_open_fda()          { rec open_fda; }
# Answers come from S_ANSWERS ("y n …"), one per question; none left = no tty.
read_answer() {
  ANSWER=""
  [ -n "${S_ANSWERS:-}" ] || return 1
  ANSWER="${S_ANSWERS%% *}"
  case "$S_ANSWERS" in *" "*) S_ANSWERS="${S_ANSWERS#* }" ;; *) S_ANSWERS="" ;; esac
  echo "Q: $1 → $ANSWER"
  return 0
}
main "$@"
DRIVER

# run <scenario> [VAR=value …] -- [adopt args …]
# Sets OUT (stdout+stderr), RC, CALLS_OUT (recorded actions), SDIR.
run() {
  local name="$1"; shift
  SDIR="$T/$name"; mkdir -p "$SDIR/home"
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  : >"$SDIR/calls"
  OUT=$(env -i PATH="$PATH" HOME="$SDIR/home" TMPDIR="$T" \
        ADOPT="$ADOPT" CALLS="$SDIR/calls" S_REV="$REV" \
        ADOPT_FLAKE_FILE="$T/flake.nix" ADOPT_STATE_DIR="$SDIR/state" \
        ADOPT_TTY=/nonexistent DOTFILES_DIR="$SDIR/home/dotfiles" \
        ${envs[@]+"${envs[@]}"} bash "$T/driver.sh" "$@" 2>&1)
  RC=$?
  CALLS_OUT=$(cat "$SDIR/calls")
}

echo "== dry-run: fresh Mac, nothing changes =="
run dry S_CLT=0 S_NIX=0 S_BREW=0 S_DOTFILES=absent -- --dry-run
check "exit 0" "$RC" 0
check "no action ran" "$CALLS_OUT" ""
if [ -e "$SDIR/state/state.json" ]; then bad "no state file written"; else ok "no state file written"; fi
has "plans the CLT install" "$OUT" "would run xcode-select --install"
has "plans the Nix install" "$OUT" "would ask, then run the official installer"
has "plans the clone" "$OUT" "would clone"
has "plans the Homebrew install" "$OUT" "would ask, then run Homebrew's official installer"
has "plans the rebuild" "$OUT" "would run scripts/rebuild.sh --plan-only"
has "says DRY RUN" "$OUT" "DRY RUN — nothing was changed"

echo "== dry-run with --yes still changes nothing =="
run dryyes S_CLT=0 S_NIX=0 S_DOTFILES=absent -- --dry-run --yes
check "no action ran" "$CALLS_OUT" ""

echo "== no flake entry: stop with new-host.sh instructions =="
run noentry S_HOST=unknown-mac S_ANSWERS="n n" --
check "exit 3 (needs action)" "$RC" 3
has "points at new-host.sh" "$OUT" "scripts/new-host.sh unknown-mac"
check "declined offers run nothing" "$CALLS_OUT" ""
has "summary says why" "$OUT" "no flake entry for unknown-mac"

echo "== no flake entry + --yes: only the read-only offers run, nothing else =="
run noentryyes S_HOST=unknown-mac S_CLT=0 S_NIX=0 -- --yes
check "exit 3" "$RC" 3
check "pre-wipe check + one audit, nothing else" "$CALLS_OUT" "prewipe
audit_remote"
has "landed audit reported" "$OUT" "audit uploaded to http://cs.test:3456"

echo "== no flake entry: an audit whose upload failed is not reported as uploaded =="
run noentrylost S_HOST=unknown-mac S_AUDIT_LOST=1 -- --yes
hasnt "no false success" "$OUT" "audit uploaded"
has "says no audit reached the service" "$OUT" "no new audit of unknown-mac reached"

echo "== Homebrew missing =="
run brewyes S_BREW=0 S_DOTFILES=absent -- --yes
check "exit 0" "$RC" 0
check "installs Homebrew before the clone and the rebuild" "$(head -n 2 <<<"$CALLS_OUT")" "install_brew
clone"
run brewno S_BREW=0 S_ANSWERS="n" --
check "declined → exit 3" "$RC" 3
hasnt "declined → nothing after it" "$CALLS_OUT" "rebuild"

echo "== no flake entry, dry-run: nothing offered =="
run noentrydry S_HOST=unknown-mac -- --dry-run
check "exit 3" "$RC" 3
check "no action" "$CALLS_OUT" ""

echo "== hostname differs only by case =="
run case S_HOST=case-mac S_ANSWERS="n n" --
check "exit 3" "$RC" 3
has "offers the exact rename" "$OUT" "sudo scutil --set HostName Case-Mac"

echo "== Intel Mac refused =="
run intel S_ARCH=x86_64 --
check "exit 1" "$RC" 1
has "says why" "$OUT" "Apple silicon only"
check "no action" "$CALLS_OUT" ""

echo "== Nix install: consent =="
run nixno S_NIX=0 S_ANSWERS="n" --
check "declined → exit 3" "$RC" 3
hasnt "declined → installer not run" "$CALLS_OUT" "install_nix"
has "state records the stop" "$(cat "$SDIR/state/state.json" 2>/dev/null)" '"phase.nix": "stopped"'

run nixnotty S_NIX=0 --
check "no terminal → exit 3" "$RC" 3
hasnt "no terminal → installer not run" "$CALLS_OUT" "install_nix"

run nixyes S_NIX=0 S_ANSWERS="y y" --
has "y → installer runs" "$CALLS_OUT" "install_nix"

run nixflag S_NIX=0 -- --yes
has "--yes → installer runs" "$CALLS_OUT" "install_nix"

run nixskip S_NIX=0 -- --yes --skip-nix-install
check "--skip-nix-install → exit 3" "$RC" 3
hasnt "--skip-nix-install → installer not run" "$CALLS_OUT" "install_nix"

run nixnogui S_NIX=0 S_GUI=0 -- --yes
check "no GUI session → exit 3" "$RC" 3
hasnt "no GUI session → installer not run" "$CALLS_OUT" "install_nix"
has "says it needs a GUI session" "$OUT" "needs a GUI session"

echo "== happy path, then resume =="
run happy S_DOTFILES=absent -- --yes
check "exit 0" "$RC" 0
check "clone → plan-only → rebuild → audit, in order" "$CALLS_OUT" "clone
rebuild --plan-only
rebuild
audit"
hasnt "--yes is never forwarded to rebuild.sh" "$CALLS_OUT" "rebuild --yes"
st=$(cat "$SDIR/state/state.json")
has "state: rebuild ok" "$st" '"phase.rebuild": "ok"'
has "state: rebuild rev" "$st" "\"rebuild.rev\": \"$REV\""
has "state: host" "$st" '"host": "test-mac"'
# Re-run on the same state: the system is now managed at that revision.
OUT2_STATE="$SDIR/state"
SDIR_SAVE="$SDIR"
OUT=$(env -i PATH="$PATH" HOME="$SDIR_SAVE/home" TMPDIR="$T" ADOPT="$ADOPT" CALLS="$SDIR_SAVE/calls2" \
      S_REV="$REV" S_MANAGED=1 ADOPT_FLAKE_FILE="$T/flake.nix" ADOPT_STATE_DIR="$OUT2_STATE" \
      ADOPT_TTY=/nonexistent DOTFILES_DIR="$SDIR_SAVE/home/dotfiles" bash "$T/driver.sh" --yes 2>&1); RC=$?
check "resume: exit 0" "$RC" 0
has "resume: announced" "$OUT" "resuming — last run"
has "resume: rebuild skipped from state" "$OUT" "already applied origin/main"
hasnt "resume: no rebuild ran" "$(cat "$SDIR_SAVE/calls2" 2>/dev/null)" "rebuild"

echo "== preflight skip: everything present → no install actions =="
run present S_MANAGED=1 -- --yes
check "exit 0" "$RC" 0
hasnt "no CLT install" "$CALLS_OUT" "install_clt"
hasnt "no Nix install" "$CALLS_OUT" "install_nix"
hasnt "no clone" "$CALLS_OUT" "clone"
hasnt "already managed + --yes does not rebuild (default No)" "$CALLS_OUT" "rebuild"

echo "== dirty or branched ~/dotfiles is never touched =="
run dirty S_DOTFILES=dirty -- --yes
check "exit 3" "$RC" 3
hasnt "no fetch/ff/rebuild" "$CALLS_OUT" "rebuild"
run branch S_DOTFILES=branch:feature -- --yes
check "exit 3" "$RC" 3
check "nothing ran" "$CALLS_OUT" ""

echo "== needsSecrets host that cannot decrypt stops before applying =="
run secrets S_HOST=secret-mac S_SECRETS_RC=1 -- --yes
check "exit 3" "$RC" 3
check "fetch, plan-only, then setup-secrets — no apply" "$CALLS_OUT" "fetch
rebuild --plan-only
setup_secrets"

echo "== rebuild.sh failure is a failure, and the next run retries it =="
run rbfail S_REBUILD_RC=1 -- --yes
check "exit 1" "$RC" 1
has "state: rebuild failed" "$(cat "$SDIR/state/state.json")" '"phase.rebuild": "failed"'
# Next run: activation may have happened (managed) — a failed rebuild is still retried, not skipped.
OUT=$(env -i PATH="$PATH" HOME="$SDIR/home" TMPDIR="$T" ADOPT="$ADOPT" CALLS="$SDIR/calls2" \
      S_REV="$REV" S_MANAGED=1 ADOPT_FLAKE_FILE="$T/flake.nix" ADOPT_STATE_DIR="$SDIR/state" \
      ADOPT_TTY=/nonexistent DOTFILES_DIR="$SDIR/home/dotfiles" bash "$T/driver.sh" --yes 2>&1); RC=$?
check "retry: exit 0" "$RC" 0
has "retry: rebuild ran again" "$(cat "$SDIR/calls2")" "rebuild --plan-only"

echo "== bash 3.2 syntax (stock macOS bash) =="
if [ -x /bin/bash ] && /bin/bash --version | head -n 1 | grep -q 'version 3\.'; then
  if /bin/bash -n "$ADOPT"; then ok "bash 3.2 parses adopt.sh"; else bad "bash 3.2 parses adopt.sh"; fi
else
  echo "  skip — no bash 3.2 here"
fi

echo
echo "adopt.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
