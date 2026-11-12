#!/usr/bin/env bash
# Coverage for rebuild.sh's first-adoption preflight: the three things a
# freshly-Nix-installed Mac reliably has wrong, which rebuild.sh now fixes
# after ONE question each (default No), inside the run's one authentication:
#
#   1. nix-command/flakes off      → append to nix.conf, restart nix-daemon
#   2. Homebrew prefix not the
#      primary user's (cross-user) → chown -R <primary>:admin <prefix>
#   3. /etc shell files nix-darwin's activation check would reject
#                                  → stock + Nix installer block: move to
#                                    *.before-nix-darwin (after the switch is
#                                    confirmed, before any app is replaced);
#                                    anything else: stop with the diff.
#
# --plan-only reports all three and changes nothing.
#
# Run: ./scripts/tests/rebuild-first-adoption.test.sh
#
# Extracted rather than sourced (rebuild.sh executes top-to-bottom). sudo, nix,
# stat and brew are PATH stubs; /etc, nix.conf and the Homebrew prefix live in
# a temp root (ETC_DIR, NIX_CONF, the stub brew's location); answers come from
# a file standing in for the terminal (PROMPT_TTY).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()   { if grep -qF -- "$2" "$W/out"; then good "$1"; else bad "$1" "missing [$2] in: $(cat "$W/out")"; fi; }
hasnt() { if grep -qF -- "$2" "$W/out"; then bad "$1" "unexpected [$2] in: $(cat "$W/out")"; else good "$1"; fi; }
logged()    { if grep -qF -- "$2" "$W/log"; then good "$1"; else bad "$1" "not in call log: [$2] — log: $(cat "$W/log")"; fi; }
notlogged() { if grep -qE -- "$2" "$W/log"; then bad "$1" "call log matched /$2/: $(cat "$W/log")"; else good "$1"; fi; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

FNS="ask_fix nix_missing_features restart_nix_daemon nix_conf_append require_nix_features
     authenticate_once host_flake_ref eval_failed eval_primary_user homebrew_enable_failed
     ensure_declared_lib brew_prefix brew_owned_dirs brew_prefix_foreign brew_as_primary setup_brew_user
     etc_managed_targets sha256_of nix_block_stripped etc_stock_with_nix_block etc_body
     etc_unexpected_lines etc_restore_hint etc_preflight etc_apply_renames"
for f in $FNS; do
  # one-line definitions (`f() { …; }`) first: a range would run on to the
  # NEXT function's closing brace
  body=$(grep -E "^$f\(\) \{.*\}$" "$SCRIPT")
  [[ -n "$body" ]] || body=$(sed -n "/^$f() {/,/^}/p" "$SCRIPT")
  if [[ -z "$body" ]]; then echo "FATAL: could not extract $f from $SCRIPT" >&2; exit 1; fi
  printf '%s\n' "$body" >>"$W/fns.sh"
done

ME=$(id -un)
PFX="$W/homebrew"
ETC="$W/etc"
STUBS="$W/stubs"
mkdir -p "$PFX/bin" "$PFX/Cellar/foo/1.0" "$STUBS"

# ── Stubs ────────────────────────────────────────────────────────────────────
cat >"$PFX/bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew[${STUB_RUN_AS:-invoker}] $*" >>"$STUB_LOG"
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
[[ "$1" == -n ]] && shift
case "$1" in
  true|-v) exit 0 ;;
  -u) user="$2"; shift 2; [[ "$1" == -H ]] && shift
      exec env STUB_RUN_AS="$user" "$@" ;;
  chown) # chown -R <user>:<group> <dirs>: every path is now <user>'s
      [[ -n "${STUB_CHOWN_NOOP:-}" ]] || echo "${3%%:*}" >"$STUB_CHOWNED"; exit 0 ;;
  launchctl|systemctl) exit 0 ;;
  mv)  [[ -z "${STUB_MV_FAIL:-}" ]] || exit 1; shift; exec mv "$@" ;;
  tee) shift; exec tee "$@" ;;
