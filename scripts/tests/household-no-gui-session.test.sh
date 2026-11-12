#!/usr/bin/env bash
# Coverage for rh7NoGuiSessionGuard (configurations/macos/home-household.nix):
# home-manager activation for a household Mac's primary user while she has NO
# login session — the owner adopting the Mac from his own account, or the
# nightly fleet-update running as root while she is logged out.
#
# Run: ./scripts/tests/household-no-gui-session.test.sh   (macOS + nix; skips elsewhere)
#
# Runs the REAL activation text — home-manager's pinned setupLaunchAgents plus
# the guard entries, as evaluated from kassie-mbp-m1 — against a sandbox home.
# Only /bin/launchctl is replaced (sed) by a stub that answers like launchd
# does for a user without a GUI session ("125: Domain does not support
# specified action", as `launchctl print gui/<uid>` reports for a logged-out
# account). Properties pinned:
#   - without the guard, upstream activation FAILS in that state (the bug);
#   - with it, activation succeeds, the plist is installed for the next login,
#     ONLY the gui bootstrap is skipped, and `run` is restored afterwards;
#   - with a GUI session the guard changes nothing, and a real bootstrap
#     failure still fails activation.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOST=kassie-mbp-m1
HM_USER=kassie

if [[ "$(uname -s)" != Darwin ]] || ! command -v nix >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: needs macOS, nix and jq (evaluates the household home-manager activation)"
  exit 0
fi

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

W=$(mktemp -d /tmp/hmgui.XXXXXX)
trap 'rm -rf "$W"' EXIT

NIXF=(--extra-experimental-features 'nix-command flakes')
CFG="$REPO#darwinConfigurations.\"$HOST\""

# The three activation entries, their DAG edges, and the user's home.
if ! nix "${NIXF[@]}" eval --json "$CFG.config.home-manager.users.$HM_USER" --apply '
  u: { home = u.home.homeDirectory;
       guard = u.home.activation.rh7NoGuiSessionGuard;
       setup = u.home.activation.setupLaunchAgents;
       done = u.home.activation.rh7NoGuiSessionGuardEnd; }' >"$W/act.json" 2>"$W/eval.err"; then
  echo "FATAL: could not evaluate $HOST's home-manager activation:" >&2
  cat "$W/eval.err" >&2
  exit 1
fi
HM_HOME=$(jq -r .home "$W/act.json")
HM_SRC=$(nix "${NIXF[@]}" flake archive --json "$REPO" | jq -r '.inputs."home-manager".path')
# GNU coreutils (readlink -m, install -T) and bash >= 4.2, as activation has.
TOOLS=$(nix "${NIXF[@]}" build --no-link --print-out-paths \
  "$CFG.pkgs.coreutils" "$CFG.pkgs.bash" "$CFG.pkgs.gettext") || { echo "FATAL: could not build tools" >&2; exit 1; }
TOOLPATH=$(printf '%s/bin:' $TOOLS)

echo ""
echo "household no-GUI-session guard — wiring"
check "guard runs after writeBoundary" "$(jq -r '.guard.after | index("writeBoundary") != null' "$W/act.json")" true
check "guard runs before setupLaunchAgents" "$(jq -r '.guard.before | index("setupLaunchAgents") != null' "$W/act.json")" true
check "guard end runs after setupLaunchAgents" "$(jq -r '.done.after | index("setupLaunchAgents") != null' "$W/act.json")" true
other=$(nix "${NIXF[@]}" eval --json "$REPO#darwinConfigurations.\"m5-air\".config.home-manager.users" \
  --apply 'us: builtins.any (u: u.home.activation ? rh7NoGuiSessionGuard) (builtins.attrValues us)' 2>/dev/null)
check "full-profile Mac (m5-air) does not get the guard" "$other" false

# ── Stub launchctl ───────────────────────────────────────────────────────────
STUB="$W/launchctl"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >>"$STUB_LOG"
nogui() { echo "$1: 125: Domain does not support specified action" >&2; exit 125; }
case "$1" in
  print)
    if [[ "$STUB_GUI" != 1 ]]; then nogui "Could not print domain"; fi
    [[ "$2" == gui/* && "$2" != gui/*/* ]] && exit 0   # the domain exists
    echo "Could not find service" >&2; exit 113 ;;  # the agent is not loaded
  bootout)
    [[ "$STUB_GUI" == 1 ]] || nogui "Boot-out failed"
    echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  bootstrap)
    [[ "$STUB_GUI" == 1 ]] || nogui "Bootstrap failed"
    if [[ -n "${STUB_BOOTSTRAP_FAIL:-}" ]]; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB"

