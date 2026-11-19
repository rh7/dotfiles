#!/usr/bin/env bash
# Coverage for the "who runs Homebrew" logic in scripts/rebuild.sh:
# setup_brew_user, brew_as_user, homebrew_plan and replace_hand_installed
# when the configuration's homebrew.user is NOT simply the invoking user's
# own default — the owner adopting a household Mac from his own account,
# with homebrew.user = primaryUser (kassie) or = him (kassie-mbp-m1:
# homebrew.user rouven, primaryUser kassie) — plus ensure_jq.
#
# Run: ./scripts/tests/rebuild-brew-user.test.sh
#
# Properties pinned:
#   - brew user ≠ invoker: EVERY brew command of the plan and the adoption
#     runs as homebrew.user (sudo -n -u <user> -H), only after the run's one
#     authentication, and a hand-installed bundle that user does not own is
#     handed over first (otherwise Homebrew's own sudo would ask for THAT
#     user's password);
#   - brew user = invoker ≠ primaryUser: brew runs directly (no sudo -u), and
#     the prefix and the installed casks' app bundles are still checked;
#   - a prefix or a Homebrew-installed bundle the brew user does not own:
#     stop before anything else, printing the exact chown fix — apps not
#     installed by Homebrew are never listed;
#   - a plan that installs a cask while the brew user cannot write
#     /Applications stops before activation (--plan-only reports it);
#   - same-user (homebrew.user = primaryUser = you): `brew` stays the plain
#     command — no sudo, no wrapper;
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

