#!/usr/bin/env bash
# Coverage for the "who runs Homebrew" logic in scripts/rebuild.sh:
# setup_brew_user, brew_as_primary, homebrew_plan and replace_hand_installed
# when the configuration's system.primaryUser is NOT the invoking user (the
# owner adopting a household Mac from his own account), plus ensure_jq.
#
# Run: ./scripts/tests/rebuild-brew-user.test.sh
#
# Properties pinned:
#   - cross-user: EVERY brew command of the plan and the adoption runs as the
#     primary user (sudo -n -u <primary> -H), only after the run's one
#     authentication, and a hand-installed bundle she does not own is handed
#     to her first (otherwise Homebrew's own sudo would ask for HER password);
#   - cross-user with a prefix she does not own: stop before anything else,
#     printing the exact chown fix;
#   - same-user: `brew` stays the plain command — no sudo, no wrapper;
#   - jq missing: taken from nixpkgs instead of skipping the checks.
#
# Extracted rather than sourced: rebuild.sh executes top-to-bottom. brew, sudo,
# stat, nix, pgrep and xattr are PATH stubs, so the real dispatch is exercised.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

FNS="setup_brew_user host_flake_ref eval_primary_user brew_prefix brew_owned_dirs brew_prefix_foreign brew_as_primary
     authenticate_once ensure_jq ensure_declared_lib homebrew_plan cask_lifecycle_plan
     cask_app_targets app_bundle_modifiable declared_outdated_mas select_by_mode
     load_critical_names replace_hand_installed"
for f in $FNS; do
  body=$(sed -n "/^$f() {/,/^}/p" "$SCRIPT")
  if [[ -z "$body" ]]; then echo "FATAL: could not extract $f from $SCRIPT" >&2; exit 1; fi
  printf '%s\n' "$body" >>"$W/fns.sh"
done

ME=$(id -un)
PFX="$W/homebrew"
APPS="$W/Applications"
STUBS="$W/stubs"
mkdir -p "$PFX/bin" "$PFX/Cellar/foo/1.0" "$PFX/Caskroom" "$PFX/Library/Taps/acme/homebrew-x" \
  "$APPS/Zen.app" "$STUBS"

# ── Stubs ────────────────────────────────────────────────────────────────────
cat >"$PFX/bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew[${STUB_RUN_AS:-invoker}] cwd=$PWD auto_update=${HOMEBREW_NO_AUTO_UPDATE:-unset} $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
  "--prefix ") echo "$STUB_PFX" ;;
  "list --cask") printf '%s\n' vlc ;;
  "list --installed-on-request") : ;;
  "outdated --formula"|"outdated --cask") : ;;
  "info --cask")
    printf '{"casks":[{"token":"zen","artifacts":[{"app":["Zen.app"],"target":"%s/Zen.app"}]}]}\n' "$STUB_APPS" ;;
esac
exit 0
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
[[ "$1" == -n ]] && shift
case "$1" in
  true|-v) exit "${STUB_SUDO_RC:-0}" ;;
  -u) user="$2"; shift 2; [[ "$1" == -H ]] && shift
      exec env STUB_RUN_AS="$user" "$@" ;;
  chown) exit 0 ;;
esac
exit 0
EOF
cat >"$STUBS/stat" <<'EOF'
#!/usr/bin/env bash
# stat -f <%Su|'%Su %N'> <path>...: owner from $STUB_OWNERS ("<path> <owner>"
# lines), else $STUB_DEFAULT_OWNER
fmt="$2"; shift 2
for p in "$@"; do
  o=$(awk -v p="$p" '$1 == p {print $2}' "$STUB_OWNERS" 2>/dev/null)
  o="${o:-$STUB_DEFAULT_OWNER}"
  if [[ "$fmt" == '%Su' ]]; then echo "$o"; else echo "$o $p"; fi
done
EOF
cat >"$STUBS/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$STUB_LOG"
if [[ "$*" == *" shell nixpkgs#jq "* ]]; then
  [[ -n "${STUB_JQ_DIR:-}" ]] || exit 1
  echo "$STUB_JQ_DIR/jq"; exit 0
fi
case "$*" in
  *config.system.primaryUser*) [[ -n "${STUB_PRIMARY_FAIL:-}" ]] && exit 1; printf '%s' "$STUB_PRIMARY" ;;
  *config.homebrew.enable*) echo "${STUB_HB_ENABLE:-true}" ;;
  *config.homebrew.casks*) echo '[{"name":"zen"},{"name":"vlc"}]' ;;
  *config.homebrew.brews*) echo '[]' ;;
  *retiredCasks*|*criticalUpgrades*) echo '[]' ;;
  *) exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/xattr"