esac
exit 0
EOF
cat >"$STUBS/stat" <<'EOF'
#!/usr/bin/env bash
# stat -f <fmt> <path>...: owner = chowned user, else $STUB_DEFAULT_OWNER
fmt="$2"; shift 2
o="$STUB_DEFAULT_OWNER"
[[ -s "$STUB_CHOWNED" ]] && o=$(cat "$STUB_CHOWNED")
for p in "$@"; do
  case "$fmt" in '%Su') echo "$o" ;; '%HT') echo "Directory" ;; *) echo "$o $p" ;; esac
done
EOF
cat >"$STUBS/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$STUB_LOG"
case "$*" in
  "config show experimental-features")
    if grep -qE '^(extra-)?experimental-features = .*nix-command flakes' "$STUB_NIX_CONF" 2>/dev/null \
       || [[ "${NIX_CONFIG:-}" == *"nix-command flakes"* ]]; then
      echo "flakes nix-command"; exit 0
    fi
    echo "error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it" >&2
    exit 1 ;;
  *config.system.primaryUser*) printf '%s' "$STUB_PRIMARY" ;;
  *config.homebrew.enable*) echo true ;;
  *config.environment.etc*)
    if [[ -n "${STUB_ETC_FAIL:-}" ]]; then echo "error: etc eval exploded" >&2; exit 1; fi
    cat "$STUB_ETC_TARGETS" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PFX/bin/brew" "$STUBS"/*

# ── /etc fixtures ────────────────────────────────────────────────────────────
STOCK_BASHRC='# System-wide .bashrc file for interactive bash(1) shells.
if [ -z "$PS1" ]; then
   return
fi

PS1='"'"'\h:\W \u\$ '"'"'
shopt -s checkwinsize
'
STOCK_ZSHRC='# System-wide profile for interactive zsh(1) shells.
HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
PS1="%n@%m %1~ %# "
'
# Exactly the block the official installer writes.
NIX_BLOCK="# Nix
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
fi
# End Nix
"
sum() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
# nix-darwin's knownSha256Hashes: the stock files (plus an unrelated hash).
printf 'bashrc\t%s 0000\nzshrc\t%s\nzshenv\t\nssh/sshd_config.d/100-nix-darwin.conf\t\n' \
  "$(sum "$STOCK_BASHRC")" "$(sum "$STOCK_ZSHRC")" >"$W/targets"

# fixture <bashrc content> <zshrc content> — fresh /etc, nix.conf, owners
fixture() {
  rm -rf "$ETC" "$W/chowned" "$W/answer"
  mkdir -p "$ETC/nix"
  printf '%s' "$1" >"$ETC/bashrc"
  printf '%s' "$2" >"$ETC/zshrc"
  printf 'build-users-group = nixbld\n' >"$ETC/nix/nix.conf"
}
prepended() { printf '\n%s\n%s' "$NIX_BLOCK" "$1"; }   # current installer
appended()  { printf '%s\n%s' "$1" "$NIX_BLOCK"; }      # older installer
answer() { printf '%s\n' "$1" >"$W/answer"; }