FNS="setup_brew_user host_flake_ref eval_failed eval_user homebrew_enable_failed require_nix_features
     ask_fix nix_missing_features restart_nix_daemon nix_conf_append
     brew_prefix brew_owned_dirs brew_prefix_foreign cask_app_bundles cask_bundles_foreign brew_as_user
     brew_user_writes_applications require_applications_writable
     authenticate_once ensure_jq ensure_declared_lib homebrew_plan cask_lifecycle_plan
     cask_app_targets app_bundle_modifiable declared_outdated_mas select_by_mode
     load_critical_names replace_hand_installed
     load_daily_owned daily_owned_listed daily_owned_foreign hand_daily_owned"
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
  "outdated --formula") : ;;
  "outdated --cask") if [[ -n "${STUB_OUTDATED_CASKS:-}" ]]; then printf '%s\n' $STUB_OUTDATED_CASKS; fi ;;
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
  chown)
    shift
    if [[ -n "${STUB_CHOWN_EPERM:-}" ]]; then
      echo "chown: ${*: -1}: Operation not permitted" >&2; exit 1
    fi
    # STUB_CHOWN_APPLY: record the new owner, so a re-check sees the result.
    if [[ -n "${STUB_CHOWN_APPLY:-}" ]]; then
      while [[ "$1" == -* ]]; do shift; done
      owner="${1%%:*}"; shift
      for p in "$@"; do
        { grep -v "^$p " "$STUB_OWNERS" || true; echo "$p $owner"; } >"$STUB_OWNERS.new"
        mv "$STUB_OWNERS.new" "$STUB_OWNERS"
      done
    fi
    exit 0 ;;
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
  "config show experimental-features")
    if [[ -n "${STUB_NOCMD:-}" ]]; then
      echo "error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it" >&2
      exit 1
    fi
    echo "${STUB_FEATURES:-flakes nix-command}" ;;
  *config.system.primaryUser*)
    if [[ -n "${STUB_PRIMARY_FAIL:-}" ]]; then
      echo "error: attribute 'rouvens-new-mac' missing" >&2
      echo "       at «string»:1:1:" >&2
      exit 1
    fi
    printf '%s' "$STUB_PRIMARY" ;;
  *config.homebrew.user*) printf '%s' "${STUB_BREW_USER:-$STUB_PRIMARY}" ;;
  *config.homebrew.enable*)
    if [[ "${STUB_HB_ENABLE:-true}" == fail ]]; then echo "error: homebrew eval exploded" >&2; exit 1; fi
    echo "${STUB_HB_ENABLE:-true}" ;;
  *dailyUserOwnedCasks*) printf '%b' "${STUB_DAILY:-}" ;;
  *config.homebrew.casks*)
    casks='[{"name":"zen"},{"name":"vlc"}]'
    echo "${STUB_CASKS_JSON:-$casks}" ;;
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
AUTO_CONFIRM=false; FORCE_MAS=false; PLAN_ONLY=false; BUILD_ONLY=false; FORCE=false
# No answer file: every first-adoption question reads EOF, i.e. No (the
# accept paths are covered by rebuild-first-adoption.test.sh).
PROMPT_TTY=/dev/null
NIX_CONF="$W/nix.conf"
$(grep -E '^FLAKES_LINE=' "$SCRIPT")
REBUILD_MAS_BIN=/nonexistent/mas
PLAN_TMP=""; MAS_TMP=""; SUDO_TOUCHED=false; SUDO_KEEPALIVE_PID=""
PRIMARY_USER=""; BREW_USER=""; BREW_AS_USER=false; BREW_BIN=""; SUDO_AUTHENTICATED=false
APPLICATIONS_DIR="${APPS_DIR:-$APPS}"
DECLARED_LIB_SOURCED=false; CRITICAL_LOADED=false; CRITICAL_KNOWN=false; CRITICAL_NAMES=""
ADOPT_CASKS=""; ADOPT_APPS=""; ADOPT_BLOCKED=""; RETIRE_CASKS=""; NEW_CASKS=""
BREW_UPGRADE_FORMULAE=""; BREW_UPGRADE_CASKS=""; DAILY_OWNED=""
source "$W/fns.sh"
$1
EOF
  ( cd "$W" && env PATH="$STUBS:$PFX/bin:/usr/bin:/bin" STUB_LOG="$W/log" STUB_PFX="$PFX" \
      STUB_APPS="$APPS" STUB_OWNERS="$W/owners" STUB_DEFAULT_OWNER="${OWNER:-kassie}" \
      STUB_PRIMARY="${PRIMARY-kassie}" STUB_PRIMARY_FAIL="${PRIMARY_FAIL:-}" STUB_BREW_USER="${BREW_USER_NAME:-}" \
      STUB_HB_ENABLE="${HB_ENABLE:-true}" STUB_JQ_DIR="${JQ_DIR:-}" \
      STUB_NOCMD="${NOCMD:-}" STUB_FEATURES="${FEATURES:-}" \
      STUB_DAILY="${DAILY:-}" STUB_CASKS_JSON="${CASKS_JSON:-}" STUB_OUTDATED_CASKS="${OUTDATED_CASKS:-}" \
      STUB_CHOWN_EPERM="${CHOWN_EPERM:-}" STUB_CHOWN_APPLY="${CHOWN_APPLY:-}" \
      bash "$W/case.sh" >"$W/out" 2>&1 )
  echo $? >"$W/rc"
}
direct_brew() { grep -c '^brew\[invoker\]' "$W/log" || true; }
as_kassie()   { grep -c '^brew\[kassie\]' "$W/log" || true; }
: >"$W/owners"

echo ""
echo "setup_brew_user — same user"
PRIMARY="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_USER TYPE=$(type -t brew)"'
check "same user: rc 0" "$(cat "$W/rc")" 0
grep -q "AS=false TYPE=file" "$W/out" && good "same user: brew stays the plain command" \
  || bad "same user: brew stays the plain command" "$(cat "$W/out")"
grep -q '^sudo' "$W/log" && bad "same user: no sudo" "$(cat "$W/log")" || good "same user: no sudo"

PRIMARY_FAIL=1 run_case 'setup_brew_user; echo "REACHED"'
check "unevaluable primaryUser: fatal (rc 1)" "$(cat "$W/rc")" 1
grep -q REACHED "$W/out" && bad "unevaluable primaryUser: no fallback to the invoker" "$(cat "$W/out")" \
  || good "unevaluable primaryUser: no fallback to the invoker"