# run_activation <with-guard 0|1> — writes $W/out, $W/rc. Assembles the entries
# in DAG order with home-manager's own bash library, like the activate script.
run_activation() {
  local guard="$1" case_dir="$W/case$RANDOM"
  mkdir -p "$case_dir/gen/LaunchAgents" "$case_dir/home"
  printf '<plist><dict><key>Label</key><string>com.rh7.collector-runner</string></dict></plist>\n' \
    >"$case_dir/gen/LaunchAgents/com.rh7.collector-runner.plist"
  CASE="$case_dir"
  sub() { jq -r "$1" "$W/act.json" | sed -e "s#/bin/launchctl#$STUB#g" -e "s#$HM_HOME#$case_dir/home#g"; }
  {
    echo 'set -eu'
    echo 'set -o pipefail'
    echo "source '$HM_SRC/lib/bash/home-manager.sh'"
    echo "newGenPath='$case_dir/gen'"
    if [[ "$guard" == 1 ]]; then sub .guard.data; fi
    echo 'declare -f run >"$CASE_DIR/run.during"'
    sub .setup.data
    if [[ "$guard" == 1 ]]; then sub .done.data; fi
    echo 'declare -f run >"$CASE_DIR/run.after"'
    echo 'declare -F _rh7HmRun >/dev/null && echo "LEAK: _rh7HmRun still defined"'
    echo 'echo "activation finished"'
  } >"$case_dir/activate.sh"
  : >"$case_dir/launchctl.log"
  env -i PATH="$TOOLPATH/usr/bin:/bin:/usr/sbin:/sbin" HOME="$case_dir/home" \
      STUB_LOG="$case_dir/launchctl.log" CASE_DIR="$case_dir" \
      STUB_GUI="${STUB_GUI:-0}" STUB_BOOTSTRAP_FAIL="${STUB_BOOTSTRAP_FAIL:-}" \
      bash "$case_dir/activate.sh" >"$W/out" 2>&1
  echo $? >"$W/rc"
}
installed() { [[ -f "$CASE/home/Library/LaunchAgents/com.rh7.collector-runner.plist" ]] && echo yes || echo no; }
bootstraps() { grep -c ' bootstrap ' "$CASE/launchctl.log" || true; }

# The unmodified HM `run`, for the restore check.
orig_run=$(env -i PATH="$TOOLPATH/usr/bin:/bin" bash -c "source '$HM_SRC/lib/bash/home-manager.sh'; declare -f run")

echo ""
echo "household no-GUI-session guard — no GUI session (logged out)"
STUB_GUI=0 run_activation 0
check "upstream alone: activation fails" "$(cat "$W/rc")" 1
grep -q 'Bootstrap failed: 125' "$W/out" && good "upstream alone: fails on the gui bootstrap (125)" \
  || bad "upstream alone: fails on the gui bootstrap (125)" "$(cat "$W/out")"

STUB_GUI=0 run_activation 1
check "guarded: activation succeeds" "$(cat "$W/rc")" 0
check "guarded: plist installed for the next login" "$(installed)" yes
check "guarded: gui bootstrap skipped" "$(bootstraps)" 0
grep -q 'LaunchAgents installed; they load at the next login' "$W/out" \
  && good "guarded: prints the marker fleet-update/rebuild.sh match" || bad "guarded: prints the marker" "$(cat "$W/out")"
check "guarded: run restored after setupLaunchAgents" "$(cat "$CASE/run.after")" "$orig_run"
grep -q LEAK "$W/out" && bad "guarded: helper removed" "$(cat "$W/out")" || good "guarded: helper removed"
grep -q '_rh7HmRun' "$CASE/run.during" && good "guarded: run wrapped during setupLaunchAgents" \
  || bad "guarded: run wrapped during setupLaunchAgents" "$(cat "$CASE/run.during")"

echo ""
echo "household no-GUI-session guard — GUI session present"
STUB_GUI=1 run_activation 1
check "logged in: activation succeeds" "$(cat "$W/rc")" 0
check "logged in: agent bootstrapped into gui/<uid>" "$(bootstraps)" 1
grep -q 'LaunchAgents installed; they load' "$W/out" && bad "logged in: no marker" "$(cat "$W/out")" \
  || good "logged in: no marker"
check "logged in: run untouched" "$(cat "$CASE/run.during")" "$orig_run"

STUB_GUI=1 STUB_BOOTSTRAP_FAIL=1 run_activation 1
check "logged in, real bootstrap failure: activation still fails" "$(cat "$W/rc")" 1

echo ""
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
