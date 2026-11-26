#!/usr/bin/env bash
# scripts/omarchy-apply.sh against stub pacman / omarchy-* / sudo / systemctl —
# no Arch machine, no network. Checks: the committed list is valid, plan
# changes nothing, apply installs only what is missing and is idempotent, one
# failure does not stop the rest, a bad list installs nothing, without a
# terminal only web apps install, --ref reads the commit not the working tree,
# and --install writes the hook and the timer.
#
# Run: bash scripts/tests/omarchy-apply.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/omarchy-apply.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()    { echo "  ok   — $1"; pass=$((pass + 1)); }
bad()   { echo "  FAIL — $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /' | head -30; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:  $2"$'\n'"want: $3"; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing: $3"$'\n'"in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected: $3"; else ok "$1"; fi; }

STUBS="$T/bin"; mkdir -p "$STUBS"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }
# State: $T/installed (one package per line), $T/calls (every write call).
stub pacman 'shift; [ "${1:-}" = "--" ] && shift; grep -qxF -- "$1" "$STATE/installed"'
stub omarchy-pkg-add 'echo "pkg-add $*" >>"$STATE/calls"; grep -qxF -- "$1" "$STATE/fail" 2>/dev/null && exit 1; printf "%s\n" "$@" >>"$STATE/installed"'
stub omarchy-pkg-aur-add 'echo "aur-add $*" >>"$STATE/calls"; grep -qxF -- "$1" "$STATE/fail" 2>/dev/null && exit 1; printf "%s\n" "$@" >>"$STATE/installed"'
stub omarchy-webapp-install 'echo "webapp $1|$2|$3" >>"$STATE/calls"; mkdir -p "$XDG_DATA_HOME/applications"; touch "$XDG_DATA_HOME/applications/$1.desktop"'
stub omarchy-install-service-demo 'echo "installer demo $*" >>"$STATE/calls"; echo demo-pkg >>"$STATE/installed"'
stub omarchy-install-browser 'echo "installer browser $*" >>"$STATE/calls"; echo "$1" >>"$STATE/installed"'
stub omarchy-install-noop 'echo "installer noop" >>"$STATE/calls"'   # exits 0, installs nothing
# Installs its sentinel package, then fails a later step unless $STATE/fixed exists.
stub omarchy-install-partial 'echo "installer partial" >>"$STATE/calls"; echo partial-pkg >>"$STATE/installed"; [ -e "$STATE/fixed" ]'
# Like omarchy-install-service-tailscale: no `set -e`, a middle step fails, the
# script still ends with exit 0 after installing its sentinel.
stub omarchy-install-swallow 'echo "installer swallow" >>"$STATE/calls"; echo swallow-pkg >>"$STATE/installed"; false; echo "later step"'
# Killed mid-run (reboot / closed terminal): sentinel installed, then the
# process dies, so omarchy-apply never sees it return.
stub omarchy-install-killed 'echo "installer killed" >>"$STATE/calls"; echo killed-pkg >>"$STATE/installed"; [ -e "$STATE/fixed" ] || kill -9 "$PPID"'
stub omarchy-hook-install 'echo "hook-install $1 $(basename "$2")" >>"$STATE/calls"; mkdir -p "$STATE/hooks/$1.d"; cp "$2" "$STATE/hooks/$1.d/"'
stub systemctl 'echo "systemctl $*" >>"$STATE/calls"'
stub sudo 'case "$1" in -v) exit 0;; -n) [ "${SUDO_OK:-1}" = 1 ];; *) exec "$@";; esac'
stub notify-send 'echo "notify $*" >>"$STATE/calls"'

reset() {
  rm -rf "${T:?}/state" "${T:?}/home"; mkdir -p "$T/state" "$T/home"
  : >"$T/state/installed"; : >"$T/state/calls"
}
run() {  # args...; sets OUT, RC
  OUT="$(cd "$T" && STATE="$T/state" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_CONFIG_HOME="$T/home/.config" OMARCHY_APPLY_ARCH="${ARCH:-x86_64}" \
    PATH="$STUBS:/usr/bin:/bin" bash "$SCRIPT" "$@" </dev/null 2>&1)"
  RC=$?
}
calls() { cat "$T/state/calls"; }

cat >"$T/list.txt" <<'EOF'
# comment
pkg     | ghostty
pkg     | already-here
aur     | slack-desktop
omarchy | omarchy-install-service-demo | demo-pkg
omarchy | omarchy-install-browser firefox | firefox
webapp  | Notion | https://www.notion.so/
webapp  | Mercury | https://app.mercury.com/home | https://example.com/m.png
EOF

