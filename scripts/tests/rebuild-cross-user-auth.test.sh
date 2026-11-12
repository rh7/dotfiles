#!/usr/bin/env bash
# End-to-end coverage for the ONE authentication of a cross-user rebuild:
# rebuild.sh run by an admin (rouven) on a Mac whose system.primaryUser — and
# Homebrew prefix — is someone else (kassie), on the kassie-mbp-m1 path: a
# full (non --plan-only) run, darwin-rebuild not on PATH (nix build fallback).
#
# WHY THIS EXISTS: kassie-mbp-m1's drift audit printed "brew info failed for:
# 1password arc … (25 casks)" and listed those apps as unmanaged, and the run
# only authenticated AFTER the build ("Homebrew belongs to kassie —
# authenticating now"). The process was the pre-#125 rebuild.sh: the
# checkout sync fast-forwarded e1c8cea → b909840 under it, so the new audit
# (which needs BREW_CMD) ran under the old parent (which never set it). #125
# added the re-exec that closes that gap from then on; this test pins what the
# current script does on that path, running the REAL rebuild.sh top to bottom:
#
#   - exactly one authentication prompt in the whole run;
#   - it happens BEFORE the drift audit, and the audit gets
#     BREW_CMD="sudo -n -u kassie -H <prefix>/bin/brew" with a usable credential
#     (its `brew info` really runs as kassie);
#   - the plan does not authenticate again, activation needs no second prompt;
#   - the build took the nix build fallback.
#   - and after a sync that changes rebuild.sh, the RE-EXECUTED version is the
#     one that authenticates, once, before its audit.
#
# Stubs (PATH): sudo (a credential file stands in for the timestamp; `sudo -v`
# is the prompt), nix, id, hostname, stat, brew (inside a temp prefix), mas.
# The checkout is a real git clone of a real bare origin. The drift audit is a
# stub that records what it was given. Nothing outside the temp dir is touched.
#
# Run: bash scripts/tests/rebuild-cross-user-auth.test.sh   (macOS: stat -f, Darwin paths)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rebuild.sh"

if [[ "$(uname -s)" != Darwin ]] || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: needs macOS (rebuild.sh's Darwin path) and jq"
  exit 0
fi

pass=0; fail=0
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then good "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

W=$(mktemp -d /tmp/xuserauth.XXXXXX)
trap 'rm -rf "$W"' EXIT

g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# ── stubs ──
STUBS="$W/stubs"; PFX="$W/homebrew"
mkdir -p "$STUBS" "$PFX/bin"

cat >"$STUBS/sudo" <<'EOF'
#!/bin/bash
# The credential file is the sudo timestamp. `sudo -v` without one is THE prompt.
ev() { echo "$*" >>"$EVENTS"; }
nonint=false
if [[ "${1:-}" == -k ]]; then rm -f "$CRED"; exit 0; fi
if [[ "${1:-}" == -n ]]; then nonint=true; shift; fi
if [[ "${1:-}" == -v ]]; then
  if [[ -f "$CRED" ]]; then exit 0; fi
  $nonint && exit 1
  ev "PROMPT"; touch "$CRED"; exit 0
fi
if [[ ! -f "$CRED" ]]; then
  $nonint && exit 1
  ev "PROMPT (sudo $*)"; touch "$CRED"
fi
if [[ "${1:-}" == -u ]]; then
  user="$2"; shift 2
  [[ "${1:-}" == -H ]] && shift
  [[ "${1:-}" == env ]] && shift
  while [[ "${1:-}" == *=* ]]; do export "${1?}"; shift; done
  SUDO_AS="$user" exec "$@"
fi
ev "sudo $*"
[[ "${1:-}" == true ]] && exit 0
case "$1" in */darwin-rebuild) exec "$@" ;; esac
exit 0
EOF

cat >"$STUBS/nix" <<'EOF'
#!/bin/bash
a="$*"
case "$a" in
  "config show experimental-features") echo "nix-command flakes" ;;
  *"config.system.primaryUser"*) printf kassie ;;
  *"config.homebrew.enable"*) echo true ;;
  *"config.homebrew.masApps"*) echo '{}' ;;
  *"config.homebrew."*|*criticalUpgrades*|*retiredCasks*) echo '[]' ;;
  *"postActivation.text"*) echo '""' ;;
  *"config.environment.etc"*) printf '' ;;
  build\ *)
    out=""; prev=""
    for x in "$@"; do [[ "$prev" == --out-link ]] && out="$x"; prev="$x"; done
    echo "nix build" >>"$EVENTS"
    mkdir -p "$W/sys/sw/bin"
    printf '#!/bin/bash\necho "darwin-rebuild $*" >>"$EVENTS"\n' >"$W/sys/sw/bin/darwin-rebuild"
    chmod +x "$W/sys/sw/bin/darwin-rebuild"
    ln -sfn "$W/sys" "$out" ;;
  "store diff-closures"*) : ;;
  *) echo "nix stub: unhandled: $a" >&2; exit 1 ;;
