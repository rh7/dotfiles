#!/usr/bin/env bash
# Make a new device a sops recipient of secrets/secrets.yaml — the recipient-side
# half of onboarding (rh7/rh-device-management#310, #111).
#
# A new device CANNOT do this itself: re-encrypting the data key requires
# decrypting it first, and the device is not a recipient yet. So this runs on an
# EXISTING recipient (rouvens-mac-studio or m5-air), and it must finish — PR
# merged — BEFORE the device's first secrets-decrypting rebuild.
#
# Run it from a worktree/clone on its own branch, never the live ~/dotfiles:
#   git -C ~/dotfiles fetch origin
#   git -C ~/dotfiles worktree add /tmp/dotfiles-sops-<host> -b sops/add-<host> origin/main
#   cd /tmp/dotfiles-sops-<host> && scripts/sops-add-host.sh <host> [age1pubkey]
#
# Steps, each fatal on failure:
#   1. refuse unless on a non-main branch, clean, and based on current origin/main
#   2. refuse unless THIS host can decrypt secrets/secrets.yaml
#   3. pubkey: the argument, or the device's registered age_public_key from the
#      config service (confirmed interactively — /register is unauthenticated)
#   4. add &<host> under keys: and *<host> to the creation rule (idempotent)
#   5. sops updatekeys, then verify the recipient set really changed
#   6. commit, push the branch, open a PR (never pushes main)
#
# Usage: scripts/sops-add-host.sh <hostname> [age1pubkey]

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_YAML=".sops.yaml"
SECRETS_FILE="secrets/secrets.yaml"
MAIN_BRANCH="main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# shellcheck source=lib/sops-recipients.sh
source "$DOTFILES_DIR/scripts/lib/sops-recipients.sh"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac
[[ $# -le 2 ]] || { usage >&2; exit 2; }
HOST="$1"
PUB="${2:-}"

[[ "$HOST" =~ $SOPS_HOST_RE ]] || die "'$HOST' is not a valid hostname (letters, digits, '-'; use the flake attr name)"
if [[ -n "$PUB" && ! "$PUB" =~ $SOPS_AGE_PUB_RE ]]; then
  die "'$PUB' is not an age public key (expected age1 + 58 lowercase bech32 chars)"
fi

cd "$DOTFILES_DIR"

for tool in git sops gh; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found on PATH"
done

# On macOS sops looks in ~/Library/Application Support/sops/age/keys.txt; the
# fleet keeps keys in ~/.config/sops/age/keys.txt (#111).
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[[ -r "$SOPS_AGE_KEY_FILE" ]] || die "no age key at $SOPS_AGE_KEY_FILE — run this on an existing recipient (rouvens-mac-studio or m5-air)"

# ── 1. Git guard ────────────────────────────────────────────────────────────
BRANCH=$(git symbolic-ref --quiet --short HEAD) || die "detached HEAD — check out a branch (see --help)"
case "$BRANCH" in
  main|master) die "refusing to run on '$BRANCH'. Create a worktree on a branch (see --help); this script never commits to $MAIN_BRANCH." ;;
esac
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  die "tracked changes present — commit or discard them first, so the commit below contains only this recipient change"
fi
info "Fetching origin/$MAIN_BRANCH..."
git fetch --quiet origin "$MAIN_BRANCH" || die "git fetch origin $MAIN_BRANCH failed"
git merge-base --is-ancestor "origin/$MAIN_BRANCH" HEAD \
  || die "branch '$BRANCH' is not based on current origin/$MAIN_BRANCH — rebase it first (re-keying stale ciphertext would revert newer secret changes)"
ok "On branch $BRANCH, clean, based on origin/$MAIN_BRANCH"

# ── 2. This host must be a recipient ────────────────────────────────────────
[[ -f "$SECRETS_FILE" ]] || die "$SECRETS_FILE not found"
sops -d "$SECRETS_FILE" >/dev/null 2>&1 \
  || die "this host cannot decrypt $SECRETS_FILE with $SOPS_AGE_KEY_FILE — only an existing recipient can add one"
ok "This host decrypts $SECRETS_FILE"

# ── 3. Resolve the device's public key ──────────────────────────────────────
if [[ -z "$PUB" ]]; then
  # shellcheck source=lib/config-service.sh
  source "$DOTFILES_DIR/scripts/lib/config-service.sh"
  load_config_service_resolver "$DOTFILES_DIR" || die "could not load the config-service resolver from scripts/collector-runner.sh"
  BASE=$(find_config_service)
  [[ -n "$BASE" ]] || die "config service not reachable — pass the key printed by the device: $0 $HOST age1..."
  info "Looking up $HOST in $BASE..."
  DEVICE_JSON=$(curl -sf --max-time 10 "$BASE/api/devices/$HOST") \
    || die "$HOST is not registered at $BASE (or the request failed). On the device run scripts/setup-secrets.sh, or pass the key explicitly."
  read -r PUB SEEN < <(printf '%s' "$DEVICE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("age_public_key") or "-", d.get("last_seen") or "unknown")
') || die "could not parse the config-service response for $HOST"
  [[ "$PUB" =~ $SOPS_AGE_PUB_RE ]] || die "$HOST has no valid age_public_key registered (got '$PUB') — run scripts/setup-secrets.sh on the device"

  # /api/devices/register is unauthenticated on the tailnet: anything can
  # register a key under any hostname. Encrypting the fleet's secrets to it and
  # pushing that to a PUBLIC repo is irreversible, so a human compares the key
  # with what the device printed.
  echo ""
  echo "  Registered age key for $HOST (last seen $SEEN):"
  echo "    $PUB"
  echo ""
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "no terminal to confirm the registry key — re-run with it as an argument after comparing it with the device output: $0 $HOST $PUB"
  fi
  printf 'Does this match the key printed on the device? [y/N] '
  read -r answer <&3 || answer=""
  exec 3<&-
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || die "not confirmed — nothing changed"
fi
info "Device: $HOST"
info "Key:    $PUB"

# From here on, a failure must not leave a half-edited tree behind (the clean
# guard above would then refuse every re-run). Restore both files on any error
# until the commit lands.
COMMITTED=false
restore_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]] && ! $COMMITTED; then
    git checkout --quiet HEAD -- "$SOPS_YAML" "$SECRETS_FILE" 2>/dev/null \
      && err "Restored $SOPS_YAML and $SECRETS_FILE to HEAD — nothing was committed"
  fi
}
trap restore_on_error EXIT