# run_case <shell code> — fresh bash with the extracted functions; writes
# $W/out, $W/rc and the stub call log $W/log.
run_case() {
  : >"$W/log"
  cat >"$W/case.sh" <<EOF
set -euo pipefail
info() { echo "[INFO] \$*"; }; warn() { echo "[WARN] \$*"; }
ok() { echo "[OK] \$*"; }; err() { echo "[ERROR] \$*" >&2; }
BOLD=; NC=
OS=Darwin
DOTFILES_DIR="$ROOT/.."
FLAKE_REF="/flake#host"
HOSTNAME=thishost
AUTO_CONFIRM=${YES:-false}; PLAN_ONLY=${PLAN:-false}; BUILD_ONLY=false; FORCE=${FORCE:-false}
PROMPT_TTY="$( [[ -f "$W/answer" ]] && echo "$W/answer" || echo /dev/null )"
NIX_CONF="$ETC/nix/nix.conf"
ETC_DIR="$ETC"
$(grep -E '^FLAKES_LINE=' "$SCRIPT")
SUDO_TOUCHED=false; SUDO_KEEPALIVE_PID=""; SUDO_AUTHENTICATED=false
PRIMARY_USER=""; BREW_AS_PRIMARY=false; BREW_BIN=""; DECLARED_LIB_SOURCED=false
ETC_RENAMES=""; ETC_RENAMED=""; ETC_MATCH_EB=0; ETC_MATCH_EA=0
source "$W/fns.sh"
$1
EOF
  ( cd "$W" && env PATH="$STUBS:$PFX/bin:/usr/bin:/bin" STUB_LOG="$W/log" \
      STUB_NIX_CONF="$ETC/nix/nix.conf" STUB_PRIMARY="${PRIMARY-kassie}" \
      STUB_DEFAULT_OWNER="${OWNER:-kassie}" STUB_CHOWNED="$W/chowned" \
      STUB_CHOWN_NOOP="${CHOWN_NOOP:-}" STUB_MV_FAIL="${MV_FAIL:-}" \
      STUB_ETC_TARGETS="$W/targets" STUB_ETC_FAIL="${ETC_FAIL:-}" \
      bash "$W/case.sh" >"$W/out" 2>&1 )
  echo $? >"$W/rc"
  # keep the kill-on-exit keep-alive of authenticate_once from outliving a case
  pkill -f "$W/case.sh" 2>/dev/null || true
}
FLAKES_ON="extra-experimental-features = nix-command flakes"
features_on() { printf '%s\n' "$FLAKES_ON" >>"$ETC/nix/nix.conf"; }
nixconf() { cat "$ETC/nix/nix.conf"; }

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "1. flakes disabled"
fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; answer y
run_case 'require_nix_features; echo "REACHED SUDO_AUTH=$SUDO_AUTHENTICATED"'
check "accept: continues (rc 0)" "$(cat "$W/rc")" 0
has "accept: run continues after the fix" "REACHED SUDO_AUTH=true"
check "accept: line appended exactly once" "$(grep -cx "$FLAKES_ON" "$ETC/nix/nix.conf")" 1
check "accept: existing nix.conf content kept" "$(head -1 "$ETC/nix/nix.conf")" "build-users-group = nixbld"
logged "accept: written as root (sudo -n tee -a)" "sudo -n tee -a $ETC/nix/nix.conf"
logged "accept: nix-daemon restarted" "sudo -n launchctl kickstart -k system/org.nixos.nix-daemon"
has "accept: re-checked and confirmed" "nix-command and flakes enabled"
has "accept: one question, default No" "Enable them now? [y/N]"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; printf 'build-users-group = nixbld' >"$ETC/nix/nix.conf"; answer y
run_case 'require_nix_features'
check "accept, no trailing newline: appended on its own line" "$(nixconf)" \
  "build-users-group = nixbld
$FLAKES_ON"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; answer n
before=$(nixconf)
run_case 'require_nix_features; echo REACHED'
check "decline: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "decline: nothing after the check runs" "REACHED"
check "decline: nix.conf unchanged" "$(nixconf)" "$before"
notlogged "decline: no sudo at all" '^sudo'
has "decline: prints the exact manual fix" \
  "echo 'extra-experimental-features = nix-command flakes' | sudo tee -a $ETC/nix/nix.conf && sudo launchctl kickstart -k system/org.nixos.nix-daemon"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; rm -f "$W/answer"
run_case 'require_nix_features'
check "no terminal answer reads as No (rc 1)" "$(cat "$W/rc")" 1

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; answer y
YES=true run_case 'require_nix_features'
check "--yes does not answer it (rc 1)" "$(cat "$W/rc")" 1
has "--yes: says so" "--yes does not answer this question"
notlogged "--yes: no sudo" '^sudo'

