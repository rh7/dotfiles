#!/usr/bin/env bash
# scripts/omarchy-apply.sh against stub pacman / omarchy-* / sudo / systemctl —
# no Arch machine, no network. Checks: every committed host file is valid, host
# files pull in profiles (deduplicated, no nesting), an unknown host falls back
# to default with a warning, a pre-profiles commit still reads, plan
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
    OMARCHY_APPLY_HOST="${HOSTN:-testhost}" OMARCHY_APPLY_REPO="${REPO:-$REPO_ROOT}" \
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

echo "== every committed host file is valid on both architectures"
for hf in "$REPO_ROOT"/configurations/omarchy/hosts/*.txt; do
  HOSTN="$(basename "$hf" .txt)"
  for ARCH in x86_64 aarch64; do
    reset
    run
    check "plan for $HOSTN exits 0 ($ARCH)" "$RC" "0"
    has "plan reads its host file ($HOSTN, $ARCH)" "$OUT" "entries for $ARCH in configurations/omarchy/hosts/$HOSTN.txt"
    hasnt "no fallback warning ($HOSTN, $ARCH)" "$OUT" "no host file"
    check "plan writes nothing ($HOSTN, $ARCH)" "$(calls)" ""
  done
done
unset ARCH HOSTN
for p in "$REPO_ROOT"/configurations/omarchy/profiles/*.txt; do
  name="$(basename "$p" .txt)"
  if grep -qE "^profile[[:space:]]*\|[[:space:]]*$name[[:space:]]*$" "$REPO_ROOT"/configurations/omarchy/hosts/*.txt; then
    ok "profile $name is used by a host file"
  else
    bad "profile $name is used by a host file" "no hosts/*.txt pulls it in"
  fi
done

# A throwaway repo with the hosts/profiles layout.
mkrepo() {  # dir
  mkdir -p "$1/configurations/omarchy/hosts" "$1/configurations/omarchy/profiles"
  printf 'pkg | base-a\npkg | shared\n' >"$1/configurations/omarchy/profiles/base.txt"
  printf 'pkg | gui-a\npkg | shared\nwebapp@aarch64 | Arm App | https://example.com/\n' >"$1/configurations/omarchy/profiles/gui.txt"
  printf '# a host\nprofile | base\nprofile | gui\npkg | host-extra\n' >"$1/configurations/omarchy/hosts/box.txt"
  printf 'profile | base\n' >"$1/configurations/omarchy/hosts/default.txt"
}

echo "== a host file pulls in its profiles"
reset; R="$T/r1"; rm -rf "$R"; mkrepo "$R"
REPO="$R" HOSTN=box run
check "exits 0" "$RC" "0"
has "names host and profiles" "$OUT" "host box (profiles: base gui)"
has "counts: an app in two profiles is listed once" "$OUT" "4 entries for x86_64 in configurations/omarchy/hosts/box.txt, 4 missing (1 for another architecture)"
for p in base-a gui-a shared host-extra; do has "plans $p" "$OUT" "would install: pkg     $p"; done
check "shared planned once" "$(grep -c 'pkg     shared' <<<"$OUT")" "1"
REPO="$R" HOSTN=box run --apply
check "apply exits 0" "$RC" "0"
check "shared installed once" "$(grep -c 'pkg-add shared' "$T/state/calls")" "1"

echo "== --host plans another machine's list"
reset
REPO="$R" HOSTN=elsewhere run --host box
has "reads box" "$OUT" "in configurations/omarchy/hosts/box.txt"

echo "== an unknown host falls back to default, with a warning"
reset
REPO="$R" HOSTN=newvm run
check "exits 0" "$RC" "0"
has "warns" "$OUT" "no host file for 'newvm' — using default"
has "reads default" "$OUT" "2 entries for x86_64 in configurations/omarchy/hosts/default.txt"
hasnt "nothing from gui" "$OUT" "gui-a"

echo "== review fixes: case, refs, conflicts, extra fields, empty lists"
reset
REPO="$R" HOSTN=Box run
check "uppercase hostname is lowercased" "$RC" "0"
has "reads box.txt" "$OUT" "hosts/box.txt"
REPO="$R" HOSTN=box run --ref no-such-ref
check "unresolvable ref: exit 2" "$RC" "2"
has "names the ref, not a missing host file" "$OUT" "ref 'no-such-ref' does not resolve"
hasnt "no misleading host-file warning" "$OUT" "no host file"
R3="$T/r3"; rm -rf "$R3"; mkrepo "$R3"
printf 'webapp | Notion | https://a.example/\n' >"$R3/configurations/omarchy/profiles/base.txt"
printf 'webapp | Notion | https://b.example/\n' >"$R3/configurations/omarchy/profiles/gui.txt"
REPO="$R3" HOSTN=box run --apply
check "same app, different URL in two profiles: exit 2" "$RC" "2"
has "conflict names the earlier line" "$OUT" "conflicts with an earlier 'webapp | Notion' line"
check "conflict: nothing installed" "$(calls)" ""
mkrepo "$R3"
printf 'omarchy | omarchy-install-browser  firefox | firefox\n' >"$R3/configurations/omarchy/profiles/base.txt"
printf 'omarchy | omarchy-install-browser firefox | firefox\n' >"$R3/configurations/omarchy/profiles/gui.txt"
REPO="$R3" HOSTN=box run
check "installer spacing does not defeat dedup" "$(grep -c 'would install: omarchy' <<<"$OUT")" "1"
for badline in 'pkg | zz | | ignored' 'profile | base | | junk'; do
  mkrepo "$R3"; printf '%s\n' "$badline" >"$R3/configurations/omarchy/hosts/box.txt"
  REPO="$R3" HOSTN=box run
  check "extra field rejected: $badline" "$RC" "2"
done
mkrepo "$R3"; : >"$R3/configurations/omarchy/hosts/box.txt"
REPO="$R3" HOSTN=box run
check "empty host file: exit 0" "$RC" "0"
has "empty host file: warned" "$OUT" "lists no apps"

echo "== profile mistakes install nothing"
reset; R2="$T/r2"; rm -rf "$R2"; mkrepo "$R2"
printf 'profile | base\npkg | gui-a\n' >"$R2/configurations/omarchy/profiles/gui.txt"
REPO="$R2" HOSTN=box run --apply
check "nested profile: exit 2" "$RC" "2"
has "nested profile: named with its file and line" "$OUT" "configurations/omarchy/profiles/gui.txt line 1: a profile cannot pull in another profile"
check "nested profile: nothing installed" "$(calls)" ""
mkrepo "$R2"; printf 'profile | nope\n' >"$R2/configurations/omarchy/hosts/box.txt"
REPO="$R2" HOSTN=box run --apply
check "missing profile: exit 2" "$RC" "2"
has "missing profile: reported" "$OUT" "no such profile"
mkrepo "$R2"; printf 'pkg | Bad Name\n' >"$R2/configurations/omarchy/profiles/gui.txt"
REPO="$R2" HOSTN=box run --apply
check "bad line in a profile: exit 2" "$RC" "2"
has "bad line in a profile: named with the profile's file" "$OUT" "configurations/omarchy/profiles/gui.txt line 1: not a package name"
check "bad line in a profile: nothing installed" "$(calls)" ""
reset
REPO="$R" HOSTN='Bad/Host' run
check "unsafe hostname: exit 2" "$RC" "2"

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
has "failure named with its file and line" "$OUT" "FAILED: aur     slack-desktop ($T/list.txt line 4, exit 1)"
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

gitc() { git -C "$1" -c user.name=t -c user.email=t@t -c init.defaultBranch=main "${@:2}"; }

echo "== --ref reads the committed host file and profiles, not the working tree"
reset
G="$T/repo"; rm -rf "$G"; mkrepo "$G"
gitc "$G" init -q && gitc "$G" add -A && gitc "$G" commit -qm list
printf 'pkg | working-tree-pkg\n' >>"$G/configurations/omarchy/profiles/gui.txt"
printf 'pkg | working-host-pkg\n' >>"$G/configurations/omarchy/hosts/box.txt"
REPO="$G" HOSTN=box run --ref HEAD
check "exits 0" "$RC" "0"
has "committed profile line planned" "$OUT" "would install: pkg     gui-a"
has "source is the ref" "$OUT" "in HEAD:configurations/omarchy/hosts/box.txt"
hasnt "working-tree profile ignored" "$OUT" "working-tree-pkg"
hasnt "working-tree host file ignored" "$OUT" "working-host-pkg"

echo "== a commit from before host files reads the old flat list"
reset
L="$T/legacy"; rm -rf "$L"; mkdir -p "$L/configurations/linux"
printf 'pkg | legacy-pkg\n' >"$L/configurations/linux/omarchy-apps.txt"
gitc "$L" init -q && gitc "$L" add -A && gitc "$L" commit -qm old
REPO="$L" HOSTN=box run --ref HEAD
check "exits 0" "$RC" "0"
has "legacy line planned" "$OUT" "would install: pkg     legacy-pkg"
has "legacy source named" "$OUT" "in HEAD:configurations/linux/omarchy-apps.txt"

echo "== from the hook: origin/main, and a notification when the host has no file"
reset
B="$T/origin.git"; C="$T/clone"; rm -rf "$B" "$C"
gitc "$T" init -q --bare "$B"
mkrepo "$C"; gitc "$C" init -q && gitc "$C" add -A && gitc "$C" commit -qm list
gitc "$C" remote add origin "$B" && gitc "$C" push -q origin HEAD:main
REPO="$C" HOSTN=renamed-box run --from-hook
check "exits 0" "$RC" "0"
has "reads origin/main default" "$OUT" "in origin/main:configurations/omarchy/hosts/default.txt"
has "notifies about the missing host file" "$(calls)" "notify rh7 apps no host file for 'renamed-box'"
reset
REPO="$C" HOSTN=box run --from-hook
hasnt "no notification for a known host" "$(calls)" "notify"

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