chmod +x "$PFX/bin/brew" "$STUBS"/*

# run_case <shell code> — fresh bash with the extracted functions; writes
# $W/out, $W/rc, and the stub call log $W/log.
run_case() {
  : >"$W/log"
  cat >"$W/case.sh" <<EOF
set -uo pipefail
info() { echo "[INFO] \$*"; }; warn() { echo "[WARN] \$*"; }
ok() { echo "[OK] \$*"; }; err() { echo "[ERROR] \$*" >&2; }
BOLD=; NC=
OS=Darwin
DOTFILES_DIR="$ROOT/.."
FLAKE_REF="/flake#host"
HOSTNAME=thishost
UPGRADE_MODE=all
AUTO_CONFIRM=false; FORCE_MAS=false
REBUILD_MAS_BIN=/nonexistent/mas
PLAN_TMP=""; MAS_TMP=""; SUDO_TOUCHED=false; SUDO_KEEPALIVE_PID=""
PRIMARY_USER=""; BREW_AS_PRIMARY=false; BREW_BIN=""; SUDO_AUTHENTICATED=false
DECLARED_LIB_SOURCED=false; CRITICAL_LOADED=false; CRITICAL_KNOWN=false; CRITICAL_NAMES=""
ADOPT_CASKS=""; ADOPT_APPS=""; ADOPT_BLOCKED=""; RETIRE_CASKS=""; NEW_CASKS=""
BREW_UPGRADE_FORMULAE=""; BREW_UPGRADE_CASKS=""
source "$W/fns.sh"
$1
EOF
  ( cd "$W" && env PATH="$STUBS:$PFX/bin:/usr/bin:/bin" STUB_LOG="$W/log" STUB_PFX="$PFX" \
      STUB_APPS="$APPS" STUB_OWNERS="$W/owners" STUB_DEFAULT_OWNER="${OWNER:-kassie}" \
      STUB_PRIMARY="${PRIMARY:-kassie}" STUB_PRIMARY_FAIL="${PRIMARY_FAIL:-}" \
      STUB_HB_ENABLE="${HB_ENABLE:-true}" STUB_JQ_DIR="${JQ_DIR:-}" \
      bash "$W/case.sh" >"$W/out" 2>&1 )
  echo $? >"$W/rc"
}
direct_brew() { grep -c '^brew\[invoker\]' "$W/log" || true; }
as_kassie()   { grep -c '^brew\[kassie\]' "$W/log" || true; }
: >"$W/owners"

echo ""
echo "setup_brew_user — same user"
PRIMARY="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY TYPE=$(type -t brew)"'
check "same user: rc 0" "$(cat "$W/rc")" 0
grep -q "AS=false TYPE=file" "$W/out" && good "same user: brew stays the plain command" \
  || bad "same user: brew stays the plain command" "$(cat "$W/out")"
grep -q '^sudo' "$W/log" && bad "same user: no sudo" "$(cat "$W/log")" || good "same user: no sudo"

PRIMARY_FAIL=1 run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY"'
grep -q "AS=false" "$W/out" && grep -q "Could not evaluate system.primaryUser" "$W/out" \
  && good "unevaluable primaryUser: warns, Homebrew runs as the invoker" \
  || bad "unevaluable primaryUser: warns, Homebrew runs as the invoker" "$(cat "$W/out")"

echo ""
echo "setup_brew_user — cross-user (primaryUser kassie, invoker $ME)"
run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY BIN=$BREW_BIN TYPE=$(type -t brew)"'
check "prefix owned by kassie: rc 0" "$(cat "$W/rc")" 0
grep -q "AS=true BIN=$PFX/bin/brew TYPE=function" "$W/out" && good "brew routed through brew_as_primary" \
  || bad "brew routed through brew_as_primary" "$(cat "$W/out")"


OWNER="$ME" run_case 'setup_brew_user; echo "REACHED"'
check "prefix owned by the invoker: stops (rc 1)" "$(cat "$W/rc")" 1
grep -q REACHED "$W/out" && bad "foreign prefix: nothing after the check runs" "$(cat "$W/out")" \
  || good "foreign prefix: nothing after the check runs"
grep -qF "sudo chown -R kassie:admin $PFX" "$W/out" && good "foreign prefix: prints the exact chown fix" \
  || bad "foreign prefix: prints the exact chown fix" "$(cat "$W/out")"
grep -qF "sudo -u kassie brew" "$W/out" && good "foreign prefix: explains brew for other accounts" \
  || bad "foreign prefix: explains brew for other accounts" "$(cat "$W/out")"

echo "$PFX/Caskroom $ME" >"$W/owners"
run_case 'setup_brew_user; echo "REACHED"'
check "half-chowned prefix (Caskroom foreign): stops" "$(cat "$W/rc")" 1
grep -qF "$PFX/Caskroom ($ME)" "$W/out" && good "half-chowned prefix: names the foreign directory" \
  || bad "half-chowned prefix: names the foreign directory" "$(cat "$W/out")"

echo "$PFX/Library/Taps/acme/homebrew-x rouven" >"$W/owners"
run_case 'setup_brew_user; echo "REACHED"'
check "foreign tap deep inside an otherwise-hers prefix: stops" "$(cat "$W/rc")" 1
grep -qF "$PFX/Library/Taps/acme/homebrew-x (rouven)" "$W/out" \
  && good "nested foreign path is named" || bad "nested foreign path is named" "$(cat "$W/out")"
OWNER="$ME" run_case 'setup_brew_user'
grep -q "… and [0-9]* more" "$W/out" && good "wholly foreign prefix: first 5 paths, then a count" \
  || bad "wholly foreign prefix: first 5 paths, then a count" "$(cat "$W/out")"
: >"$W/owners"

HB_ENABLE=false OWNER="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY"'
grep -q "AS=false" "$W/out" && good "homebrew.enable = false: hands off, no ownership stop" \
  || bad "homebrew.enable = false: hands off, no ownership stop" "$(cat "$W/out")"
HB_ENABLE=null run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY"'
grep -q "AS=true" "$W/out" && good "homebrew.enable unknown: still runs Homebrew as kassie (fail safe)" \
  || bad "homebrew.enable unknown: still runs Homebrew as kassie (fail safe)" "$(cat "$W/out")"
for ref in /flake '/flake#'; do
  run_case "FLAKE_REF='$ref'; setup_brew_user; echo \"AS=\$BREW_AS_PRIMARY\""
  grep -qF 'nix eval --raw /flake#darwinConfigurations."thishost".config.system.primaryUser' "$W/log" \
    && grep -q "AS=true" "$W/out" \
    && good "--flake $ref: resolves to this host, like the build" \
    || bad "--flake $ref: resolves to this host, like the build" "$(cat "$W/log" "$W/out")"
done

echo ""
echo "brew_as_primary"
run_case 'setup_brew_user >/dev/null; HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask -1'
grep -qE '^sudo -n -u kassie -H env HOMEBREW_NO_AUTO_UPDATE=1 .*/bin/brew list --cask -1$' "$W/log" \
  && good "runs: sudo -n -u kassie -H env HOMEBREW_NO_AUTO_UPDATE=1 <prefix>/bin/brew …" \
  || bad "runs: sudo -n -u kassie -H env HOMEBREW_NO_AUTO_UPDATE=1 <prefix>/bin/brew …" "$(cat "$W/log")"
