#!/usr/bin/env bash
# scripts/omarchy-apply.sh — keep an Omarchy machine carrying the apps its host
# file lists: configurations/omarchy/hosts/<hostname>.txt, which names profiles
# in configurations/omarchy/profiles/ (see configurations/omarchy/README.md).
#
#   omarchy-apply.sh                  plan: show what is missing, change nothing
#   omarchy-apply.sh --apply          install what is missing
#   omarchy-apply.sh --ref <ref>      read the list from a committed ref, not the working tree
#   omarchy-apply.sh --install        install the post-update hook + the daily audit timer
#   omarchy-apply.sh --from-hook      what the post-update hook runs: fetch origin,
#                                     then --apply --ref origin/main
#   omarchy-apply.sh --host <name>    plan or apply another host's list (default: this hostname)
#   omarchy-apply.sh --list <file>    use one list file instead of a host file
#
# THE DIVISION OF LABOUR: Omarchy owns the desktop and does every install. This
# script only decides WHAT is missing and hands it to Omarchy's own tools —
# omarchy-pkg-add (pacman), omarchy-pkg-aur-add (yay), the omarchy-install-*
# installers (they also add browser extensions, bar plugins and services) and
# omarchy-webapp-install. It never writes pacman/yay state itself and never
# touches ~/.config (that is the user's, see configurations/linux/omarchy.nix).
#
# ADDITIVE ONLY. A line removed from the list uninstalls nothing; removal stays
# `omarchy pkg drop` / Remove > Web App, by a human.
#
# IDEMPOTENT. Every line has a presence check (pacman -Q, or the web app's
# launcher file); present lines are skipped, so a re-run installs nothing.
#
# ONE FAILURE DOES NOT STOP THE REST. A flaky AUR build must not keep Signal
# off the machine. Exit 1 when any line failed, after trying all of them.
#
# SUDO. Package installs need sudo. Omarchy clears its cached sudo before
# post-update hooks run, so from the hook this asks once in the update terminal.
# With no terminal and no usable sudo it installs only the web apps (no root
# needed) and reports the rest instead of hanging on a prompt.
#
# The list is validated as a whole before anything runs; one bad line installs
# nothing (exit 2). Omarchy installer lines must name an omarchy-install-*
# command — the list declares software, it is not a place for arbitrary shell.
#
# Exit: 0 ok / plan shown, 1 a line failed, 2 bad list or not Omarchy, 64 usage.
set -euo pipefail

REPO_ROOT="${OMARCHY_APPLY_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OMARCHY_REL="configurations/omarchy"
HOSTS_REL="$OMARCHY_REL/hosts"
PROFILES_REL="$OMARCHY_REL/profiles"
# The single list every machine shared before host files; read only from a
# commit that has no hosts/ directory yet.
LEGACY_LIST_REL="configurations/linux/omarchy-apps.txt"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# The name fleet-fix.sh and enroll.sh already recognise as a Linux audit
# schedule (they also accept the cron line collector-runner --install writes).
AUDIT_UNIT="fleet-audit"
# An omarchy-install-* installer can create its presence sentinel and then fail
# on a later step (Microsoft creates Word before Excel; Tailscale installs the
# package before `tailscale up`). A run that fails leaves a marker here; while
# it exists the line counts as missing, so the installer re-runs until it
# succeeds. A sentinel without a marker (installed by hand) counts as present.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rh7-omarchy-apply"
HOOK_NAME="rh7-apps"