echo "== the committed list is valid on both architectures"
for ARCH in x86_64 aarch64; do
  reset
  run
  check "plan over the real list exits 0 ($ARCH)" "$RC" "0"
  has "plan reports the real list ($ARCH)" "$OUT" "entries for $ARCH in configurations/linux/omarchy-apps.txt"
  check "plan writes nothing ($ARCH)" "$(calls)" ""
done
unset ARCH

echo "== kind@arch applies only on that architecture"
cat >"$T/arch.txt" <<'EOF'
pkg            | everywhere
pkg@x86_64     | intel-only
webapp@aarch64 | Arm Stand-in | https://example.com/
EOF
reset
ARCH=x86_64 run --list "$T/arch.txt"
has "x86_64: own line planned" "$OUT" "would install: pkg     intel-only"
hasnt "x86_64: aarch64 line skipped" "$OUT" "Arm Stand-in"
has "x86_64: skipped line counted" "$OUT" "2 entries for x86_64 in $T/arch.txt, 2 missing (1 for another architecture)"
ARCH=aarch64 run --list "$T/arch.txt"
has "aarch64: web-app stand-in planned" "$OUT" "would install: webapp  Arm Stand-in"
hasnt "aarch64: x86_64 line skipped" "$OUT" "intel-only"
for badline in 'pkg@arm64 | x' 'pkg@ | x'; do
  reset
  printf '%s\n' "$badline" >"$T/badarch.txt"
  ARCH=aarch64 run --list "$T/badarch.txt"
  check "unknown arch rejected: $badline" "$RC" "2"
done


echo "== plan"
reset; echo already-here >"$T/state/installed"
run --list "$T/list.txt"
check "plan exits 0" "$RC" "0"
has "counts missing" "$OUT" "7 entries for x86_64 in $T/list.txt, 6 missing"
has "lists an AUR package" "$OUT" "would install: aur     slack-desktop"
hasnt "present package not listed" "$OUT" "already-here"
check "plan writes nothing" "$(calls)" ""

echo "== apply installs only what is missing"
run --list "$T/list.txt" --apply
check "apply exits 0" "$RC" "0"
has "pkg via omarchy-pkg-add" "$(calls)" "pkg-add ghostty"
has "aur via omarchy-pkg-aur-add" "$(calls)" "aur-add slack-desktop"
has "installer with its argument" "$(calls)" "installer browser firefox"
has "web app, icon fetched (empty third arg)" "$(calls)" "webapp Notion|https://www.notion.so/|"
has "web app with icon" "$(calls)" "webapp Mercury|https://app.mercury.com/home|https://example.com/m.png"
hasnt "present package untouched" "$(calls)" "already-here"
has "summary" "$OUT" "installed 6, failed 0"

echo "== second apply is a no-op"
: >"$T/state/calls"
run --list "$T/list.txt" --apply
check "exits 0" "$RC" "0"
has "nothing missing" "$OUT" "0 missing"
check "no calls" "$(calls)" ""

echo "== one failure does not stop the rest"
reset; echo slack-desktop >"$T/state/fail"
run --list "$T/list.txt" --apply
check "exits 1" "$RC" "1"
has "failure named with its line" "$OUT" "FAILED: aur     slack-desktop (line 4, exit 1)"
has "later lines still ran" "$(calls)" "webapp Mercury"

echo "== an installer that exits 0 without installing counts as failed"
reset
printf 'omarchy | omarchy-install-noop | never-installed\n' >"$T/noop.txt"
run --list "$T/noop.txt" --apply
check "exits 1" "$RC" "1"
has "reported" "$OUT" "FAILED: omarchy omarchy-install-noop"

echo "== a partly failed installer re-runs until it succeeds"
reset
printf 'omarchy | omarchy-install-partial | partial-pkg\n' >"$T/partial.txt"
run --list "$T/partial.txt" --apply
check "first run fails" "$RC" "1"
: >"$T/state/calls"
run --list "$T/partial.txt"
has "sentinel present but still planned" "$OUT" "would install: omarchy omarchy-install-partial"
touch "$T/state/fixed"
run --list "$T/partial.txt" --apply
check "re-run succeeds" "$RC" "0"
has "installer ran again" "$(calls)" "installer partial"
: >"$T/state/calls"
run --list "$T/partial.txt" --apply
has "then nothing missing" "$OUT" "0 missing"
check "and no further runs" "$(calls)" ""

