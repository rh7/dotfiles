#!/usr/bin/env bash
# Coverage for scripts/audit-config-drift.sh itself (rebuild.sh's drift gate
# is covered by rebuild-drift-audit.test.sh).
#
# WHY THIS EXISTS: on kassie-mbp-m1's first adoption the audit died with
# "line 301: tailscale: unbound variable". The cause was not the host (it
# declares no tailscale cask) but the shell: with no Nix bash on PATH,
# `#!/usr/bin/env bash` is macOS's /bin/bash 3.2, which has no `declare -A` —
# the `[tailscale-app]=` subscript was evaluated as arithmetic. Bash then
# exited 1, the "drift found" code, without a DRIFT_RESULT line.
#
# Pinned:
#   - a full audit of a host fixture WITHOUT tailscale completes (summary
#     line, exit 0/1) under every bash available — /bin/bash 3.2 on a Mac;
#   - no bash-4-only construct (associative arrays) in the audit or rebuild.sh,
#     so a Linux runner (bash 5) still catches a regression;
#   - a crash mid-audit exits 2 (error), never 1 (drift).
#
# Run: bash scripts/tests/audit-config-drift.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="$ROOT/scripts/audit-config-drift.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

mkdir -p "$W/stubs" "$W/crash"
cat >"$W/stubs/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
# Host fixture: firefox + zoom (a .pkg cask from the override table), NO tailscale.
cat >"$W/stubs/nix" <<'EOF'
#!/bin/sh
case "$*" in
  *config.system.primaryUser*) echo '"kassie"' ;;
  *config.homebrew.casks*) echo '[{"name":"firefox"},{"name":"zoom"}]' ;;
  *config.homebrew.onActivation.cleanup*) echo '"none"' ;;
  *retiredCasks*) echo '[]' ;;
  *postActivation.text*) echo '""' ;;
  *) echo null ;;
esac
EOF
cat >"$W/stubs/brew" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "list --cask") printf 'firefox\nzoom\n' ;;
  "info --cask") printf '==> Artifacts\nFirefox.app (App)\n' ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$W/stubs/mas"
cat >"$W/stubs/defaults" <<'EOF'
#!/bin/sh
# `defaults read com.apple.dock persistent-apps` as on a real Mac; any other key unset.
if [ "$*" = "read com.apple.dock persistent-apps" ]; then
  printf '(\n    {\n        "tile-data" = {\n            "file-data" = {\n                "_CFURLString" = "file:///Applications/Safari.app/";\n            };\n        };\n    }\n)\n'
  exit 0