grep -q "Could not evaluate system.primaryUser" "$W/out" && grep -qF "error: attribute 'rouvens-new-mac' missing" "$W/out" \
  && good "unevaluable primaryUser: shows the nix error" \
  || bad "unevaluable primaryUser: shows the nix error" "$(cat "$W/out")"
grep -q '^brew\|^sudo' "$W/log" && bad "unevaluable primaryUser: no brew/sudo calls" "$(cat "$W/log")" \
  || good "unevaluable primaryUser: no brew/sudo calls"
PRIMARY="" run_case 'setup_brew_user; echo "REACHED"'
check "empty primaryUser: fatal (rc 1)" "$(cat "$W/rc")" 1

echo ""
echo "setup_brew_user — cross-user (primaryUser kassie, invoker $ME)"
run_case 'setup_brew_user; echo "AS=$BREW_AS_USER BIN=$BREW_BIN TYPE=$(type -t brew)"'
check "prefix owned by kassie: rc 0" "$(cat "$W/rc")" 0
grep -q "AS=true BIN=$PFX/bin/brew TYPE=function" "$W/out" && good "brew routed through brew_as_user" \
  || bad "brew routed through brew_as_user" "$(cat "$W/out")"


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

HB_ENABLE=false OWNER="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_USER"'
grep -q "AS=false" "$W/out" && good "homebrew.enable = false: hands off, no ownership stop" \
  || bad "homebrew.enable = false: hands off, no ownership stop" "$(cat "$W/out")"
for hb in null fail; do
  HB_ENABLE=$hb run_case 'setup_brew_user; echo "REACHED"'
  check "homebrew.enable $hb: fatal (rc 1)" "$(cat "$W/rc")" 1
  grep -q "Could not evaluate homebrew.enable" "$W/out" && ! grep -q REACHED "$W/out" \
    && good "homebrew.enable $hb: stops with the reason" || bad "homebrew.enable $hb: stops with the reason" "$(cat "$W/out")"
done
grep -q "homebrew eval exploded" "$W/out" && good "homebrew.enable eval error: nix error shown" \
  || bad "homebrew.enable eval error: nix error shown" "$(cat "$W/out")"

echo ""
echo "require_nix_features"
run_case 'require_nix_features; echo "PASSED"'
check "features on: rc 0" "$(cat "$W/rc")" 0
grep -q PASSED "$W/out" && good "features on: continues" || bad "features on: continues" "$(cat "$W/out")"
NOCMD=1 run_case 'require_nix_features; setup_brew_user; echo "REACHED"'
check "nix-command off: stops (rc 1)" "$(cat "$W/rc")" 1
grep -qF "echo 'extra-experimental-features = nix-command flakes' | sudo tee -a $W/nix.conf && sudo launchctl kickstart -k system/org.nixos.nix-daemon" "$W/out" \
  && good "nix-command off: prints the exact macOS fix" || bad "nix-command off: prints the exact macOS fix" "$(cat "$W/out")"
grep -q REACHED "$W/out" && bad "nix-command off: nothing after the check runs" "$(cat "$W/out")" \
  || good "nix-command off: nothing after the check runs"
grep -q '^brew\|^sudo\|nix eval' "$W/log" && bad "nix-command off: no eval, brew or sudo" "$(cat "$W/log")" \
  || good "nix-command off: no eval, brew or sudo"
FEATURES="nix-command" run_case 'require_nix_features'
check "flakes off: stops (rc 1)" "$(cat "$W/rc")" 1
grep -q "not enabled: flakes\." "$W/out" && good "flakes off: names the missing feature" \
  || bad "flakes off: names the missing feature" "$(cat "$W/out")"
