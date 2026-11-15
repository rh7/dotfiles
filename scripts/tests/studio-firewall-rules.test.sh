#!/usr/bin/env bash
# Coverage for scripts/studio-firewall-rules.sh — the Mac Studio's per-app
# application-firewall rules (configurations/macos/mac-studio-firewall.nix).
#
# socketfilterfw is a STATEFUL stub: it keeps the app list in a file, prints
# --listapps in the real macOS 26 format, and logs every argv, so the tests
# assert on what was actually invoked:
#   - apply adds a rule for the RESOLVED path behind a symlink, allow or block;
#   - a second apply changes nothing and prints nothing (the daemon log stays quiet);
#   - --check never calls a mutating command and reports drift by exit code;
#   - a moved binary (symlink repointed, old store path gone) gets a new rule
#     and the stale rule is removed; rules outside the store prefixes are kept;
#   - an existing rule in the wrong state is flipped without a second --add;
#   - a missing path warns but does not fail; a rule that does not stick fails.
#
# Runs on Linux CI and macOS alike. Run: bash scripts/tests/studio-firewall-rules.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/studio-firewall-rules.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"   # macOS: /var → /private/var, so realpath output matches

STATE="$T/apps"; CALLS="$T/calls.log"
: >"$STATE"; : >"$CALLS"
export STATE CALLS

# Stub socketfilterfw. State lines: "<allow|block>\t<path>".
cat >"$T/socketfilterfw" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
cmd="$1"; p="${2-}"
setstate() {  # setstate <path> <state>
  awk -F'\t' -v p="$1" -v s="$2" 'BEGIN{OFS="\t"} $2==p{$1=s} {print}' "$STATE" >"$STATE.new" && mv "$STATE.new" "$STATE"
}
case "$cmd" in
  --listapps)
    n=$(grep -c . "$STATE" || true)
    echo "Total number of apps = $n "
    i=0
    while IFS=$'\t' read -r s path; do
      [ -n "$path" ] || continue
      i=$((i + 1))
      echo "$i : $path "
      if [ "$s" = allow ]; then echo "             (Allow incoming connections)"; else echo "             (Block incoming connections)"; fi
    done <"$STATE"
    ;;
  --add)
    case "$p" in *broken*) exit 0 ;; esac   # a rule that silently does not stick
    if awk -F'\t' -v p="$p" '$2==p{f=1} END{exit !f}' "$STATE"; then
      echo "The application is already a part of the firewall"
    else
      printf 'allow\t%s\n' "$p" >>"$STATE"   # macOS adds new apps as allowed
    fi
    ;;
  --remove)    awk -F'\t' -v p="$p" '$2!=p' "$STATE" >"$STATE.new" && mv "$STATE.new" "$STATE" ;;
  --blockapp)  setstate "$p" block ;;
  --unblockapp) setstate "$p" allow ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/socketfilterfw"
export STUDIO_FW_SOCKETFILTERFW="$T/socketfilterfw"
export STUDIO_FW_STALE_PREFIXES="$T/store/"
# pgrep stub: `pgrep -x NAME` succeeds when NAME is listed in $RUNNING.
printf '#!/usr/bin/env bash\ncase " ${RUNNING:-} " in *" $2 "*) exit 0 ;; esac\nexit 1\n' >"$T/pgrep"
chmod +x "$T/pgrep"
export STUDIO_FW_PGREP="$T/pgrep"

pass=0; fail=0
check() { # check <name> <got> <want>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1"; echo "     got:  $2"; echo "     want: $3"; fi
}
has() { # has <name> <haystack> <needle>
  case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   $1" ;;
  *) fail=$((fail + 1)); echo "FAIL $1"; echo "     missing: $3"; echo "     in: $2" ;; esac
}
state() { cat "$STATE"; }
mutations() { grep -cE '^--(add|remove|blockapp|unblockapp)' "$CALLS" || true; }

# Layout: stable names (symlinks) in front of "store" paths, like the Studio's
# /opt/homebrew/opt/tailscale and /etc/profiles/per-user/<user>.
mkdir -p "$T/store/tailscale-1/bin" "$T/store/node-1/bin" "$T/opt/with space" "$T/System/ControlCenter.app"
touch "$T/store/tailscale-1/bin/tailscaled" "$T/store/node-1/bin/node" "$T/opt/with space/rest-server"
ln -s "$T/store/tailscale-1" "$T/opt/tailscale"
ln -s "$T/store/node-1/bin/node" "$T/opt/node"

ARGS=(--allow "$T/opt/tailscale/bin/tailscaled" --allow "$T/opt/node"
      --allow "$T/opt/with space/rest-server" --block "$T/System/ControlCenter.app")
run() { out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }

echo "== usage =="
run;                          check "no rules: exit 64" "$rc" 64
run --allow;                  check "--allow without a path: exit 64" "$rc" 64
run --bogus x;                check "unknown argument: exit 64" "$rc" 64

echo "== check on an empty firewall: drift, nothing mutated =="
run --check "${ARGS[@]}"
check "check exit 1 on drift" "$rc" 1
has "check counts the drift" "$out" "drift=4 missing=0"
check "check mutates nothing" "$(mutations)" 0

echo "== first apply =="
: >"$CALLS"
run "${ARGS[@]}"
check "apply exit 0" "$rc" 0
check "rules are the resolved paths" "$(state)" "$(printf 'allow\t%s\nallow\t%s\nallow\t%s\nblock\t%s' \
  "$T/store/tailscale-1/bin/tailscaled" "$T/store/node-1/bin/node" "$T/opt/with space/rest-server" "$T/System/ControlCenter.app")"
has "apply names what it allowed" "$out" "allow $T/store/tailscale-1/bin/tailscaled (from $T/opt/tailscale/bin/tailscaled)"
has "apply names what it blocked" "$out" "block $T/System/ControlCenter.app"

echo "== second apply: converged, silent, no writes =="
: >"$CALLS"
run "${ARGS[@]}"
check "re-apply exit 0" "$rc" 0
check "re-apply prints nothing" "$out" ""
check "re-apply mutates nothing" "$(mutations)" 0
run --check "${ARGS[@]}"
check "check exit 0 when converged" "$rc" 0
has "check reports zero drift" "$out" "drift=0 missing=0"

echo "== upgrade: the symlink moves, the old store path is gone, the service still runs it =="
printf 'allow\t/usr/bin/ruby-not-here\n' >>"$STATE"   # outside the store prefix: never pruned
mkdir -p "$T/store/tailscale-2/bin" && touch "$T/store/tailscale-2/bin/tailscaled"
ln -sfn "$T/store/tailscale-2" "$T/opt/tailscale"
rm -rf "$T/store/tailscale-1"
export RUNNING="tailscaled"   # brew upgraded, tailscaled not yet restarted
run --check "${ARGS[@]}"
check "check sees the new path only" "$rc" 1
has "check: drift=1 (old rule kept while running)" "$out" "drift=1 missing=0"
: >"$CALLS"
run "${ARGS[@]}"
check "apply after upgrade exit 0" "$rc" 0
has "new path allowed" "$(state)" "$(printf 'allow\t%s' "$T/store/tailscale-2/bin/tailscaled")"
check "old rule kept while tailscaled runs" "$(grep -c "tailscale-1" "$STATE")" 1
check "no --remove while it runs" "$(grep -c '^--remove' "$CALLS")" 0

echo "== nothing of that name runs any more: the stale rule is pruned =="
export RUNNING=""
run --check "${ARGS[@]}"
check "check sees the stale rule" "$rc" 1
has "check: drift=1 (stale)" "$out" "drift: stale rule for $T/store/tailscale-1/bin/tailscaled"
: >"$CALLS"
run "${ARGS[@]}"
check "prune exit 0" "$rc" 0
check "stale rule removed" "$(grep -c "tailscale-1" "$STATE")" 0
has "stale removal logged" "$out" "removed stale rule for $T/store/tailscale-1/bin/tailscaled"
check "rule outside the store prefixes kept" "$(grep -c "ruby-not-here" "$STATE")" 1

echo "== a rule in the wrong state is flipped, not re-added =="
awk -F'\t' -v p="$T/store/node-1/bin/node" 'BEGIN{OFS="\t"} $2==p{$1="block"} {print}' "$STATE" >"$STATE.new" && mv "$STATE.new" "$STATE"
: >"$CALLS"
run "${ARGS[@]}"
check "flip exit 0" "$rc" 0
check "flip: no --add" "$(grep -c '^--add' "$CALLS")" 0
check "flip: one --unblockapp" "$(grep -c '^--unblockapp' "$CALLS")" 1
has "node allowed again" "$(state)" "$(printf 'allow\t%s' "$T/store/node-1/bin/node")"

echo "== a missing path warns, does not fail =="
run "${ARGS[@]}" --allow "$T/opt/absent"
check "missing path: exit 0" "$rc" 0
has "missing path: warning" "$out" "warning: $T/opt/absent does not exist"
run --check "${ARGS[@]}" --allow "$T/opt/absent"
has "check counts it as missing" "$out" "drift=0 missing=1"

echo "== a rule that does not stick fails loudly =="
touch "$T/opt/broken-bin"
run "${ARGS[@]}" --allow "$T/opt/broken-bin"
check "unstuck rule: exit 1" "$rc" 1
has "unstuck rule: error" "$out" "error: could not set allow for $T/opt/broken-bin"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
