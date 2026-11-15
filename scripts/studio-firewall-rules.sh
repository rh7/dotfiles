#!/usr/bin/env bash
# scripts/studio-firewall-rules.sh — per-app application-firewall rules for the
# Mac Studio (rouvens-mac-studio). Never run from ~/dotfiles:
# configurations/macos/mac-studio-firewall.nix copies THIS file into the nix
# store and wraps it, with the host's rule list baked in, as
# /run/current-system/sw/bin/rh7-studio-firewall-rules. Read that module's
# header for the design (which listener is allowed or blocked, and why).
#
#   rh7-studio-firewall-rules            apply (root): converge the rules, quiet
#                                        when nothing changes
#   rh7-studio-firewall-rules --check    read-only (any user): print the drift,
#                                        exit 1 if there is any
#
# Wrapper arguments (from the module, not for hand use):
#   --allow PATH   PATH may accept incoming connections
#   --block PATH   PATH may not accept incoming connections
#
# WHY RESOLVE AND RE-APPLY: the firewall keys an app by the path it was added
# under, and the binaries that need a rule are ad-hoc signed (no Developer ID,
# so "allow downloaded signed software" does not cover them). Their real paths
# move: a nix-store path changes with every rebuild, a Homebrew Cellar path
# with every `brew upgrade`, and the config service's restic rest-server is an
# out-link rh7/rh-device-management repoints. The wrapper therefore names a
# STABLE path (a profile or opt/ symlink), this script resolves it to the real
# binary on every run and adds a rule for that, and the module runs it on
# every activation and from a LaunchDaemon every 10 minutes, so a path that
# moved between rebuilds gets its rule back without one.
#
# A rule for a path that no longer exists under /nix/store/ or
# /opt/homebrew/Cellar/ is stale (an old generation, an upgraded formula) and
# is removed. Rules elsewhere (the ones macOS keeps itself) are never touched.
#
# Exit: 0 converged (apply) / no drift (check); 1 a rule could not be set, or
# drift (check); 64 usage.
set -uo pipefail

SFW="${STUDIO_FW_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
# Space-separated; the override exists for scripts/tests only.
read -r -a STALE_PREFIXES <<<"${STUDIO_FW_STALE_PREFIXES:-/nix/store/ /opt/homebrew/Cellar/}"

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
die_usage() { echo "studio-firewall-rules: $*" >&2; exit 64; }

mode=apply
want_path=()
want_state=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --allow|--block)
      [ $# -ge 2 ] || die_usage "$1 needs a path"
      want_state+=("${1#--}")
      want_path+=("$2")
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done
[ "${#want_path[@]}" -gt 0 ] || die_usage "no --allow/--block rules given"

log() { echo "studio-firewall-rules: $*"; }

# rules — "<allow|block>\t<path>" per app in the firewall's list. --listapps
# prints "N : <path> " then an indented "(Allow|Block incoming connections)".
rules() {
  "$SFW" --listapps 2>/dev/null | awk '
    /^[0-9]+ : / { sub(/^[0-9]+ : /, ""); sub(/[ \t]+$/, ""); p = $0; next }
    /\(Allow incoming connections\)/ { if (p != "") print "allow\t" p; p = ""; next }
    /\(Block incoming connections\)/ { if (p != "") print "block\t" p; p = ""; next }
  '
}

# state_of <path> — allow | block | "" (not in the list)
state_of() {
  printf '%s\n' "$current" | awk -F'\t' -v p="$1" '$2 == p { print $1; exit }'
}

current="$(rules)"
drift=0
failed=0
missing=0
desired=""   # resolved paths this run wants, one per line

for i in "${!want_path[@]}"; do
  path="${want_path[$i]}"
  want="${want_state[$i]}"
  if [ ! -e "$path" ]; then
    log "warning: $path does not exist — no $want rule for it"
    missing=$((missing + 1))
    continue
  fi
  real="$(realpath "$path")"
  desired="$desired$real"$'\n'
  have="$(state_of "$real")"
  [ "$have" = "$want" ] && continue
  drift=$((drift + 1))
  if [ "$mode" = check ]; then
    log "drift: $real is ${have:-not in the list}, want $want (from $path)"
    continue
  fi
  [ -n "$have" ] || "$SFW" --add "$real" >/dev/null
  if [ "$want" = allow ]; then "$SFW" --unblockapp "$real" >/dev/null; else "$SFW" --blockapp "$real" >/dev/null; fi
  current="$(rules)"
  have="$(state_of "$real")"
  if [ "$have" = "$want" ]; then
    log "$want $real (from $path)"
  else
    log "error: could not set $want for $real (firewall reports: ${have:-not in the list})"
    failed=$((failed + 1))
  fi
done

# Stale rules: a store / Cellar path that is gone and that this run does not want.
while IFS=$'\t' read -r _ p; do
  [ -n "$p" ] || continue
  stale=0
  for prefix in "${STALE_PREFIXES[@]}"; do
    case "$p" in "$prefix"*) stale=1 ;; esac
  done
  [ "$stale" = 1 ] && [ ! -e "$p" ] || continue
  printf '%s' "$desired" | grep -qxF -- "$p" && continue
  drift=$((drift + 1))
  if [ "$mode" = check ]; then
    log "drift: stale rule for $p (path gone)"
  elif "$SFW" --remove "$p" >/dev/null; then
    log "removed stale rule for $p"
  else
    log "error: could not remove the stale rule for $p"
    failed=$((failed + 1))
  fi
done <<<"$current"

if [ "$mode" = check ]; then
  log "drift=$drift missing=$missing"
  [ "$drift" -eq 0 ]
  exit
fi
[ "$failed" -eq 0 ]