FEATURES="nix-command" run_case 'OS=Linux; require_nix_features'
grep -q "systemctl restart nix-daemon" "$W/out" && good "Linux: prints the systemd fix" \
  || bad "Linux: prints the systemd fix" "$(cat "$W/out")"
for ref in /flake '/flake#'; do
  run_case "FLAKE_REF='$ref'; setup_brew_user; echo \"AS=\$BREW_AS_USER\""
  grep -qF 'nix eval --raw /flake#darwinConfigurations."thishost".config.system.primaryUser' "$W/log" \
    && grep -q "AS=true" "$W/out" \
    && good "--flake $ref: resolves to this host, like the build" \
    || bad "--flake $ref: resolves to this host, like the build" "$(cat "$W/log" "$W/out")"
done

echo ""
echo "brew_as_user"
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
grep -qF "sudo -n -u kassie test -w $APPS" "$W/log" \
  && good "plan: checks that kassie (the brew user) can write /Applications" \
  || bad "plan: checks the brew user can write /Applications" "$(cat "$W/log")"

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

has()   { if grep -qF -- "$2" "$W/out"; then good "$1"; else bad "$1" "missing [$2] in: $(cat "$W/out")"; fi; }
hasnt() { if grep -qF -- "$2" "$W/out"; then bad "$1" "unexpected [$2] in: $(cat "$W/out")"; else good "$1"; fi; }

echo ""
echo "homebrew.user ≠ primaryUser (kassie-mbp-m1: homebrew.user = you, primaryUser kassie)"
BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_USER TYPE=$(type -t brew) BU=$BREW_USER PU=$PRIMARY_USER"'
check "brew user = invoker: rc 0" "$(cat "$W/rc")" 0
has "brew user = invoker: brew runs directly (no wrapper)" "AS=false TYPE=file BU=$ME PU=kassie"
has "brew user = invoker: says so" "Homebrew runs as you"
grep -q '^sudo' "$W/log" && bad "brew user = invoker: no sudo" "$(cat "$W/log")" || good "brew user = invoker: no sudo"

BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "ADOPT=$ADOPT_CASKS AUTH=$SUDO_AUTHENTICATED"'
check "brew user = invoker, plan: rc 0" "$(cat "$W/rc")" 0
grep -q '^sudo' "$W/log" && bad "brew user = invoker, plan: no sudo, no authentication" "$(cat "$W/log")" \
  || good "brew user = invoker, plan: no sudo, no authentication"
check "brew user = invoker, plan: nothing runs as kassie" "$(as_kassie)" 0
[[ "$(direct_brew)" -ge 4 ]] && good "brew user = invoker, plan: plain brew ($(direct_brew) calls)" \
  || bad "brew user = invoker, plan: plain brew" "$(cat "$W/log")"

# The prefix is still the primary user's (before the one-time chown): checked
# although you ARE the brew user — the same-user shortcut would have skipped it.
BREW_USER_NAME="$ME" run_case 'setup_brew_user; echo REACHED'
check "prefix still kassie's: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "prefix still kassie's: nothing after the check runs" "REACHED"
has "prefix still kassie's: the chown targets the brew user" "sudo chown -R $ME:admin $PFX"
has "prefix still kassie's: other accounts run brew as the brew user" "sudo -u $ME brew"

# Homebrew-installed bundles (Caskroom links into /Applications) owned by the
# old owner are offered too; an app Homebrew did not install, or a link out
# of /Applications, never is.
mkdir -p "$PFX/Caskroom/zen/1.0" "$PFX/Caskroom/else/2.0" "$APPS/Other.app" "$W/elsewhere/Else.app"
ln -s "$APPS/Zen.app" "$PFX/Caskroom/zen/1.0/Zen.app"
ln -s "$W/elsewhere/Else.app" "$PFX/Caskroom/else/2.0/Else.app"
printf '%s kassie\n' "$APPS/Zen.app" "$APPS/Other.app" "$W/elsewhere/Else.app" >"$W/owners"
BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
check "installed cask bundle not the brew user's: stops (rc 1)" "$(cat "$W/rc")" 1
has "installed cask bundle: listed with its owner" "$APPS/Zen.app (kassie)"
has "installed cask bundle: exact chown printed" "sudo chown -R $ME '$APPS/Zen.app'"
hasnt "installed cask bundle: a prefix that is already the brew user's is not offered" "$ME:admin"
hasnt "an app Homebrew did not install is never listed" "Other.app"
hasnt "a Caskroom link outside /Applications is never listed" "Else.app"
grep -q chown "$W/log" && bad "declined (no answer): nothing chowned" "$(cat "$W/log")" \
  || good "declined (no answer): nothing chowned"
