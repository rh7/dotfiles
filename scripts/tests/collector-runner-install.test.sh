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
# These tests pin: a declared, deployed agent is not overwritten and the DECLARED
# plist is what gets (re)bootstrapped; a declared agent that is missing on disk
# or that launchd refuses falls back to the imperative LaunchAgent (the device
# must keep auditing); and a host without a home-manager agent still gets the
# imperative LaunchAgent.
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

# Stub bin: uname reports Darwin; launchctl records every call (and, for
# bootstrap, the CONTENT of the plist it was handed) and succeeds — except with
# LAUNCHCTL_FAIL_FIRST_BOOTSTRAP=1, where the first bootstrap fails (models a
# declared plist that launchd refuses to load).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$LAUNCHCTL_LOG"
if [ "$1" = "bootstrap" ]; then
  if [ "${LAUNCHCTL_FAIL_FIRST_BOOTSTRAP:-0}" = 1 ] \
    && [ "$(grep -c '^bootstrap ' "$LAUNCHCTL_LOG")" -eq 1 ]; then
    echo "Bootstrap failed: 5: Input/output error" >&2
    exit 5
  fi
  echo "loaded-content $(head -c 64 "$3")" >> "$LAUNCHCTL_LOG"
fi
exit 0
EOF
chmod +x "$TMP/bin/uname" "$TMP/bin/launchctl"

# make_home <dir> [deploy] -> HOME whose active home-manager generation declares
# the agent; with "deploy" the same plist is also in ~/Library/LaunchAgents.
make_home() {
  local home="$1" hm_dir="$1/.local/state/home-manager/gcroots/current-home/LaunchAgents"
  mkdir -p "$hm_dir" "$home/Library/LaunchAgents"
  echo "declared-by-home-manager" > "$hm_dir/$LABEL.plist"
  [[ "${2:-}" == deploy ]] && cp "$hm_dir/$LABEL.plist" "$home/Library/LaunchAgents/$LABEL.plist"
  return 0
}

# run_install <home> [ENV=VAL...] -> sets OUT; launchctl calls land in <home>/launchctl.log
run_install() {
  local home="$1"; shift
  : > "$home/launchctl.log"
  OUT="$(env "$@" HOME="$home" LAUNCHCTL_LOG="$home/launchctl.log" \
    COLLECTOR_CACHE_DIR="$home/cache" PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" --install 2>&1)"
}

# assert_imperative <home> <case> — the imperative agent was written and bootstrapped
assert_imperative() {
  grep -q "<string>$LABEL</string>" "$1/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
    && good "$2: imperative LaunchAgent plist is written" \
    || bad "$2: imperative LaunchAgent plist is written" "got: $OUT"
  grep -q "^bootstrap " "$1/launchctl.log" \
    && good "$2: agent is bootstrapped into launchd" \
    || bad "$2: agent is bootstrapped into launchd" "calls: $(cat "$1/launchctl.log")"
}

echo ""
echo "collector-runner --install — declared and deployed"

# The label may already be loaded from a STALE imperative registration (a
# partially failed activation); "is it loaded?" can't tell. The declared plist
# itself must be what ends up bootstrapped.
H1="$TMP/declared"
make_home "$H1" deploy
run_install "$H1"

[[ "$(cat "$H1/Library/LaunchAgents/$LABEL.plist")" == "declared-by-home-manager" ]] \
  && good "declared plist is not overwritten" \
  || bad "declared plist is not overwritten" "plist now: $(cat "$H1/Library/LaunchAgents/$LABEL.plist")"
grep -q "^loaded-content declared-by-home-manager" "$H1/launchctl.log" \
  && good "the declared plist is (re)bootstrapped, replacing any stale job" \
  || bad "the declared plist is (re)bootstrapped, replacing any stale job" "calls: $(cat "$H1/launchctl.log")"
[[ "$(grep -c '^bootstrap ' "$H1/launchctl.log")" -eq 1 ]] \
  && good "no imperative agent is bootstrapped" \
  || bad "no imperative agent is bootstrapped" "calls: $(cat "$H1/launchctl.log")"
grep -q "declared by the active home-manager generation" <<<"$OUT" \
  && good "says why it skipped the imperative install" || bad "says why it skipped the imperative install" "got: $OUT"

echo ""
echo "collector-runner --install — declared but NOT loadable (falls back)"

H3="$TMP/declared-missing"
make_home "$H3"
run_install "$H3"
assert_imperative "$H3" "deployed plist missing"

H4="$TMP/declared-refused"
make_home "$H4" deploy
run_install "$H4" LAUNCHCTL_FAIL_FIRST_BOOTSTRAP=1
assert_imperative "$H4" "launchd refuses the declared plist"

echo ""
echo "collector-runner --install — no declared agent (imperative path)"

H2="$TMP/imperative"
mkdir -p "$H2"
run_install "$H2"
assert_imperative "$H2" "no home-manager agent"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
