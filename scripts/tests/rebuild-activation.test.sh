#!/usr/bin/env bash
# Coverage for run_darwin_rebuild() in scripts/rebuild.sh
#
# Run: ./scripts/tests/rebuild-activation.test.sh
#
# This function decides WHETHER THE SCRIPT ADMITS A FAILURE. Its original form
# ended in `rm -f "$log"`, so it always returned 0: a switch that died during
# activation still reached the "Done." banner and exit 0. A rebuild that lies
# about succeeding is worse than one that prompts too often — nothing surfaces
# a half-switched system until something downstream breaks.
#
# It also GUESSED at causes. An unmatched failure was reported as "likely sops
# secrets on first build (#27)" even when the switch had printed the real cause
# verbatim one line earlier. These tests pin both properties: the status is
# propagated, and an unknown cause is quoted rather than invented.
#
# The function is extracted from rebuild.sh rather than sourced — rebuild.sh
# executes top-to-bottom and would run a real rebuild if sourced.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/rebuild.sh"

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }

# Stubs for the helpers the function calls.
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }
info() { echo "[INFO] $*"; }
LOG_FILE="/tmp/rebuild-activation-test.log"

# shellcheck disable=SC1090
eval "$(sed -n '/^run_darwin_rebuild() {/,/^}/p' "$SCRIPT")"

if ! declare -F run_darwin_rebuild >/dev/null; then
  echo "FATAL: could not extract run_darwin_rebuild from $SCRIPT" >&2
  exit 1
fi

# fake_switch <exit-code> <output...> — stands in for `sudo darwin-rebuild switch`
fake_switch() { local rc="$1"; shift; printf '%s\n' "$@"; return "$rc"; }

run_case() { # run_case <exit-code> <output...>  -> sets OUT and RC
  OUT="$(run_darwin_rebuild fake_switch "$@" 2>&1)"; RC=$?
}

echo ""
echo "run_darwin_rebuild — exit status propagation"

run_case 0 "setting up /etc..." "Homebrew bundle..."
[[ $RC -eq 0 ]] && good "success returns 0" || bad "success returns 0" "got $RC"
grep -q "System updated" <<<"$OUT" && good "success reports 'System updated'" \
  || bad "success reports 'System updated'" "got: $OUT"

run_case 1 "Homebrew bundle..." "Error: You have not agreed to the Xcode license."
[[ $RC -eq 1 ]] && good "failure propagates exit 1" || bad "failure propagates exit 1" "got $RC"

run_case 3 "boom"
[[ $RC -eq 3 ]] && good "failure propagates the actual code (3)" \
  || bad "failure propagates the actual code (3)" "got $RC"

# Household guard: the primary user was logged out — still a success, with a
# note that her LaunchAgents load at her next login.
run_case 0 "Activating home-manager configuration for kassie" \
  "rh7: no GUI login session for kassie — LaunchAgents installed; they load at the next login"
[[ $RC -eq 0 ]] && good "logged-out primary user: still success" || bad "logged-out primary user: still success" "got $RC"
grep -q "load at her next login" <<<"$OUT" && good "logged-out primary user: note printed" \
  || bad "logged-out primary user: note printed" "got: $OUT"
run_case 0 "setting up /etc..."
grep -q "next login" <<<"$OUT" && bad "no note without the marker" "got: $OUT" || good "no note without the marker"

echo ""
echo "run_darwin_rebuild — cause reporting"

run_case 1 "Homebrew bundle..." "Error: You have not agreed to the Xcode license."
grep -q "xcodebuild -license accept" <<<"$OUT" \
  && good "Xcode gate names the fix" || bad "Xcode gate names the fix" "got: $OUT"
grep -q "NO cask was processed" <<<"$OUT" \
  && good "Xcode gate says no cask ran" || bad "Xcode gate says no cask ran" "got: $OUT"

run_case 1 "error: builder for '/nix/store/x.drv' failed"
grep -q "Nix build error" <<<"$OUT" \
  && good "nix builder failure is named" || bad "nix builder failure is named" "got: $OUT"