mkdir -p "$APPS/Zen.app/Contents"
printf '%s root\n' "$APPS/Zen.app/Contents" >"$W/owners"
BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
has "a foreign path INSIDE an installed bundle counts" "$APPS/Zen.app (root)"
PLAN_SETUP='PLAN_ONLY=true; setup_brew_user; echo "REACHED AS=$BREW_AS_USER"'
BREW_USER_NAME="$ME" OWNER="$ME" run_case "$PLAN_SETUP"
has "--plan-only: reports it as will fix and goes on" "will fix: rebuild.sh offers this chown"
has "--plan-only: continues" "REACHED AS=false"
rm -rf "$PFX/Caskroom/zen" "$PFX/Caskroom/else" "$APPS/Other.app" "$APPS/Zen.app/Contents" "$W/elsewhere"
: >"$W/owners"

echo ""
echo "homebrew.user ≠ primaryUser ≠ invoker"
BREW_USER_NAME=maint OWNER=maint run_case 'setup_brew_user >/dev/null; HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask -1; echo "AS=$BREW_AS_USER"'
has "brew routed through brew_as_user" "AS=true"
grep -qE '^sudo -n -u maint -H env HOMEBREW_NO_AUTO_UPDATE=1 .*/bin/brew list --cask -1$' "$W/log" \
  && good "runs as the brew user, not as the primary user" || bad "runs as the brew user" "$(cat "$W/log")"
check "nothing runs as the primary user" "$(as_kassie)" 0
echo "$APPS/Zen.app kassie" >"$W/owners"
BREW_USER_NAME=maint OWNER=maint run_case "setup_brew_user >/dev/null; ADOPT_CASKS=zen; ADOPT_APPS='$APPS/Zen.app'; replace_hand_installed"
grep -qF "sudo -n chown -R maint $APPS/Zen.app" "$W/log" \
  && good "a hand-installed bundle is handed to the brew user, not the primary user" \
  || bad "a hand-installed bundle is handed to the brew user" "$(cat "$W/log")"
echo "$APPS/Zen.app kassie" >"$W/owners"
BREW_USER_NAME="$ME" OWNER="$ME" run_case "setup_brew_user >/dev/null; SUDO_AUTHENTICATED=true; ADOPT_CASKS=zen; ADOPT_APPS='$APPS/Zen.app'; replace_hand_installed"
grep -qF "sudo -n chown -R $ME $APPS/Zen.app" "$W/log" \
  && good "brew user = invoker: her hand-installed bundle is handed to you first" \
  || bad "brew user = invoker: her bundle is handed to you first" "$(cat "$W/log")"
grep -q '^brew\[invoker\] .*install --cask --force zen' "$W/log" \
  && good "brew user = invoker: replaced with plain brew" || bad "brew user = invoker: plain brew install" "$(cat "$W/log")"
: >"$W/owners"