esac
EOF

cat >"$STUBS/id" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -un ]]; then echo "${SUDO_AS:-rouven}"; else exec /usr/bin/id "$@"; fi
EOF
printf '#!/bin/bash\necho testhost\n' >"$STUBS/hostname"
# Every path under the prefix is kassie's (brew_prefix_foreign: stat -f '%Su %N').
cat >"$STUBS/stat" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -f && "${2:-}" == '%Su %N' ]]; then shift 2; for p; do echo "kassie $p"; done
else exec /usr/bin/stat "$@"; fi
EOF
printf '#!/bin/bash\nexit 0\n' >"$STUBS/mas"
# Homebrew answers only for its owner, like the real `brew info` from another
# account on kassie-mbp-m1; every call is recorded with the user it ran as.
cat >"$PFX/bin/brew" <<'EOF'
#!/bin/bash
who="${SUDO_AS:-rouven}"
echo "brew[$who] $*" >>"$EVENTS"
[[ "$who" == kassie ]] || exit 1
case "${1:-}" in
  info) echo '{"casks":[]}' ;;
esac
exit 0
EOF
chmod +x "$STUBS"/* "$PFX/bin/brew"

# The drift audit: records its BREW_CMD and whether a credential exists, and
# runs `brew info` through it the way audit-config-drift.sh does.
AUDIT_STUB='#!/bin/bash
cred=no; [[ -f "$CRED" ]] && cred=yes
echo "AUDIT BREW_CMD=${BREW_CMD:-} cred=$cred" >>"$EVENTS"
if [[ -n "${BREW_CMD:-}" ]]; then ( cd / && $BREW_CMD info --cask probe >/dev/null ) && echo "AUDIT brew info ok" >>"$EVENTS"; fi
echo "DRIFT_RESULT: risky=0 benign=0 informational=0"
exit 0'

# setup <case> <script> — bare origin + clean checkout at origin/main whose
# scripts/rebuild.sh is <script>.
setup() {
  local d="$W/$1"
  mkdir -p "$d"
  g init -q --bare "$d/origin.git"
  g clone -q "$d/origin.git" "$d/dot" 2>/dev/null
  mkdir -p "$d/dot/scripts/lib"
  cp "$ROOT"/lib/*.sh "$d/dot/scripts/lib/"
  cp "$2" "$d/dot/scripts/rebuild.sh"
  printf '%s\n' "$AUDIT_STUB" >"$d/dot/scripts/audit-config-drift.sh"
  chmod +x "$d/dot/scripts/audit-config-drift.sh" "$d/dot/scripts/rebuild.sh"
  printf 'result\n' >"$d/dot/.gitignore"
  g -C "$d/dot" add -A && g -C "$d/dot" commit -qm v1 && g -C "$d/dot" push -q origin HEAD:main
}

# run <case> [args…] — the real rebuild.sh; events in $W/<case>/events.
run() {
  local d="$W/$1"; shift
  : >"$d/events"; rm -f "$d/cred"
  ( cd "$d" && env -i PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$d" TERM=dumb \
      USER=rouven LOGNAME=rouven GIT_CONFIG_GLOBAL=/dev/null DOTFILES_DIR="$d/dot" \
      REBUILD_LOG_DIR="$d/logs" EVENTS="$d/events" CRED="$d/cred" W="$d" \
      HOMEBREW_PREFIX="$PFX" \
      "$BASH" "$d/dot/scripts/rebuild.sh" "$@" </dev/null >"$d/out" 2>&1
    echo $? >"$d/rc" )
}
ev_line() { grep -n -- "$2" "$W/$1/events" | head -1 | cut -d: -f1; }

# brew_prefix finds Homebrew by `command -v brew` / the standard prefixes;
# pin it to the temp prefix for the run.
grep -q '^brew_prefix() {' "$SCRIPT" || { echo "FATAL: brew_prefix not found in $SCRIPT" >&2; exit 1; }
patched() {  # rebuild.sh with brew_prefix answering the temp prefix
  awk -v p="$PFX" '
    /^brew_prefix\(\) \{/ { print "brew_prefix() { echo \"" p "\"; }"; skip = ($0 !~ /\}$/); next }
    skip { if ($0 ~ /^\}/) skip = 0; next }
    { print }' "$SCRIPT"
}
patched >"$W/rebuild.sh"
grep -q "brew_prefix() { echo \"$PFX\"; }" "$W/rebuild.sh" \
  || { echo "FATAL: could not pin brew_prefix" >&2; exit 1; }

echo "cross-user full run (nix build fallback)"
setup a "$W/rebuild.sh"
run a --yes --upgrade=none
E="$W/a/events"
check "exit 0" "$(cat "$W/a/rc")" 0
[[ "$(cat "$W/a/rc")" == 0 ]] || { echo "----- output -----"; cat "$W/a/out"; echo "----- events -----"; cat "$E"; }
check "exactly one authentication prompt" "$(grep -c '^PROMPT' "$E")" 1
l_prompt=$(ev_line a '^PROMPT'); l_audit=$(ev_line a '^AUDIT BREW_CMD')
l_build=$(ev_line a '^nix build'); l_switch=$(ev_line a '^darwin-rebuild ')
[[ -n "$l_prompt" && -n "$l_audit" && "$l_prompt" -lt "$l_audit" ]] \
  && good "the prompt comes before the drift audit" || bad "prompt before audit" "$(cat "$E")"
[[ -n "$l_build" && "$l_audit" -lt "$l_build" ]] \
  && good "the audit (and so the prompt) comes before the build" || bad "audit before build" "$(cat "$E")"
check "the audit runs Homebrew as kassie, with a credential" \
  "$(sed -n "${l_audit}p" "$E")" "AUDIT BREW_CMD=sudo -n -u kassie -H $PFX/bin/brew cred=yes"
grep -q '^AUDIT brew info ok$' "$E" && good "the audit's brew info succeeds (as kassie)" \
  || bad "audit brew info" "$(cat "$E")"
if grep -q '^brew\[rouven\]' "$E"; then bad "no brew call as the invoker" "$(grep '^brew\[rouven\]' "$E")"
else good "no brew call as the invoker"; fi
if grep -q 'authenticating now to run it as' "$W/a/out"; then
  bad "the plan does not authenticate again" "$(grep 'authenticating now' "$W/a/out")"
else good "the plan does not authenticate again"; fi
grep -q 'authenticating now so the drift audit' "$W/a/out" \
  && good "says why it authenticates before the audit" || bad "says why" "$(cat "$W/a/out")"
grep -q 'darwin-rebuild not in PATH — using nix build' "$W/a/out" \
  && good "took the nix build fallback" || bad "nix build fallback" "$(cat "$W/a/out")"
[[ -n "$l_switch" ]] && grep -q "^darwin-rebuild switch --flake $W/a/dot#testhost" "$E" \
  && good "activated with the built closure's darwin-rebuild, no second prompt" \
  || bad "activation" "$(cat "$E")"

echo ""
echo "the sync changes rebuild.sh: the re-executed version authenticates, once, before its audit"
# Checkout at v1 (marker: never reaches the audit), origin/main one commit
# ahead with the current script. The old process must not run its own audit.
setup b "$W/rebuild.sh"
awk '{ print } !d && $0 == "cd \"$DOTFILES_DIR\"" { print "echo OLD-VERSION-RAN >>\"$EVENTS\"; exit 3"; d=1 }' \
  "$W/rebuild.sh" >"$W/b/dot/scripts/rebuild.sh"
g -C "$W/b/dot" commit -qam old && g -C "$W/b/dot" push -q origin HEAD:main
cp "$W/rebuild.sh" "$W/b/dot/scripts/rebuild.sh"
g -C "$W/b/dot" commit -qam new && g -C "$W/b/dot" push -q origin HEAD:main
g -C "$W/b/dot" reset -q --hard HEAD~1
run b --yes --upgrade=none
E="$W/b/events"
check "exit 0" "$(cat "$W/b/rc")" 0
grep -q 'restarting the updated version' "$W/b/out" && good "re-executed after the sync" \
  || bad "re-exec" "$(cat "$W/b/out")"
if grep -q OLD-VERSION-RAN "$E"; then bad "the old version does not go on" "$(cat "$E")"
else good "the old version does not go on"; fi
check "exactly one authentication prompt" "$(grep -c '^PROMPT' "$E")" 1
l_prompt=$(ev_line b '^PROMPT'); l_audit=$(ev_line b '^AUDIT BREW_CMD')
[[ -n "$l_prompt" && -n "$l_audit" && "$l_prompt" -lt "$l_audit" ]] \
  && good "the prompt comes before the drift audit" || bad "prompt before audit" "$(cat "$E")"
check "the audit runs Homebrew as kassie, with a credential" \
  "$(sed -n "${l_audit:-1}p" "$E")" "AUDIT BREW_CMD=sudo -n -u kassie -H $PFX/bin/brew cred=yes"

echo ""
printf 'passed: %d   failed: %d\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