run_case 1 "Error: Failed to install Foo from App Store"
grep -q "App Store" <<<"$OUT" \
  && good "mas failure is named" || bad "mas failure is named" "got: $OUT"

# The regression that motivated this file: an unknown cause must not be
# reported as a confident sops diagnosis.
run_case 1 "some novel explosion" "error: the disk caught fire"
grep -qi "sops\|#27" <<<"$OUT" \
  && bad "unknown cause does not guess sops/#27" "got: $OUT" \
  || good "unknown cause does not guess sops/#27"
grep -q "Unrecognised failure" <<<"$OUT" \
  && good "unknown cause is labelled unrecognised" \
  || bad "unknown cause is labelled unrecognised" "got: $OUT"
grep -q "disk caught fire" <<<"$OUT" \
  && good "unknown cause quotes the real error line" \
  || bad "unknown cause quotes the real error line" "got: $OUT"

# Xcode gates Homebrew, so a brew failure alongside it is a symptom, not a
# second independent problem to report.
run_case 1 "Error: You have not agreed to the Xcode license." "Installing foo has failed!"
grep -q "not all Homebrew packages installed" <<<"$OUT" \
  && bad "Xcode suppresses the redundant brew line" "got: $OUT" \
  || good "Xcode suppresses the redundant brew line"

# The wording brew actually prints. "`brew bundle` failed!" has backticks and
# upgrade failures say "Upgrading X has failed!", so the original patterns
# missed both and a plain download failure was reported as "Unrecognised".
run_case 1 "Upgrading firefox has failed!" "\`brew bundle\` failed! 20 Brewfile dependencies failed to install"
grep -q "brew bundle had failures" <<<"$OUT" \
  && good "real brew-bundle wording is recognised" \
  || bad "real brew-bundle wording is recognised" "got: $OUT"
grep -q "Unrecognised failure" <<<"$OUT" \
  && bad "real brew-bundle wording is not 'unrecognised'" "got: $OUT" \
  || good "real brew-bundle wording is not 'unrecognised'"

# ── build_darwin_system: the fresh-Mac fallback (rh7/rh-device-management#311) ──
# With darwin-rebuild not on PATH (a freshly-Nix-installed Mac) the fallback
# used to build with `--no-link` and then activate ./result/sw/bin/darwin-rebuild
# — a path the build had just declined to create. Pin that the fallback builds
# to a real out-link and hands activation a darwin-rebuild that exists.
info() { echo "[INFO] $*"; }
# shellcheck disable=SC1090
eval "$(sed -n '/^build_darwin_system() {/,/^}/p' "$SCRIPT")"
if ! declare -F build_darwin_system >/dev/null; then
  echo "FATAL: could not extract build_darwin_system from $SCRIPT" >&2
  exit 1
fi

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$BUILD_ROOT/bin" "$BUILD_ROOT/dotfiles"
# Stub nix: records its argv; on success honours --out-link the way nix does
# (a link to a closure containing sw/bin/darwin-rebuild). `--no-link` creates
# nothing, exactly as the real one.
cat > "$BUILD_ROOT/bin/nix" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$NIX_ARGS_FILE"
[[ "${NIX_STUB_RC:-0}" -eq 0 ]] || exit "$NIX_STUB_RC"
out=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == --out-link ]] && { out="$2"; shift; }
  shift
done
if [[ -n "$out" ]]; then
  store="$NIX_STORE_DIR/system"
  mkdir -p "$store/sw/bin"
  printf '#!/bin/sh\nexit 0\n' > "$store/sw/bin/darwin-rebuild"
  chmod +x "$store/sw/bin/darwin-rebuild"
  ln -sfn "$store" "$out"
fi
STUB
chmod +x "$BUILD_ROOT/bin/nix"
mkdir -p "$BUILD_ROOT/store"