echo ""
echo "require_applications_writable — a non-admin brew user stops before activation"
mv "$APPS/Zen.app" "$W/Zen.app.away"   # zen becomes a NEW install, not an adoption
APPS_DIR="$W/ro-apps" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo REACHED'
check "cross-user, kassie cannot write /Applications: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "cross-user: nothing after the plan runs (no confirmation, no activation)" "REACHED"
has "names who and why" "Homebrew runs as 'kassie', who cannot write $W/ro-apps (not an admin)"
has "names the casks" "Installing zen would make Homebrew fall back to its own sudo"
has "names the fix" "set homebrew.user in this host's configuration to an admin account"
grep -qF "sudo -n -u kassie test -w $W/ro-apps" "$W/log" && good "asked as the brew user (sudo -n -u kassie test -w)" \
  || bad "asked as the brew user" "$(cat "$W/log")"
APPS_DIR="$W/ro-apps" PRIMARY="$ME" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo REACHED'
check "same user, cannot write /Applications: stops (rc 1)" "$(cat "$W/rc")" 1
has "same user: names who" "Homebrew runs as '$ME', who cannot write"
APPS_DIR="$W/ro-apps" run_case 'PLAN_ONLY=true; setup_brew_user >/dev/null; homebrew_plan; echo REACHED'
check "--plan-only: reports it, rc 0" "$(cat "$W/rc")" 0
has "--plan-only: says a full run stops" "A full run stops here, before activation."
run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "REACHED NEW=$NEW_CASKS"'
has "writable /Applications: the install goes ahead" "REACHED NEW=zen"
mv "$W/Zen.app.away" "$APPS/Zen.app"

echo ""
echo "dotfiles.homebrew.dailyUserOwnedCasks (kassie-mbp-m1: claude → Claude.app, kassie's)"
# Brew user = you, primaryUser kassie. Claude (listed) self-updates as kassie
# and must stay hers; Zen (not listed) is still offered to the brew user.
mkdir -p "$PFX/Caskroom/zen/1.0" "$PFX/Caskroom/claude/2.0" "$APPS/Claude.app"
ln -s "$APPS/Zen.app" "$PFX/Caskroom/zen/1.0/Zen.app"
ln -s "$APPS/Claude.app" "$PFX/Caskroom/claude/2.0/Claude.app"
DAILY_CLAUDE='claude\tClaude.app\n'
printf '%s kassie\n' "$APPS/Zen.app" "$APPS/Claude.app" >"$W/owners"
DAILY="$DAILY_CLAUDE" BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
check "unlisted Zen.app not the brew user's: still stops (rc 1)" "$(cat "$W/rc")" 1
has "unlisted cask bundle: still offered to the brew user" "sudo chown -R $ME '$APPS/Zen.app'"
hasnt "listed Claude.app (kassie's): never offered to the brew user" "chown -R $ME '$APPS/Claude.app'"
hasnt "listed Claude.app (kassie's): not reported at all" "Claude.app"

DAILY="" BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
has "control — the same Claude.app UNlisted is offered to the brew user" "sudo chown -R $ME '$APPS/Claude.app'"

# Listed bundle owned by the brew user (as Homebrew installed it): offered to
# kassie; declining that alone does not stop the build.
printf '%s %s\n' "$APPS/Zen.app" "$ME" "$APPS/Claude.app" "$ME" >"$W/owners"
DAILY="$DAILY_CLAUDE" BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo "REACHED AS=$BREW_AS_USER"'
check "listed bundle the brew user's, declined: build goes on (rc 0)" "$(cat "$W/rc")" 0
has "listed bundle: reported with its owner" "$APPS/Claude.app ($ME)"
has "listed bundle: offered to kassie" "self-updating app bundle(s) to kassie (chown -R kassie:staff)"
has "declined: prints the Terminal fix" "sudo chown -R kassie:staff '$APPS/Claude.app'"
has "declined: continues" "REACHED AS=false"
hasnt "listed bundle: never offered to the brew user" "chown -R $ME '$APPS/Claude.app'"
grep -q chown "$W/log" && bad "declined: nothing chowned" "$(cat "$W/log")" || good "declined: nothing chowned"

echo "y" >"$W/yes"
DAILY="$DAILY_CLAUDE" CHOWN_APPLY=1 BREW_USER_NAME="$ME" OWNER="$ME" \
  run_case "PROMPT_TTY='$W/yes'; setup_brew_user; echo REACHED"
