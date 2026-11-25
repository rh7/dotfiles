#!/usr/bin/env bash
# scripts/omarchy-apply.sh — keep an Omarchy machine carrying the apps listed in
# configurations/linux/omarchy-apps.txt.
#
#   omarchy-apply.sh                  plan: show what is missing, change nothing
#   omarchy-apply.sh --apply          install what is missing
#   omarchy-apply.sh --ref <ref>      read the list from a committed ref, not the working tree
#   omarchy-apply.sh --install        install the post-update hook + the daily audit timer
#   omarchy-apply.sh --from-hook      what the post-update hook runs: fetch origin,
#                                     then --apply --ref origin/main
#   omarchy-apply.sh --list <file>    use another list file
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
LIST_REL="configurations/linux/omarchy-apps.txt"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUDIT_UNIT="rh7-fleet-audit"
HOOK_NAME="rh7-apps"

say()  { printf '%s\n' "$*"; }
warn() { printf 'omarchy-apply: %s\n' "$*" >&2; }
usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=plan
REF=""
LIST_FILE=""
FROM_HOOK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --install) MODE=install ;;
    --from-hook) MODE=apply; FROM_HOOK=1 ;;
    --ref) [ $# -ge 2 ] || { usage >&2; exit 64; }; REF="$2"; shift ;;
    --list) [ $# -ge 2 ] || { usage >&2; exit 64; }; LIST_FILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 64 ;;
  esac
  shift
done

# ── --install: post-update hook + daily audit timer ─────────────────────────
install_hook_and_timer() {
  command -v omarchy-hook-install >/dev/null 2>&1 \
    || { warn "omarchy-hook-install not found — is this an Omarchy machine?"; exit 2; }

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  {
    printf '#!/bin/bash\n'
    printf '# rh7/dotfiles: keep the apps in %s installed after every omarchy update.\n' "$LIST_REL"
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
if [ "$FROM_HOOK" -eq 1 ]; then
  # New lines merged to main reach this machine on its next `omarchy update`
  # without anyone pulling the checkout. The list is read from the fetched ref,
  # never the working tree, so a local edit or a feature branch is not applied
  # by surprise. A failed fetch falls back to the last fetched origin/main.
  git -C "$REPO_ROOT" fetch --quiet origin main 2>/dev/null \
    || warn "git fetch failed — using the last fetched origin/main"
  REF="origin/main"
fi

if [ -n "$LIST_FILE" ]; then
  [ -r "$LIST_FILE" ] || { warn "cannot read $LIST_FILE"; exit 2; }
  LIST_TEXT="$(cat "$LIST_FILE")"
  LIST_DESC="$LIST_FILE"
elif [ -n "$REF" ]; then
  LIST_TEXT="$(git -C "$REPO_ROOT" show "$REF:$LIST_REL" 2>/dev/null)" \
    || { warn "cannot read $LIST_REL at $REF"; exit 2; }
  LIST_DESC="$REF:$LIST_REL"
else
  [ -r "$REPO_ROOT/$LIST_REL" ] || { warn "cannot read $REPO_ROOT/$LIST_REL"; exit 2; }
  LIST_TEXT="$(cat "$REPO_ROOT/$LIST_REL")"
  LIST_DESC="$LIST_REL"
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

PKG_RE='^[a-z0-9@._+-]+$'
KIND=(); F1=(); F2=(); F3=(); LINENO_OF=()
errors=0
n=0
line=""
bad() { warn "$LIST_DESC line $n: $1: $line"; errors=$((errors + 1)); }
while IFS= read -r raw || [ -n "$raw" ]; do
  n=$((n + 1))
  line="$(trim "$raw")"
  case "$line" in ''|'#'*) continue ;; esac
  IFS='|' read -r k a b c extra <<<"$line"
  k="$(trim "$k")"; a="$(trim "${a:-}")"; b="$(trim "${b:-}")"; c="$(trim "${c:-}")"
  [ -z "${extra:-}" ] || { bad "too many fields"; continue; }
  case "$k" in
    pkg|aur)
      [[ $a =~ $PKG_RE ]] || { bad "not a package name"; continue; }
      [ -z "$b" ] || { bad "$k takes one field"; continue; } ;;
    omarchy)
      read -ra words <<<"$a"
      [[ ${words[0]:-} =~ ^omarchy-install-[a-z0-9-]+$ ]] || { bad "must name an omarchy-install-* command"; continue; }
      for w in "${words[@]:1}"; do [[ $w =~ ^[a-z0-9._-]+$ ]] || { bad "unsafe installer argument '$w'"; continue 2; }; done
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
  KIND+=("$k"); F1+=("$a"); F2+=("$b"); F3+=("$c"); LINENO_OF+=("$n")
done <<<"$LIST_TEXT"

if [ "$errors" -gt 0 ]; then
  warn "$errors invalid line(s) in $LIST_DESC — nothing installed"
  exit 2
fi

# ── Presence ─────────────────────────────────────────────────────────────────
command -v pacman >/dev/null 2>&1 || { warn "pacman not found — this is not an Arch/Omarchy machine"; exit 2; }
pkg_present() { pacman -Q -- "$1" >/dev/null 2>&1; }
app_present() { [ -f "$APPS_DIR/$1.desktop" ]; }
present() {  # index
  local i="$1"
  case "${KIND[$i]}" in
    pkg|aur) pkg_present "${F1[$i]}" ;;
    omarchy) if [[ ${F2[$i]} == app:* ]]; then app_present "${F2[$i]#app:}"; else pkg_present "${F2[$i]}"; fi ;;
    webapp) app_present "${F1[$i]}" ;;
  esac
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

say "omarchy-apply: ${#KIND[@]} entries in $LIST_DESC, ${#missing[@]} missing"
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
for i in "${missing[@]}"; do
  if [ "${KIND[$i]}" != webapp ] && [ "$can_root" -eq 0 ]; then
    skipped+=("$(label "$i")"); continue
  fi
  say "→ $(label "$i")"
  rc=0
  case "${KIND[$i]}" in
    pkg) omarchy-pkg-add "${F1[$i]}" || rc=$? ;;
    aur) omarchy-pkg-aur-add "${F1[$i]}" || rc=$? ;;
    omarchy) read -ra words <<<"${F1[$i]}"; "${words[@]}" || rc=$? ;;
    webapp) omarchy-webapp-install "${F1[$i]}" "${F2[$i]}" "${F3[$i]}" || rc=$? ;;
  esac
  # Trust the presence check over the exit code: an installer can exit 0
  # without installing (pacman sometimes does), or launch-and-return.
  if [ "$rc" -eq 0 ] && present "$i"; then
    done_+=("$(label "$i")")
  else
    failed+=("$(label "$i") (line ${LINENO_OF[$i]}, exit $rc)")
  fi
done

say "omarchy-apply: installed ${#done_[@]}, failed ${#failed[@]}, needs a terminal ${#skipped[@]}"
for s in ${failed[@]+"${failed[@]}"};   do say "  FAILED: $s"; done
for s in ${skipped[@]+"${skipped[@]}"}; do say "  not installed (needs sudo; run $REPO_ROOT/scripts/omarchy-apply.sh --apply in a terminal): $s"; done
if [ "${#skipped[@]}" -gt 0 ] && command -v notify-send >/dev/null 2>&1; then
  notify-send "rh7 apps" "${#skipped[@]} app(s) need a terminal: run $REPO_ROOT/scripts/omarchy-apply.sh --apply" || true
fi
[ "${#failed[@]}" -eq 0 ]