# An existing `experimental-features` list (here or via !include) is ADDED
# to, never replaced: the appended key is extra-experimental-features.
fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; printf 'experimental-features = ca-derivations\n' >>"$ETC/nix/nix.conf"; answer y
run_case 'require_nix_features'
check "existing experimental-features list: accepted (rc 0)" "$(cat "$W/rc")" 0
check "existing experimental-features list: kept, extra- line added after it" "$(tail -2 "$ETC/nix/nix.conf")" \
  "experimental-features = ca-derivations
$FLAKES_ON"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; printf 'extra-experimental-features = ca-derivations\n' >>"$ETC/nix/nix.conf"; answer y
before=$(nixconf)
run_case 'require_nix_features'
check "extra- key already set: stops (rc 1)" "$(cat "$W/rc")" 1
check "extra- key already set: no second line appended" "$(nixconf)" "$before"
hasnt "extra- key already set: no question asked" "[y/N]"
has "extra- key already set: says why" "already sets extra-experimental-features"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Homebrew prefix not owned by the primary user (cross-user)"
fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; features_on; answer y
OWNER="$ME" run_case 'setup_brew_user; echo "AS=$BREW_AS_PRIMARY AUTH=$SUDO_AUTHENTICATED"'
check "accept: continues (rc 0)" "$(cat "$W/rc")" 0
has "accept: shows the owner and the offending-path count" "path(s) under $PFX belong to $ME"
has "accept: explains the consequence for other accounts" "sudo -u kassie brew …"
logged "accept: chown as root inside the authentication" "sudo -n chown -R kassie:admin $PFX"
has "accept: brew then runs as kassie" "AS=true AUTH=true"
first_sudo=$(grep -n '^sudo' "$W/log" | head -1)
[[ "$first_sudo" == *"sudo -n true"* || "$first_sudo" == *"sudo -v"* ]] \
  && good "accept: authenticates before the chown" || bad "accept: authenticates before the chown" "$(cat "$W/log")"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; features_on; answer n
OWNER="$ME" run_case 'setup_brew_user; echo REACHED'
check "decline: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "decline: nothing after the check runs" "REACHED"
notlogged "decline: no chown" 'chown'
has "decline: prints the exact chown" "sudo chown -R kassie:admin $PFX"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; features_on; answer y
OWNER="$ME" CHOWN_NOOP=1 run_case 'setup_brew_user; echo REACHED'
check "chown did not take: stops (rc 1)" "$(cat "$W/rc")" 1
has "chown did not take: re-checked, says so" "Still not owned by kassie"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "3. /etc files nix-darwin would reject"
fixture "$(prepended "$STOCK_BASHRC")" "$(prepended "$STOCK_ZSHRC")"; answer y
run_case 'etc_preflight; echo "RENAMES=$(cut -f1 <<<"$ETC_RENAMES" | xargs)"'
check "stock + installer block: accepted (rc 0)" "$(cat "$W/rc")" 0
has "stock + installer block: both files queued" "RENAMES=$ETC/bashrc $ETC/zshrc"
has "stock + installer block: diff summary shows the block" "+ # Nix"
[[ -f "$ETC/bashrc" && ! -e "$ETC/bashrc.before-nix-darwin" ]] \
  && good "accept: nothing moved yet (only after the switch is confirmed)" \
  || bad "accept: nothing moved yet" "$(ls -la "$ETC")"
notlogged "accept: no sudo during the preflight" '^sudo'
run_case "ETC_RENAMES=\$(printf '%s\t%s\n%s\t%s\n' '$ETC/bashrc' \"\$(sha256_of '$ETC/bashrc')\" '$ETC/zshrc' \"\$(sha256_of '$ETC/zshrc')\")
etc_apply_renames; echo DONE"
check "apply: rc 0" "$(cat "$W/rc")" 0
[[ ! -e "$ETC/bashrc" && ! -e "$ETC/zshrc" ]] && good "apply: originals moved away" || bad "apply: originals moved away" "$(ls -la "$ETC")"
check "apply: content preserved in bashrc.before-nix-darwin" "$(cat "$ETC/bashrc.before-nix-darwin")" "$(prepended "$STOCK_BASHRC")"
logged "apply: moved as root" "sudo -n mv -f $ETC/zshrc $ETC/zshrc.before-nix-darwin"