check "accepted: rc 0" "$(cat "$W/rc")" 0
grep -qF "sudo -n chown -R -h kassie:staff $APPS/Claude.app" "$W/log" \
  && good "accepted: chown -R -h kassie:staff, inside the run's authentication" \
  || bad "accepted: chown -R -h kassie:staff" "$(cat "$W/log")"
has "accepted: confirmed" "$APPS/Claude.app now belongs to kassie"
hasnt "accepted: nothing left over" "Still not kassie's"

printf '%s %s\n' "$APPS/Zen.app" "$ME" "$APPS/Claude.app" "$ME" >"$W/owners"
DAILY="$DAILY_CLAUDE" CHOWN_EPERM=1 BREW_USER_NAME="$ME" OWNER="$ME" \
  run_case "PROMPT_TTY='$W/yes'; setup_brew_user; echo REACHED"
check "App Management EPERM (over SSH): not fatal (rc 0)" "$(cat "$W/rc")" 0
has "EPERM: names App Management" "macOS App Management blocked chown of $APPS/Claude.app"
has "EPERM: prints the command to run in Terminal" "sudo chown -R kassie:staff '$APPS/Claude.app'"
has "EPERM: the build goes on" "REACHED"

# Mixed: an unlisted foreign bundle AND a listed one, declined → stops, and
# both fixes are printed.
printf '%s kassie\n%s %s\n' "$APPS/Zen.app" "$APPS/Claude.app" "$ME" >"$W/owners"
DAILY="$DAILY_CLAUDE" BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
check "brew-user bundle + listed bundle, declined: stops (rc 1)" "$(cat "$W/rc")" 1
has "mixed: brew-user fix" "sudo chown -R $ME '$APPS/Zen.app'"
has "mixed: daily-user fix" "sudo chown -R kassie:staff '$APPS/Claude.app'"
has "mixed: one question covers both" "Hand Homebrew to $ME now (the 1 app bundle(s) above), and the 1 self-updating app bundle(s) to kassie"

# Never upgraded by Homebrew, even when `brew outdated` lists it (greedy).
printf '%s %s\n' "$APPS/Zen.app" "$ME" "$APPS/Claude.app" kassie >"$W/owners"
DAILY="$DAILY_CLAUDE" CASKS_JSON='[{"name":"zen"},{"name":"claude"}]' OUTDATED_CASKS="zen claude" \
  BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "UPGRADE=[$BREW_UPGRADE_CASKS]"'
has "--upgrade=all: an unlisted outdated cask is upgraded" "UPGRADE=[zen]"
has "--upgrade=all: the plan says why claude is not" "they update themselves as kassie"
printf '%s %s\n' "$APPS/Zen.app" "$ME" "$APPS/Claude.app" "$ME" >"$W/owners"
DAILY="" CASKS_JSON='[{"name":"zen"},{"name":"claude"}]' OUTDATED_CASKS="zen claude" \
  BREW_USER_NAME="$ME" OWNER="$ME" run_case 'setup_brew_user >/dev/null; homebrew_plan; echo "UPGRADE=[$BREW_UPGRADE_CASKS]"'
has "control — unlisted, claude would be upgraded" "UPGRADE=[claude zen]"
rm -rf "$PFX/Caskroom/zen" "$PFX/Caskroom/claude" "$APPS/Claude.app"
: >"$W/owners"

echo ""
echo "every Homebrew call site goes through \`brew\`"
# The wrapper only covers calls spelled `brew …`. A `command brew` or a direct
# $BREW_BIN would bypass it on the cross-user path.
bypass=$(grep -nE 'command brew|"\$BREW_BIN"|/opt/homebrew/bin/brew' "$SCRIPT" \
  | grep -vE '^[0-9]+:\s*#|exec sudo -n -u "\$BREW_USER"' || true)
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