say()  { printf '%s\n' "$*"; }
warn() { printf 'omarchy-apply: %s\n' "$*" >&2; }
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=plan
REF=""
LIST_FILE=""
FROM_HOOK=0
HOST="${OMARCHY_APPLY_HOST:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --install) MODE=install ;;
    --from-hook) MODE=apply; FROM_HOOK=1 ;;
    --ref) [ $# -ge 2 ] || { usage >&2; exit 64; }; REF="$2"; shift ;;
    --host) [ $# -ge 2 ] || { usage >&2; exit 64; }; HOST="$2"; shift ;;
    --list) [ $# -ge 2 ] || { usage >&2; exit 64; }; LIST_FILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 64 ;;
  esac
  shift
done
[ -n "$HOST" ] || HOST="$(hostnamectl hostname 2>/dev/null || uname -n)"
# The short name, lowercased: host files are named in lowercase, and a
# hostname is case-insensitive (`Rouven-ThinkPad` and `rouven-thinkpad` are one machine).
HOST="${HOST%%.*}"
HOST="${HOST,,}"

# ── --install: post-update hook + daily audit timer ─────────────────────────
install_hook_and_timer() {
  command -v omarchy-hook-install >/dev/null 2>&1 \
    || { warn "omarchy-hook-install not found — is this an Omarchy machine?"; exit 2; }

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  {
    printf '#!/bin/bash\n'
    printf '# rh7/dotfiles: keep the apps in %s installed after every omarchy update.\n' "$HOSTS_REL/<hostname>.txt"
    printf '# Written by scripts/omarchy-apply.sh --install; re-run that to refresh it.\n'
    printf 'script=%q\n' "$REPO_ROOT/scripts/omarchy-apply.sh"
    # shellcheck disable=SC2016
    printf 'if [ -f "$script" ]; then bash "$script" --from-hook; else echo "%s: $script not found — skipped"; fi\n' "$HOOK_NAME"
  } >"$tmp/$HOOK_NAME"
  omarchy-hook-install post-update "$tmp/$HOOK_NAME"

  # The collector runner's Linux schedule is cron, and Omarchy ships no cron
  # daemon — so the daily audit never ran here. A user timer needs no root and,
  # with Persistent=true, catches up a run missed while the laptop was off or
  # asleep. It runs while the user session is up, which is when a laptop audits.
  mkdir -p "$SYSTEMD_USER_DIR"
  cat >"$SYSTEMD_USER_DIR/$AUDIT_UNIT.service" <<EOF
[Unit]
Description=rh7 fleet audit (gated collector runner)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $REPO_ROOT/scripts/collector-runner.sh
EOF
  cat >"$SYSTEMD_USER_DIR/$AUDIT_UNIT.timer" <<EOF
[Unit]
Description=Daily rh7 fleet audit

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$AUDIT_UNIT.timer"
  say "installed: post-update hook '$HOOK_NAME' and $AUDIT_UNIT.timer (daily, catches up after sleep)"
}

if [ "$MODE" = install ]; then
  install_hook_and_timer
  exit 0
fi

# ── Read the list ────────────────────────────────────────────────────────────
# A machine's list is its host file, configurations/omarchy/hosts/<hostname>.txt.
# A host file holds `profile | <name>` lines (each pulls in
# configurations/omarchy/profiles/<name>.txt) and may add lines of its own.
# Profiles hold only app lines: they cannot pull in other profiles. An app that
# appears in two profiles is installed once. A machine with no host file gets
# hosts/default.txt and a warning: it is not in the fleet's list yet.
if [ "$FROM_HOOK" -eq 1 ]; then
  # New lines merged to main reach this machine on its next `omarchy update`
  # without anyone pulling the checkout. The list is read from the fetched ref,
  # never the working tree, so a local edit or a feature branch is not applied
  # by surprise. A failed fetch falls back to the last fetched origin/main.
  git -C "$REPO_ROOT" fetch --quiet origin main 2>/dev/null \
    || warn "git fetch failed — using the last fetched origin/main"
  REF="origin/main"
fi

# read_rel <path relative to the repo> — from $REF when set, else the working tree.
read_rel() {
  if [ -n "$REF" ]; then
    git -C "$REPO_ROOT" show "$REF:$1" 2>/dev/null
  else
    [ -r "$REPO_ROOT/$1" ] && cat "$REPO_ROOT/$1"
  fi
}
exists_rel() {
  if [ -n "$REF" ]; then
    git -C "$REPO_ROOT" cat-file -e "$REF:$1" 2>/dev/null
  else
    [ -e "$REPO_ROOT/$1" ]
  fi
}
src_prefix() { [ -n "$REF" ] && printf '%s:' "$REF"; return 0; }

[[ $HOST =~ ^[a-z0-9][a-z0-9-]*$ ]] || { warn "bad hostname '$HOST'"; exit 2; }
# 4: a ref that does not resolve would read as "no host file" — say what is wrong.
if [ -n "$REF" ] && ! git -C "$REPO_ROOT" rev-parse --quiet --verify "$REF^{commit}" >/dev/null; then
  warn "ref '$REF' does not resolve in $REPO_ROOT"
  [ "$FROM_HOOK" -eq 0 ] || ! command -v notify-send >/dev/null 2>&1 || notify-send "rh7 apps" "cannot read $REF — nothing installed" || true
  exit 2
fi
HOST_NOTE=""
if [ -n "$LIST_FILE" ]; then
  [ -r "$LIST_FILE" ] || { warn "cannot read $LIST_FILE"; exit 2; }
  LIST_TEXT="$(cat "$LIST_FILE")"
  LIST_DESC="$LIST_FILE"
elif ! exists_rel "$HOSTS_REL" && exists_rel "$LEGACY_LIST_REL"; then
  # A commit from before host files existed (a checkout on this version
  # reading an older origin/main): its one flat list is every machine's list.
  LIST_TEXT="$(read_rel "$LEGACY_LIST_REL")" || { warn "cannot read $(src_prefix)$LEGACY_LIST_REL"; exit 2; }
  LIST_DESC="$(src_prefix)$LEGACY_LIST_REL"
  HOST_NOTE="legacy flat list"
else
  host_rel="$HOSTS_REL/$HOST.txt"
  if ! exists_rel "$host_rel"; then
    host_rel="$HOSTS_REL/default.txt"
    HOST_NOTE="no host file for '$HOST' — using default (add $HOSTS_REL/$HOST.txt)"
    warn "$HOST_NOTE"
  fi
  LIST_TEXT="$(read_rel "$host_rel")" || { warn "cannot read $(src_prefix)$host_rel"; exit 2; }
  LIST_DESC="$(src_prefix)$host_rel"
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

PKG_RE='^[a-z0-9@._+-]+$'
PROFILE_RE='^[a-z0-9][a-z0-9-]*$'
# `kind@<arch>` limits a line to one CPU architecture (the M2 Air runs Omarchy
# on Apple Silicon; some apps have no aarch64 Linux build). Validated on every
# machine, applied only where the arch matches. Override is for the tests.
MACHINE_ARCH="${OMARCHY_APPLY_ARCH:-$(uname -m)}"
KIND=(); F1=(); F2=(); F3=(); SRC_OF=()
declare -A SEEN=() SEEN_SRC=()
PROFILES_USED=()
errors=0
other_arch=0

# `bad` reads parse's locals (bash scopes dynamically), so inside a nested
# profile it names the profile's file and line, and the host file's after.
bad() { warn "$desc line $n: $1: $line"; errors=$((errors + 1)); }
# parse <description> <text> <may include profiles: 1|0>
parse() {
  local desc="$1" text="$2" includes="$3" n=0 raw line k a b c extra only_arch key ptext w words
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    line="$(trim "$raw")"
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r k a b c extra <<<"$line"
    k="$(trim "$k")"; a="$(trim "${a:-}")"; b="$(trim "${b:-}")"; c="$(trim "${c:-}")"
    if [ "$k" = profile ]; then
      [ "$includes" = 1 ] || { bad "a profile cannot pull in another profile"; continue; }
      [[ $a =~ $PROFILE_RE ]] || { bad "not a profile name"; continue; }
      [ -z "$b" ] && [ -z "$c" ] && [ -z "${extra:-}" ] || { bad "profile takes one field"; continue; }
      exists_rel "$PROFILES_REL/$a.txt" || { bad "no such profile ($PROFILES_REL/$a.txt)"; continue; }
      ptext="$(read_rel "$PROFILES_REL/$a.txt")" || { bad "cannot read $(src_prefix)$PROFILES_REL/$a.txt"; continue; }
      PROFILES_USED+=("$a")
      parse "$(src_prefix)$PROFILES_REL/$a.txt" "$ptext" 0
      continue
    fi
    only_arch=""
    if [[ $k == *@* ]]; then
      only_arch="${k#*@}"; k="${k%%@*}"
      case "$only_arch" in x86_64|aarch64) ;; *) bad "unknown architecture '$only_arch' (x86_64 or aarch64)"; continue ;; esac
    fi
    [ -z "${extra:-}" ] || { bad "too many fields"; continue; }
    case "$k" in
      pkg|aur)
        [[ $a =~ $PKG_RE ]] || { bad "not a package name"; continue; }
        [ -z "$b" ] && [ -z "$c" ] || { bad "$k takes one field"; continue; } ;;
      omarchy)
        read -ra words <<<"$a"
        [[ ${words[0]:-} =~ ^omarchy-install-[a-z0-9-]+$ ]] || { bad "must name an omarchy-install-* command"; continue; }
        for w in "${words[@]:1}"; do [[ $w =~ ^[a-z0-9._-]+$ ]] || { bad "unsafe installer argument '$w'"; continue 2; }; done
        a="${words[*]}"
        if [[ $b == app:* ]]; then
          [[ -n ${b#app:} && ${b#app:} != */* ]] || { bad "bad app: presence check"; continue; }
        else
          [[ $b =~ $PKG_RE ]] || { bad "needs a presence check: <package> or app:<launcher name>"; continue; }
        fi
        [ -z "$c" ] || { bad "omarchy takes two fields"; continue; } ;;
      webapp)
        [[ -n $a && $a != */* ]] || { bad "launcher name must be non-empty without '/'"; continue; }
        [[ $b =~ ^https://[^[:space:]]+$ ]] || { bad "web app URL must be https"; continue; }
        [[ -z $c || $c =~ ^https://[^[:space:]]+$ ]] || { bad "icon must be an https URL"; continue; } ;;
      *) bad "unknown kind '$k'"; continue ;;
    esac
    if [ -n "$only_arch" ] && [ "$only_arch" != "$MACHINE_ARCH" ]; then other_arch=$((other_arch + 1)); continue; fi
    key="$k|$a"
    if [ -n "${SEEN[$key]+x}" ]; then
      # The same app twice is fine (two profiles may share it); the same app
      # with a different URL/check is a contradiction, and which one wins
      # would depend on profile order.
      [ "${SEEN[$key]}" = "$b|$c" ] || bad "conflicts with an earlier '$k | $a' line (${SEEN_SRC[$key]})"
      continue
    fi
    SEEN[$key]="$b|$c"; SEEN_SRC[$key]="$desc line $n"
    KIND+=("$k"); F1+=("$a"); F2+=("$b"); F3+=("$c"); SRC_OF+=("$desc line $n")
  done <<<"$text"
}
parse "$LIST_DESC" "$LIST_TEXT" 1

if [ "$errors" -gt 0 ]; then
  warn "$errors invalid line(s) in $LIST_DESC — nothing installed"
  exit 2
fi
if [ "${#KIND[@]}" -eq 0 ] && [ "$other_arch" -eq 0 ]; then
  warn "$LIST_DESC lists no apps — is it truncated?"
fi

# ── Presence ─────────────────────────────────────────────────────────────────
command -v pacman >/dev/null 2>&1 || { warn "pacman not found — this is not an Arch/Omarchy machine"; exit 2; }
pkg_present() { pacman -Q -- "$1" >/dev/null 2>&1; }
app_present() { [ -f "$APPS_DIR/$1.desktop" ]; }
failed_marker() { printf '%s/failed/%s' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')"; }
sentinel_present() {  # index — the line's own check, ignoring any pending marker
  local i="$1"
  case "${KIND[$i]}" in
    pkg|aur) pkg_present "${F1[$i]}" ;;
    omarchy) if [[ ${F2[$i]} == app:* ]]; then app_present "${F2[$i]#app:}"; else pkg_present "${F2[$i]}"; fi ;;
    webapp) app_present "${F1[$i]}" ;;
  esac
}
present() {  # index
  local i="$1"
  if [ "${KIND[$i]}" = omarchy ] && [ -e "$(failed_marker "${F1[$i]}")" ]; then return 1; fi
  sentinel_present "$i"
}
label() {
  local i="$1"
  case "${KIND[$i]}" in
    pkg|aur) printf '%-7s %s' "${KIND[$i]}" "${F1[$i]}" ;;
    omarchy) printf '%-7s %s' omarchy "${F1[$i]}" ;;
    webapp) printf '%-7s %s (%s)' webapp "${F1[$i]}" "${F2[$i]}" ;;
  esac
}

missing=()
for i in ${KIND[@]+"${!KIND[@]}"}; do
  present "$i" || missing+=("$i")
done

arch_note=""
[ "$other_arch" -eq 0 ] || arch_note=" ($other_arch for another architecture)"
profile_note=""
[ "${#PROFILES_USED[@]}" -eq 0 ] || profile_note=" (profiles: ${PROFILES_USED[*]})"
say "omarchy-apply: host $HOST$profile_note"
say "omarchy-apply: ${#KIND[@]} entries for $MACHINE_ARCH in $LIST_DESC, ${#missing[@]} missing$arch_note"
if [ "$FROM_HOOK" -eq 1 ] && [[ $HOST_NOTE == no\ host\ file* ]] && command -v notify-send >/dev/null 2>&1; then
  notify-send "rh7 apps" "$HOST_NOTE" || true
fi
if [ "${#missing[@]}" -eq 0 ]; then exit 0; fi

if [ "$MODE" = plan ]; then
  for i in "${missing[@]}"; do say "  would install: $(label "$i")"; done
  say "run with --apply to install them"
  exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────────────
command -v omarchy-pkg-add >/dev/null 2>&1 || { warn "omarchy-pkg-add not found — is this an Omarchy machine?"; exit 2; }

needs_root=0
for i in "${missing[@]}"; do [ "${KIND[$i]}" = webapp ] || needs_root=1; done
can_root=1
if [ "$needs_root" -eq 1 ]; then
  if [ -t 0 ]; then
    sudo -v || can_root=0
  else
    sudo -n true 2>/dev/null || can_root=0
  fi
fi

failed=(); skipped=(); done_=()
# Several omarchy-install-* scripts have no `set -e` (Tailscale, Zed, VS Code,
# Dropbox): a failed `tailscale up` is followed by steps that succeed, the
# script exits 0, and the package sentinel would read as "done" forever. Run
# bash installers under errexit so the first failing step is the exit status
# and the failed-marker keeps the line pending. Steps an installer means to be
# optional already carry `|| true`.
run_installer() {
  local path first
  path="$(command -v "$1")" || { warn "installer $1 not found"; return 127; }
  IFS= read -r first <"$path" || first=""
  case "$first" in
    '#!'*bash*) bash -e "$path" "${@:2}" ;;
    *) "$@" ;;
  esac
}

for i in "${missing[@]}"; do
  if [ "${KIND[$i]}" != webapp ] && [ "$can_root" -eq 0 ]; then
    skipped+=("$(label "$i")"); continue
  fi
  say "→ $(label "$i")"
  rc=0
  case "${KIND[$i]}" in
    pkg) omarchy-pkg-add "${F1[$i]}" || rc=$? ;;
    aur) omarchy-pkg-aur-add "${F1[$i]}" || rc=$? ;;
    omarchy)
      # Marker first: an installer killed mid-run (reboot, closed terminal)
      # never returns here, and its sentinel alone must not read as done.
      mkdir -p "$STATE_DIR/failed" && : >"$(failed_marker "${F1[$i]}")"
      read -ra words <<<"${F1[$i]}"; run_installer "${words[@]}" || rc=$? ;;
    webapp) omarchy-webapp-install "${F1[$i]}" "${F2[$i]}" "${F3[$i]}" || rc=$? ;;
  esac
  # Trust the presence check over the exit code: an installer can exit 0
  # without installing (pacman sometimes does), or launch-and-return. An
  # installer's marker is cleared only after a verified success.
  if [ "$rc" -eq 0 ] && sentinel_present "$i"; then
    [ "${KIND[$i]}" != omarchy ] || rm -f "$(failed_marker "${F1[$i]}")"
    done_+=("$(label "$i")")
  else
    failed+=("$(label "$i") (${SRC_OF[$i]}, exit $rc)")
  fi
done

say "omarchy-apply: installed ${#done_[@]}, failed ${#failed[@]}, needs a terminal ${#skipped[@]}"
for s in ${failed[@]+"${failed[@]}"};   do say "  FAILED: $s"; done
for s in ${skipped[@]+"${skipped[@]}"}; do say "  not installed (needs sudo; run $REPO_ROOT/scripts/omarchy-apply.sh --apply in a terminal): $s"; done
if [ "${#skipped[@]}" -gt 0 ] && command -v notify-send >/dev/null 2>&1; then
  notify-send "rh7 apps" "${#skipped[@]} app(s) need a terminal: run $REPO_ROOT/scripts/omarchy-apply.sh --apply" || true
fi
[ "${#failed[@]}" -eq 0 ]