grep -q 'brew\[kassie\] cwd=/ ' "$W/log" && good "runs from / (her access to the invoker's cwd is not assumed)" \
  || bad "runs from /" "$(cat "$W/log")"

echo ""
echo "homebrew_plan — cross-user"
run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "ADOPT=$ADOPT_CASKS AUTH=$SUDO_AUTHENTICATED"'
check "plan: rc 0" "$(cat "$W/rc")" 0
first_sudo=$(grep -n '^sudo' "$W/log" | head -1)
[[ "$first_sudo" == *"sudo -n true"* || "$first_sudo" == *"sudo -v"* ]] \
  && good "plan: authenticates before the first brew command" || bad "plan: authenticates first" "$(cat "$W/log")"
check "plan: no brew command runs as the invoker" "$(direct_brew)" 0
[[ "$(as_kassie)" -ge 4 ]] && good "plan: update/outdated/list/info all run as kassie ($(as_kassie))" \
  || bad "plan: brew commands run as kassie" "$(cat "$W/log")"
grep -q "ADOPT=zen AUTH=true" "$W/out" && good "plan: hand-installed Zen.app is adopted" \
  || bad "plan: hand-installed Zen.app is adopted" "$(cat "$W/out")"

echo ""
echo "homebrew_plan — same user (unchanged)"
PRIMARY="$ME" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "ADOPT=$ADOPT_CASKS AUTH=$SUDO_AUTHENTICATED"'
check "same-user plan: rc 0" "$(cat "$W/rc")" 0
grep -q '^sudo' "$W/log" && bad "same-user plan: no sudo, no authentication" "$(cat "$W/log")" \
  || good "same-user plan: no sudo, no authentication"
