#!/usr/bin/env bash
# Coverage for `collector-runner.sh --install` on macOS vs a home-manager agent.
#
# Run: ./scripts/tests/collector-runner-install.test.sh
#
# Every nix-darwin Mac declares com.rh7.collector-runner through home-manager
# (modules/home/profiles/fleet-audit.nix via mkMac, rh-device-management#315).
# setup.sh runs `--install` right AFTER activation; without a guard that call
# boots the declared agent out and overwrites its plist with the imperative one,
# so the host silently runs an unmanaged schedule until the next rebuild.
# These tests pin both directions: a declared agent is left untouched, and a
# host without one still gets the imperative LaunchAgent.
#
# The script runs for real in a sandbox HOME; `uname` and `launchctl` are stubbed
# on PATH so the Darwin branch is exercised on any OS without touching launchd.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/collector-runner.sh"
LABEL="com.rh7.collector-runner"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub bin: uname reports Darwin; launchctl records calls and succeeds.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$LAUNCHCTL_LOG"
exit 0
EOF
chmod +x "$TMP/bin/uname" "$TMP/bin/launchctl"

# run_install <home> -> sets OUT; launchctl calls land in <home>/launchctl.log
run_install() {
  local home="$1"
  : > "$home/launchctl.log"
  OUT="$(HOME="$home" LAUNCHCTL_LOG="$home/launchctl.log" \
    COLLECTOR_CACHE_DIR="$home/cache" PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" --install 2>&1)"
}

echo ""
echo "collector-runner --install — home-manager-declared agent"

H1="$TMP/declared"
hm_dir="$H1/.local/state/home-manager/gcroots/current-home/LaunchAgents"
mkdir -p "$hm_dir" "$H1/Library/LaunchAgents"
echo "declared-by-home-manager" > "$hm_dir/$LABEL.plist"
cp "$hm_dir/$LABEL.plist" "$H1/Library/LaunchAgents/$LABEL.plist"
run_install "$H1"

[[ "$(cat "$H1/Library/LaunchAgents/$LABEL.plist")" == "declared-by-home-manager" ]] \
  && good "declared plist is not overwritten" \
  || bad "declared plist is not overwritten" "plist now: $(cat "$H1/Library/LaunchAgents/$LABEL.plist")"
[[ ! -s "$H1/launchctl.log" ]] \
  && good "launchctl is never called (no bootout of the declared agent)" \
  || bad "launchctl is never called (no bootout of the declared agent)" "calls: $(cat "$H1/launchctl.log")"
grep -q "declared by the active home-manager generation" <<<"$OUT" \
  && good "says why it skipped" || bad "says why it skipped" "got: $OUT"

echo ""
echo "collector-runner --install — no declared agent (imperative path)"

H2="$TMP/imperative"
mkdir -p "$H2"
run_install "$H2"

grep -q "<string>$LABEL</string>" "$H2/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
  && good "imperative LaunchAgent plist is written" \
  || bad "imperative LaunchAgent plist is written" "got: $OUT"
grep -q "^bootstrap " "$H2/launchctl.log" \
  && good "agent is bootstrapped into launchd" \
  || bad "agent is bootstrapped into launchd" "calls: $(cat "$H2/launchctl.log")"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