echo "== a sentinel installed by hand counts as present"
reset; echo partial-pkg >"$T/state/installed"
run --list "$T/partial.txt" --apply
has "nothing missing" "$OUT" "0 missing"
check "installer not run" "$(calls)" ""

echo "== an installer that swallows a failed step does not count as done"
reset
printf 'omarchy | omarchy-install-swallow | swallow-pkg\n' >"$T/swallow.txt"
run --list "$T/swallow.txt" --apply
check "exits 1" "$RC" "1"
has "reported" "$OUT" "FAILED: omarchy omarchy-install-swallow"
run --list "$T/swallow.txt"
has "still pending on the next run" "$OUT" "would install: omarchy omarchy-install-swallow"

echo "== an installer killed mid-run stays pending"
reset
printf 'omarchy | omarchy-install-killed | killed-pkg\n' >"$T/killed.txt"
run --list "$T/killed.txt" --apply
hasnt "the run never reached its summary" "$OUT" "installed 1"
run --list "$T/killed.txt"
has "pending on the next run despite the sentinel" "$OUT" "would install: omarchy omarchy-install-killed"
touch "$T/state/fixed"
run --list "$T/killed.txt" --apply
check "completes on re-run" "$RC" "0"
run --list "$T/killed.txt"
has "then done" "$OUT" "0 missing"

echo "== a bad list installs nothing"
for badline in \
  'brew | ghostty' \
  'omarchy | rm -rf / | x' \
  'omarchy | omarchy-install-service-demo' \
  'omarchy | omarchy-install-browser $(id) | firefox' \
  'webapp | Notion | http://www.notion.so/' \
  'webapp | a/b | https://x.example/' \
  'pkg | Ghostty Terminal'; do
  reset
  printf 'pkg | ghostty\n%s\n' "$badline" >"$T/bad.txt"
  run --list "$T/bad.txt" --apply
  check "exit 2 for: $badline" "$RC" "2"
  check "nothing installed for: $badline" "$(calls)" ""
done

echo "== without a terminal or sudo only web apps install"
reset
OUT="$(cd "$T" && STATE="$T/state" HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" XDG_CONFIG_HOME="$T/home/.config" \
  SUDO_OK=0 PATH="$STUBS:/usr/bin:/bin" bash "$SCRIPT" --list "$T/list.txt" --apply </dev/null 2>&1)"; RC=$?
check "exits 0 (nothing failed)" "$RC" "0"
has "web app installed" "$(calls)" "webapp Notion"
hasnt "no package install" "$(calls)" "pkg-add"
has "skipped are reported" "$OUT" "needs a terminal 5"
has "desktop notification" "$(calls)" "notify rh7 apps"

echo "== --ref reads the committed list, not the working tree"
reset
G="$T/repo"; mkdir -p "$G/configurations/linux"
git -C "$G" init -q
printf 'pkg | committed-pkg\n' >"$G/configurations/linux/omarchy-apps.txt"
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm list
printf 'pkg | working-tree-pkg\n' >"$G/configurations/linux/omarchy-apps.txt"
OUT="$(cd "$T" && STATE="$T/state" HOME="$T/home" OMARCHY_APPLY_REPO="$G" PATH="$STUBS:/usr/bin:/bin" \
  bash "$SCRIPT" --ref HEAD 2>&1)"; RC=$?
check "exits 0" "$RC" "0"
has "committed line planned" "$OUT" "would install: pkg     committed-pkg"
hasnt "working tree ignored" "$OUT" "working-tree-pkg"

echo "== --install writes the hook and the audit timer"
reset
run --install
check "exits 0" "$RC" "0"
has "post-update hook installed" "$(calls)" "hook-install post-update rh7-apps"
hook="$T/state/hooks/post-update.d/rh7-apps"
if bash -n "$hook" 2>/dev/null; then ok "hook is valid bash"; else bad "hook is valid bash" "$(cat "$hook")"; fi
has "hook runs --from-hook" "$(cat "$hook")" "--from-hook"
timer="$T/home/.config/systemd/user/fleet-audit.timer"
service="$T/home/.config/systemd/user/fleet-audit.service"
has "timer catches up missed runs" "$(cat "$timer")" "Persistent=true"
has "service runs the collector runner" "$(cat "$service")" "scripts/collector-runner.sh"
has "timer enabled under the name fleet-fix/enroll recognise" "$(calls)" "systemctl --user enable --now fleet-audit.timer"

echo
echo "omarchy-apply: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