check "same-user plan: no brew command as another user" "$(as_kassie)" 0
[[ "$(direct_brew)" -ge 4 ]] && good "same-user plan: plain brew ($(direct_brew) calls)" \
  || bad "same-user plan: plain brew" "$(cat "$W/log")"
grep -q "ADOPT=zen AUTH=false" "$W/out" && good "same-user plan: same adoption result" \
  || bad "same-user plan: same adoption result" "$(cat "$W/out")"

echo ""
echo "replace_hand_installed"
echo "$APPS/Zen.app rouven" >"$W/owners"
run_case "setup_brew_user >/dev/null; SUDO_AUTHENTICATED=true
ADOPT_CASKS=zen; ADOPT_APPS='$APPS/Zen.app'\$'\\n'
replace_hand_installed"
grep -qF "sudo -n chown -R kassie $APPS/Zen.app" "$W/log" \
  && good "cross-user: a bundle she does not own is handed to her first" \
  || bad "cross-user: a bundle she does not own is handed to her first" "$(cat "$W/log")"
grep -q '^brew\[kassie\] .*auto_update=1 install --cask --force zen' "$W/log" \
  && good "cross-user: replaced as kassie, no auto-update" || bad "cross-user: replaced as kassie" "$(cat "$W/log")"
check "cross-user: no brew as the invoker" "$(direct_brew)" 0

echo "$APPS/Zen.app kassie" >"$W/owners"
run_case "setup_brew_user >/dev/null; ADOPT_CASKS=zen; ADOPT_APPS='$APPS/Zen.app'; replace_hand_installed"
grep -q 'chown' "$W/log" && bad "cross-user: her own bundle is not chowned" "$(cat "$W/log")" \
  || good "cross-user: her own bundle is not chowned"

echo "$APPS/Zen.app rouven" >"$W/owners"
PRIMARY="$ME" run_case "setup_brew_user >/dev/null; ADOPT_CASKS=zen; ADOPT_APPS='$APPS/Zen.app'; replace_hand_installed"
grep -q '^sudo' "$W/log" && bad "same user: no sudo, no chown" "$(cat "$W/log")" || good "same user: no sudo, no chown"
grep -q '^brew\[invoker\] .*install --cask --force zen' "$W/log" \
  && good "same user: plain brew install" || bad "same user: plain brew install" "$(cat "$W/log")"
: >"$W/owners"

echo ""
echo "every Homebrew call site goes through \`brew\`"
# The wrapper only covers calls spelled `brew …`. A `command brew` or a direct
# $BREW_BIN would bypass it on the cross-user path.
bypass=$(grep -nE 'command brew|"\$BREW_BIN"|/opt/homebrew/bin/brew' "$SCRIPT" \
  | grep -vE '^[0-9]+:\s*#|exec sudo -n -u "\$PRIMARY_USER"' || true)
check "no call site bypasses the wrapper" "$bypass" ""

echo ""
echo "ensure_jq"
mkdir -p "$W/jqbin"; printf '#!/bin/sh\nexit 0\n' >"$W/jqbin/jq"; chmod +x "$W/jqbin/jq"
NOJQ="$W/nojq"; mkdir -p "$NOJQ"
for t in bash env sh dirname cat awk grep sed id mktemp rm; do
  p=$(command -v "$t") && ln -sf "$p" "$NOJQ/$t"
done
run_jq_case() {
  : >"$W/log"
  ( env PATH="$STUBS:$NOJQ" STUB_LOG="$W/log" STUB_JQ_DIR="${1:-}" "$NOJQ/bash" -c "
      info() { echo \"[INFO] \$*\"; }; warn() { echo \"[WARN] \$*\"; }
      source '$W/fns.sh'
      ensure_jq; rc=\$?
      echo \"RC=\$rc JQ=\$(command -v jq || echo none)\"
      bash -c 'echo CHILD=\$(command -v jq || echo none)'" >"$W/out" 2>&1 )
}
run_jq_case "$W/jqbin"
grep -q "RC=0 JQ=$W/jqbin/jq" "$W/out" && good "jq missing: taken from nix shell nixpkgs#jq" \
  || bad "jq missing: taken from nix shell nixpkgs#jq" "$(cat "$W/out")"
grep -q "CHILD=$W/jqbin/jq" "$W/out" && good "jq missing: child processes (drift audit) see it" \
  || bad "jq missing: child processes see it" "$(cat "$W/out")"
run_jq_case ""
grep -q "RC=1 JQ=none" "$W/out" && grep -q "Could not get jq" "$W/out" \
  && good "nixpkgs unreachable: says so, returns 1" || bad "nixpkgs unreachable: says so" "$(cat "$W/out")"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