fi
exit 1
EOF
# Crash injection: any `comm` fails, killing the audit under set -e.
printf '#!/bin/sh\nexit 3\n' >"$W/crash/comm"
chmod +x "$W/stubs"/* "$W/crash"/*

# run_audit <bash> [extra PATH dir] — writes $W/out, $W/rc
run_audit() {
  local sh="$1" extra="${2:-}"
  ( env PATH="${extra:+$extra:}$W/stubs:/usr/bin:/bin" HOME="$W" XDG_CACHE_HOME="$W/cache" \
      DOTFILES="$W/flake" "$sh" "$AUDIT" kassie-mbp-m1 >"$W/out" 2>&1 )
  echo $? >"$W/rc"
}

shells=()
for sh in "$(command -v bash)" /bin/bash; do
  [[ -x "$sh" ]] || continue
  case " ${shells[*]-} " in *" $sh "*) continue ;; esac
  shells+=("$sh")
done

for sh in "${shells[@]}"; do
  ver=$("$sh" -c 'echo $BASH_VERSION')
  echo ""
  echo "audit under $sh ($ver), host without tailscale"
  run_audit "$sh"
  rc=$(cat "$W/rc")
  [[ "$rc" == 0 || "$rc" == 1 ]] && good "completes (exit $rc)" || bad "completes" "exit $rc: $(cat "$W/out")"
  grep -q '^DRIFT_RESULT: risky=[0-9]* benign=[0-9]* informational=[0-9]*$' "$W/out" \
    && good "prints the DRIFT_RESULT summary" || bad "prints the DRIFT_RESULT summary" "$(cat "$W/out")"
  grep -q 'unbound variable' "$W/out" && bad "no unbound variable" "$(grep 'unbound' "$W/out")" \
    || good "no unbound variable"
  grep -q 'all casks match' "$W/out" && good "cask section ran to the end" || bad "cask section ran" "$(cat "$W/out")"

  run_audit "$sh" "$W/crash"
  rc=$(cat "$W/rc")
  [[ "$rc" == 2 ]] && good "a crash mid-audit exits 2 (error), not 1 (drift)" \
    || bad "a crash mid-audit exits 2" "exit $rc: $(cat "$W/out")"
  grep -q 'aborted before completing' "$W/out" && good "a crash says the drift is unknown" \
    || bad "a crash says the drift is unknown" "$(cat "$W/out")"
  grep -q '^DRIFT_RESULT:' "$W/out" && bad "a crash prints no summary" "$(cat "$W/out")" \
    || good "a crash prints no summary"
done

# kassie-mbp-m1, run by rouven, Homebrew owned by kassie: the cask section was
# right but /Applications listed 25 declared, brew-installed apps as
# unmanaged. `brew list` (a bash fast path) works from any account; `brew
# info` (Ruby) here only as the owner — so the stub fails it unless sudo -u
# kassie ran it. rebuild.sh hands the owner's invocation over as BREW_CMD.
mkdir -p "$W/xuser" "$W/apps/Firefox.app" "$W/apps/Stray.app"
cat >"$W/xuser/brew" <<'EOF'
#!/bin/sh
echo "brew[${STUB_AS_USER:-invoker}] $*" >>"$STUB_LOG"
case "$1 $2" in
  "list --cask") printf 'firefox\nzoom\n' ;;
  "info --cask")
    [ "${STUB_AS_USER:-}" = kassie ] || { echo "Error: Permission denied @ rb_sysopen" >&2; exit 1; }
    case "$3" in firefox) printf '==> Artifacts\nFirefox.app (App)\n' ;; *) printf '==> Artifacts\n' ;; esac ;;
esac
EOF
cat >"$W/xuser/sudo" <<'EOF'
#!/bin/sh
# sudo -n -u <user> -H <cmd…> → <cmd…> as <user>
user=""
while [ $# -gt 0 ]; do
  case "$1" in -n|-H) shift ;; -u) user="$2"; shift 2 ;; *) break ;; esac
done
STUB_AS_USER="$user" exec "$@"
EOF
chmod +x "$W/xuser"/*
run_xuser() { # run_xuser <bash> [BREW_CMD]
  : >"$W/xlog"
  ( env PATH="$W/xuser:$W/stubs:/usr/bin:/bin" HOME="$W" XDG_CACHE_HOME="$W/cache" \
      DOTFILES="$W/flake" DRIFT_APPS_DIR="$W/apps" STUB_LOG="$W/xlog" BREW_CMD="${2:-}" \
      "$1" "$AUDIT" kassie-mbp-m1 >"$W/out" 2>&1 )
}
for sh in "${shells[@]}"; do
  echo ""
  echo "Homebrew owned by another account ($sh)"
  run_xuser "$sh"
  grep -q 'Firefox.app (unmanaged' "$W/out" && good "reproduced: as the invoker, a declared app reads as unmanaged" \
    || bad "reproduced: as the invoker, a declared app reads as unmanaged" "$(cat "$W/out")"
  grep -q 'brew info failed for: firefox zoom' "$W/out" && good "as the invoker: the failed lookup is reported" \
    || bad "as the invoker: the failed lookup is reported" "$(cat "$W/out")"

  run_xuser "$sh" "sudo -n -u kassie -H brew"
  grep -q 'Firefox.app' "$W/out" && bad "BREW_CMD: a declared app is not unmanaged" "$(cat "$W/out")" \
    || good "BREW_CMD: a declared app is not unmanaged"
  grep -q 'Stray.app (unmanaged' "$W/out" && good "BREW_CMD: an undeclared app still is" \
    || bad "BREW_CMD: an undeclared app still is" "$(cat "$W/out")"
  grep -q 'brew info failed' "$W/out" && bad "BREW_CMD: no failed lookups" "$(cat "$W/out")" \
    || good "BREW_CMD: no failed lookups"
  grep -q 'all casks match' "$W/out" && good "BREW_CMD: cask section unchanged" || bad "BREW_CMD: cask section" "$(cat "$W/out")"
  n=$(grep -c '^brew\[invoker\]' "$W/xlog" || true)
  [[ "$n" == 0 ]] && good "BREW_CMD: every brew call (list and info) ran as kassie" \
    || bad "BREW_CMD: every brew call ran as kassie" "$(cat "$W/xlog")"
done

echo ""
echo "bash 3.2 compatibility (static)"
# The scripts a household Mac runs before nix-darwin puts a newer bash on PATH.
hits=$(grep -nE '^[[:space:]]*(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A' \
  "$AUDIT" "$ROOT/scripts/rebuild.sh" || true)
[[ -z "$hits" ]] && good "no associative arrays in audit-config-drift.sh / rebuild.sh" \
  || bad "no associative arrays (bash 4+) in audit-config-drift.sh / rebuild.sh" "$hits"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