fixture "$(appended "$STOCK_BASHRC")" "$STOCK_ZSHRC"; answer y
run_case 'etc_preflight; echo "RENAMES=$(cut -f1 <<<"$ETC_RENAMES" | xargs)"'
has "older installer layout (block appended) is recognised too" "RENAMES=$ETC/bashrc"
hasnt "a file with a KNOWN hash is left to nix-darwin" "$ETC/zshrc:"

fixture "$(prepended "$STOCK_BASHRC")" "$STOCK_ZSHRC"; answer n
run_case 'etc_preflight; echo REACHED'
check "decline: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "decline: nothing after the check runs" "REACHED"
has "decline: exact manual instruction" "sudo mv $ETC/bashrc $ETC/bashrc.before-nix-darwin"
check "decline: file untouched" "$(cat "$ETC/bashrc")" "$(prepended "$STOCK_BASHRC")"

fixture "$(prepended "$STOCK_BASHRC")
alias ll='ls -l'
" "$STOCK_ZSHRC"
printf '%s' "$STOCK_BASHRC" >"$ETC/bashrc.backup-before-nix"; answer y
run_case 'etc_preflight; echo REACHED'
check "custom content: stops (rc 1)" "$(cat "$W/rc")" 1
hasnt "custom content: no question asked" "[y/N]"
has "custom content: diff shows the unexpected line" "+ alias ll='ls -l'"
hasnt "custom content: the installer block is not reported as unexpected" "+ # Nix"
has "custom content: exact manual instruction" "sudo mv $ETC/bashrc $ETC/bashrc.before-nix-darwin"
[[ -f "$ETC/bashrc" && ! -e "$ETC/bashrc.before-nix-darwin" ]] && good "custom content: untouched" || bad "custom content: untouched" "$(ls "$ETC")"

fixture "$STOCK_BASHRC" "export SECRET_SAUCE=1
"; answer y
run_case 'etc_preflight'
check "custom content, no installer backup: stops (rc 1)" "$(cat "$W/rc")" 1
has "custom content, no installer backup: shows its content" "| export SECRET_SAUCE=1"

fixture "$(printf '%s\n%s' "$STOCK_BASHRC" "# Nix
export PATH=/evil:\$PATH
# End Nix")" "$STOCK_ZSHRC"; answer y
run_case 'etc_preflight'
check "a '# Nix' block holding anything else is custom (rc 1)" "$(cat "$W/rc")" 1

fixture "$(prepended "$STOCK_BASHRC")" "$STOCK_ZSHRC"; echo old >"$ETC/bashrc.before-nix-darwin"; answer y
run_case 'etc_preflight'
check ".before-nix-darwin exists: refuses (rc 1)" "$(cat "$W/rc")" 1
has ".before-nix-darwin exists: says so and names --force" "already exists — refusing to overwrite it"
check ".before-nix-darwin exists: old copy kept" "$(cat "$ETC/bashrc.before-nix-darwin")" "old"
FORCE=true run_case 'etc_preflight; etc_apply_renames'
check "--force: overwrites it (rc 0)" "$(cat "$W/rc")" 0
check "--force: replaced by the current file" "$(cat "$ETC/bashrc.before-nix-darwin")" "$(prepended "$STOCK_BASHRC")"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"; rm "$ETC/bashrc"; mkdir -p "$ETC/static"
echo x >"$ETC/static/bashrc"; ln -s "$ETC/static/bashrc" "$ETC/bashrc"; answer y
run_case 'etc_preflight; echo "RENAMES=[$ETC_RENAMES]"'
has "already nix-darwin's /etc/static link: nothing to do" "RENAMES=[]"