# ── 4. Declare the recipient in .sops.yaml ──────────────────────────────────
rc=0
sops_yaml_add_recipient "$SOPS_YAML" "$HOST" "$PUB" || rc=$?
case "$rc" in
  0)  ok "Added &$HOST to keys: and *$HOST to the secrets/secrets.yaml creation rule" ;;
  10) info "No change to $SOPS_YAML: $HOST is already declared with this key" ;;
  *)  die "$SOPS_YAML not changed" ;;
esac

# ── 5. Re-encrypt the data key to the declared set ──────────────────────────
BEFORE=$(sops_metadata_recipients "$SECRETS_FILE")
if grep -qxF "$PUB" <<<"$BEFORE"; then
  info "No change to $SECRETS_FILE: $HOST is already a recipient"
  [[ "$rc" -eq 10 ]] || die "$SECRETS_FILE already lists this key but $SOPS_YAML did not — declared≠applied drift; fix by hand"
else
  info "Running sops updatekeys..."
  sops updatekeys -y "$SECRETS_FILE" || die "sops updatekeys failed"
  AFTER=$(sops_metadata_recipients "$SECRETS_FILE")
  grep -qxF "$PUB" <<<"$AFTER" || die "sops updatekeys ran but $PUB is still not a recipient of $SECRETS_FILE"
  DROPPED=$(comm -23 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))
  [[ -z "$DROPPED" ]] || die "sops updatekeys REMOVED recipient(s): $DROPPED — $SOPS_YAML and the file had drifted; resolve by hand"
  EXTRA=$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -vxF "$PUB" || true)
  [[ -z "$EXTRA" ]] || warn "updatekeys also added previously-declared-but-unapplied recipient(s): $EXTRA"
  sops -d "$SECRETS_FILE" >/dev/null 2>&1 || die "this host can no longer decrypt $SECRETS_FILE after updatekeys"
  ok "$HOST is now a recipient of $SECRETS_FILE ($(grep -c . <<<"$AFTER") recipients)"
fi

# ── 6. Commit, push the branch, open a PR ───────────────────────────────────
if [[ -n "$(git status --porcelain --untracked-files=no -- "$SOPS_YAML" "$SECRETS_FILE")" ]]; then
  git add -- "$SOPS_YAML" "$SECRETS_FILE"
  git commit --quiet -m "sops: add $HOST as a recipient of $SECRETS_FILE" \
    -m "Declares &$HOST in .sops.yaml and re-encrypts the data key with sops updatekeys, so $HOST can decrypt on its first rebuild." \
    -m "Generated by scripts/sops-add-host.sh. Refs rh7/rh-device-management#310" \
    || die "git commit failed"
  ok "Committed on $BRANCH"
  NEW_COMMIT=true
else
  NEW_COMMIT=false
fi
COMMITTED=true

if git diff --quiet "origin/$MAIN_BRANCH" HEAD -- "$SOPS_YAML" "$SECRETS_FILE"; then
  info "No change: $HOST is already a recipient on origin/$MAIN_BRANCH — nothing to commit or publish"
  exit 0
fi

$NEW_COMMIT || info "Nothing new to commit — $BRANCH already carries this change; making sure it is pushed and has a PR"
info "Pushing $BRANCH..."
git push --quiet -u origin "HEAD:refs/heads/$BRANCH" || die "git push failed — commit is on local branch $BRANCH; re-run this script to retry"

if PR_URL=$(gh pr view "$BRANCH" --json url --jq .url 2>/dev/null) && [[ -n "$PR_URL" ]]; then
  ok "PR already open: $PR_URL"
else
  PR_URL=$(gh pr create --base "$MAIN_BRANCH" --head "$BRANCH" \
    --title "sops: add $HOST as a recipient of $SECRETS_FILE" \
    --body "Adds \`$HOST\` (\`$PUB\`) to \`.sops.yaml\` and re-encrypts \`$SECRETS_FILE\` via \`sops updatekeys\`, generated by \`scripts/sops-add-host.sh\`.

Merge BEFORE $HOST's first secrets-decrypting rebuild. Then on $HOST: \`git -C ~/dotfiles pull --ff-only && ~/dotfiles/scripts/setup-secrets.sh\`.

Refs rh7/rh-device-management#310") || die "gh pr create failed — branch $BRANCH is pushed; open the PR by hand"
  ok "PR opened: $PR_URL"
fi

echo ""
echo "Next: merge the PR, then on $HOST:"
echo "  git -C ~/dotfiles pull --ff-only && ~/dotfiles/scripts/setup-secrets.sh"
