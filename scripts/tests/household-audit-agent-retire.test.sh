#!/usr/bin/env bash
# Coverage for retireUserAuditAgent (modules/home/profiles/fleet-audit.nix) on
# a household Mac: the daily audit moved from the primary user's gui-domain
# LaunchAgent to a system LaunchDaemon (modules/darwin/fleet-audit.nix), so the
# FIRST activation after that change must remove her com.rh7.collector-runner
# agent — also while she is logged out (the owner rebuilding from his account,
# the nightly fleet-update), and also when the plist on disk is an imperative
# `collector-runner.sh --install` copy, which home-manager alone leaves behind.
#
# Run: ./scripts/tests/household-audit-agent-retire.test.sh   (macOS + nix; skips elsewhere)
#
# Runs the REAL activation text — home-manager's pinned setupLaunchAgents plus
# retireUserAuditAgent, as evaluated from kassie-mbp-m1 — against a sandbox
# home whose previous generation shipped the agent. Only /bin/launchctl is
# replaced (sed) by a stub that answers like launchd: without a GUI session
# every gui/<uid> call fails with "125: Domain does not support specified
# action". Properties pinned:
#   - logged out or in, activation succeeds, the agent plist is gone, nothing
#     is bootstrapped; logged in, the loaded agent is booted out of gui/<uid>;
#   - an imperative (diverged) plist is removed too — home-manager alone skips
#     it ("contents have diverged"), which would leave a second daily audit.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOST=kassie-mbp-m1
HM_USER=kassie
LABEL=com.rh7.collector-runner

if [[ "$(uname -s)" != Darwin ]] || ! command -v nix >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: needs macOS, nix and jq (evaluates the household home-manager activation)"
  exit 0
fi

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

W=$(mktemp -d /tmp/hmretire.XXXXXX)
trap 'rm -rf "$W"' EXIT

NIXF=(--extra-experimental-features 'nix-command flakes')
CFG="$REPO#darwinConfigurations.\"$HOST\""

if ! nix "${NIXF[@]}" eval --json "$CFG.config.home-manager.users.$HM_USER" --apply '
  u: { home = u.home.homeDirectory;
       retire = u.home.activation.retireUserAuditAgent;
       setup = u.home.activation.setupLaunchAgents; }' >"$W/act.json" 2>"$W/eval.err"; then
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
echo "household audit agent retirement — wiring"
check "runs after writeBoundary" "$(jq -r '.retire.after | index("writeBoundary") != null' "$W/act.json")" true
check "runs before setupLaunchAgents" "$(jq -r '.retire.before | index("setupLaunchAgents") != null' "$W/act.json")" true
other=$(nix "${NIXF[@]}" eval --json "$REPO#darwinConfigurations.\"m5-air\".config.home-manager.users" \
  --apply 'us: builtins.any (u: u.home.activation ? retireUserAuditAgent) (builtins.attrValues us)' 2>/dev/null)
check "user-agent Mac (m5-air) does not retire its agent" "$other" false

# ── Stub launchctl ───────────────────────────────────────────────────────────
STUB="$W/launchctl"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >>"$STUB_LOG"
nogui() { echo "$1: 125: Domain does not support specified action" >&2; exit 125; }
case "$1" in
  print)
    [[ "$STUB_GUI" == 1 ]] || nogui "Could not print domain"
    [[ "$2" == gui/*/* && -n "${STUB_LOADED:-}" ]] && exit 0
    echo "Could not find service" >&2; exit 113 ;;
  bootout)
    [[ "$STUB_GUI" == 1 ]] || nogui "Boot-out failed"
    [[ -n "${STUB_LOADED:-}" ]] && exit 0
    echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  bootstrap)
    [[ "$STUB_GUI" == 1 ]] || nogui "Bootstrap failed"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB"

# run_activation <with-retire 0|1> <deployed: same|diverged> — writes $W/out,
# $W/rc. The previous generation shipped the agent; the new one ships none.
run_activation() {
  local retire="$1" deployed="$2" case_dir="$W/case$RANDOM"
  mkdir -p "$case_dir/old/LaunchAgents" "$case_dir/gen/LaunchAgents" "$case_dir/home/Library/LaunchAgents"
  printf '<plist><dict><key>Label</key><string>%s</string></dict></plist>\n' "$LABEL" \
    >"$case_dir/old/LaunchAgents/$LABEL.plist"
  if [[ "$deployed" == same ]]; then
    cp "$case_dir/old/LaunchAgents/$LABEL.plist" "$case_dir/home/Library/LaunchAgents/"
  else
    echo "<plist>imperative --install copy</plist>" >"$case_dir/home/Library/LaunchAgents/$LABEL.plist"
  fi
  CASE="$case_dir"
  sub() { jq -r "$1" "$W/act.json" | sed -e "s#/bin/launchctl#$STUB#g" -e "s#$HM_HOME#$case_dir/home#g"; }
  {
    echo 'set -eu'
    echo 'set -o pipefail'
    echo "source '$HM_SRC/lib/bash/home-manager.sh'"
    echo "oldGenPath='$case_dir/old'"
    echo "newGenPath='$case_dir/gen'"
    if [[ "$retire" == 1 ]]; then sub .retire.data; fi
    sub .setup.data
    echo 'echo "activation finished"'
  } >"$case_dir/activate.sh"
  : >"$case_dir/launchctl.log"
  env -i PATH="$TOOLPATH/usr/bin:/bin:/usr/sbin:/sbin" HOME="$case_dir/home" \
      STUB_LOG="$case_dir/launchctl.log" STUB_GUI="${STUB_GUI:-0}" STUB_LOADED="${STUB_LOADED:-}" \
      bash "$case_dir/activate.sh" >"$W/out" 2>&1
  echo $? >"$W/rc"
}
present() { [[ -e "$CASE/home/Library/LaunchAgents/$LABEL.plist" ]] && echo yes || echo no; }
calls() { grep -c " $1 " "$CASE/launchctl.log" || true; }

echo ""
echo "household audit agent retirement — logged out (no GUI session)"
STUB_GUI=0 run_activation 1 same
check "activation succeeds" "$(cat "$W/rc")" 0
check "agent plist removed" "$(present)" no
check "nothing bootstrapped" "$(calls bootstrap)" 0
grep -q "removed the $LABEL LaunchAgent" "$W/out" && good "says the system daemon runs the audit now" \
  || bad "says the system daemon runs the audit now" "$(cat "$W/out")"

STUB_GUI=0 run_activation 1 diverged
check "imperative copy: activation succeeds" "$(cat "$W/rc")" 0
check "imperative copy: removed" "$(present)" no

echo ""
echo "household audit agent retirement — logged in, agent loaded"
STUB_GUI=1 STUB_LOADED=1 run_activation 1 same
check "activation succeeds" "$(cat "$W/rc")" 0
check "agent plist removed" "$(present)" no
grep -q "bootout gui/[0-9]*/$LABEL" "$CASE/launchctl.log" && good "loaded agent booted out of gui/<uid>" \
  || bad "loaded agent booted out of gui/<uid>" "$(cat "$CASE/launchctl.log")"
check "nothing bootstrapped" "$(calls bootstrap)" 0

echo ""
echo "control — home-manager alone"
STUB_GUI=1 STUB_LOADED=1 run_activation 0 diverged
check "leaves an imperative copy behind (why the step exists)" "$(present)" yes

echo ""
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