run_build() { # run_build <nix-rc> [flake-ref-suffix]  -> sets BOUT, BRC, BREBUILD, BARGS
  rm -f "$BUILD_ROOT/dotfiles/result"
  BOUT="$(
    # PATH holds only the stub dir and the base system — no darwin-rebuild.
    # (Running in a subshell keeps the stripped PATH out of the harness.)
    PATH="$BUILD_ROOT/bin:/usr/bin:/bin"
    export NIX_ARGS_FILE="$BUILD_ROOT/nix-args" NIX_STORE_DIR="$BUILD_ROOT/store" NIX_STUB_RC="$1"
    DOTFILES_DIR="$BUILD_ROOT/dotfiles" HOSTNAME="fresh-mac"
    # shellcheck disable=SC2034  # read by the eval'd build_darwin_system
    FLAKE_REF="${DOTFILES_DIR}${2-#${HOSTNAME}}"
    # shellcheck disable=SC2034
    RESULT_LINK="${DOTFILES_DIR}/result"
    DARWIN_REBUILD=""
    build_darwin_system 2>&1; rc=$?
    echo "RC=$rc"; echo "DARWIN_REBUILD=$DARWIN_REBUILD"; echo "FLAKE_REF=$FLAKE_REF"
  )"
  BRC="$(sed -n 's/^RC=//p' <<<"$BOUT")"
  BREBUILD="$(sed -n 's/^DARWIN_REBUILD=//p' <<<"$BOUT")"
  BFLAKE="$(sed -n 's/^FLAKE_REF=//p' <<<"$BOUT")"
  BARGS="$(cat "$BUILD_ROOT/nix-args" 2>/dev/null)"
}

echo ""
echo "build_darwin_system — darwin-rebuild not on PATH"

if PATH="/usr/bin:/bin" command -v darwin-rebuild >/dev/null 2>&1; then
  bad "harness hides darwin-rebuild" "darwin-rebuild found in /usr/bin:/bin"
else
  run_build 0
  [[ "$BRC" == 0 ]] && good "fallback build returns 0" || bad "fallback build returns 0" "got: $BOUT"
  grep -q -- '--no-link' <<<"$BARGS" \
    && bad "fallback does not build with --no-link" "nix args: $BARGS" \
    || good "fallback does not build with --no-link"
  grep -q -- "--out-link $BUILD_ROOT/dotfiles/result" <<<"$BARGS" \
    && good "fallback builds to the result link the diff reads" \
    || bad "fallback builds to the result link the diff reads" "nix args: $BARGS"
  grep -q "#darwinConfigurations.fresh-mac.system" <<<"$BARGS" \
    && good "fallback builds the FLAKE_REF host's system" \
    || bad "fallback builds the FLAKE_REF host's system" "nix args: $BARGS"
  [[ -n "$BREBUILD" && -x "$BREBUILD" ]] \
    && good "activation binary exists and is executable" \
    || bad "activation binary exists and is executable" "DARWIN_REBUILD='$BREBUILD'"
  [[ "$BREBUILD" == /* ]] \
    && good "activation binary is an absolute path (not cwd-relative ./result)" \
    || bad "activation binary is an absolute path (not cwd-relative ./result)" "DARWIN_REBUILD='$BREBUILD'"

  run_build 0 "#other-mac"
  grep -q "#darwinConfigurations.other-mac.system" <<<"$BARGS" \
    && good "fallback honours an explicit --flake host" \
    || bad "fallback honours an explicit --flake host" "nix args: $BARGS"
  for frag in "#" ""; do
    run_build 0 "$frag"
    grep -q "#darwinConfigurations.fresh-mac.system" <<<"$BARGS" \
      && good "flake ref '…${frag}' defaults to this host" \
      || bad "flake ref '…${frag}' defaults to this host" "nix args: $BARGS"
    [[ "$BFLAKE" == "$BUILD_ROOT/dotfiles#fresh-mac" ]] \
      && good "flake ref '…${frag}' is pinned for activation too" \
      || bad "flake ref '…${frag}' is pinned for activation too" "FLAKE_REF='$BFLAKE'"
  done

  run_build 1
  [[ "$BRC" != 0 ]] && good "failed nix build returns non-zero" \
    || bad "failed nix build returns non-zero" "got: $BOUT"
fi

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