fixture "$STOCK_BASHRC" "$STOCK_ZSHRC"
ETC_FAIL=1 run_case 'etc_preflight; echo REACHED'
check "environment.etc unevaluable: fatal (rc 1)" "$(cat "$W/rc")" 1
has "environment.etc unevaluable: shows the nix error" "etc eval exploded"

fixture "$(prepended "$STOCK_BASHRC")" "$STOCK_ZSHRC"
run_case "ETC_RENAMES=\$(printf '%s\t%s\n' '$ETC/bashrc' deadbeef); etc_apply_renames; echo REACHED"
check "apply: file changed since the check → stops (rc 1)" "$(cat "$W/rc")" 1
[[ -f "$ETC/bashrc" ]] && good "apply: changed file not moved" || bad "apply: changed file not moved" "$(ls "$ETC")"
MV_FAIL=1 run_case "ETC_RENAMES=\$(printf '%s\t%s\n' '$ETC/bashrc' \"\$(sha256_of '$ETC/bashrc')\"); etc_apply_renames; echo REACHED"
check "apply: a failed mv stops the run (rc 1)" "$(cat "$W/rc")" 1
hasnt "apply: nothing after a failed mv" "REACHED"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "4. --plan-only reports all three, changes nothing"
fixture "$(prepended "$STOCK_BASHRC")" "$(prepended "$STOCK_ZSHRC")"; answer y
snap() { (cd "$W" && find etc -type f -exec shasum {} + | sort; ls -la etc) ; }
before=$(snap)
OWNER="$ME" PLAN=true run_case 'require_nix_features; setup_brew_user; etc_preflight
echo "MISSING=[$(nix_missing_features)] RENAMES=[$ETC_RENAMES]"'
check "plan-only: rc 0" "$(cat "$W/rc")" 0
check "plan-only: /etc and nix.conf unchanged" "$(snap)" "$before"
notlogged "plan-only: no tee/chown/mv/launchctl" 'sudo .*(tee|chown|mv|launchctl)'
hasnt "plan-only: no question asked" "[y/N]"
check "plan-only: 'will fix' reported for all three" "$(grep -c 'will fix' "$W/out")" 3
has "plan-only: the preview still evaluates (flakes on for this process only)" "MISSING=[]"
has "plan-only: nothing queued" "RENAMES=[]"

fixture "$STOCK_BASHRC" "custom
"
PLAN=true run_case 'etc_preflight; echo REACHED'
check "plan-only, custom /etc file: reports, does not exit" "$(cat "$W/rc")" 0
has "plan-only, custom /etc file: says the real run will stop" "will STOP"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "5. ordering in rebuild.sh"
ln_of() { grep -nE "$1" "$SCRIPT" | head -1 | cut -d: -f1; }
l_feat=$(ln_of '^require_nix_features$'); l_brew=$(ln_of '^setup_brew_user$')
l_etc=$(ln_of '^etc_preflight$'); l_plan=$(ln_of '^if \$PLAN_ONLY; then')
l_drift=$(ln_of '^# >>> BEGIN DRIFT AUDIT'); l_auth=$(ln_of '^authenticate_once "Build result')
l_apply=$(ln_of '^  etc_apply_renames$'); l_replace=$(ln_of '^  replace_hand_installed$')
l_switch=$(ln_of 'run_darwin_rebuild sudo')
for v in l_feat l_brew l_etc l_plan l_drift l_auth l_apply l_replace l_switch; do
  [[ -n "${!v}" ]] || bad "ordering: anchor $v found" "pattern missing in rebuild.sh"
done
(( l_feat < l_brew && l_brew < l_etc && l_etc < l_plan && l_plan < l_drift )) \
  && good "preflight: flakes → Homebrew owner → /etc, all before --plan-only exits and the drift audit" \
  || bad "preflight order" "$l_feat $l_brew $l_etc $l_plan $l_drift"
(( l_auth < l_apply && l_apply < l_replace && l_replace < l_switch )) \
  && good "/etc moves: after the authentication, before any app replacement and activation" \
  || bad "/etc move order" "$l_auth $l_apply $l_replace $l_switch"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
