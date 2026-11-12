#!/usr/bin/env bash
# new-host.sh — generate a Mac's flake entry + host file from its real audit.
#
# Owner-side half of adopting a Mac (the device-side half is scripts/adopt.sh,
# which stops and points here when its hostname has no flake entry). Run it on
# an owner machine with the control plane reachable (and `gh` for --apply),
# from any rh7/dotfiles clone — it reads origin/main, never the working tree,
# and --apply works in its own /tmp worktree:
#
#   scripts/new-host.sh <hostname> [--role household|personal|workstation]
#                       [--user <primary>] [--apply]
#
# Inputs: the device's latest audit (GET /api/audit/<host>) and its gaps
# (GET /api/audit/gaps/<host>) from the config service, plus Homebrew's cask
# catalogue (https://formulae.brew.sh/api/cask.json — the same data as
# `brew info --json=v2 --cask`; cached a day under ~/.cache/rh7-new-host).
#
# What it generates — `configurations/macos/<host>.nix` + a `mkMac` entry:
#   homebrew.casks  ADOPT only: an app already in /Applications whose bundle
#                   name is EXACTLY a cask's app artifact (a stable cask wins
#                   over @beta/@nightly variants; otherwise the one whose token
#                   is the slugged name; still ambiguous → commented), plus the
#                   server's present_unmanaged / unmanaged_casks. Never adds;
#                   apps only in a user's ~/Applications are never adopted.
#   manual block    commented, with the reason: Adobe/Maxon vendor installers,
#                   Tailscale + VPN clients (network-critical), casks DISABLED
#                   upstream, pkg-installer casks (need root on install),
#                   ambiguous matches. Deprecated casks are adopted, marked.
#   MAS apps        commented (id + name when the audit has `mas`, else the
#                   App Store receipt names from application_bundles) — never
#                   declared, and never adopted as casks (rebuild.sh would
#                   replace the App Store copy with the Homebrew one).
#   role defaults   household (default): role household-mac.nix,
#                   homeProfile "household", needsSecrets = false, no Dock;
#                   personal: role personal-mac.nix, needsSecrets = false;
#                   workstation: the default role, needsSecrets (sops) on.
#                   All: autoUpdate = "fleet/stable". A role file that
#                   hard-codes another account's /Users/<name>/ is refused.
#
# PUBLIC REPO HYGIENE: crypto wallets — by name pattern AND by the cask
# catalogue's description/display name — are dropped and only COUNTED, never
# named; apps without an exact cask and ~/Applications apps are only counted;
# no serial number, user file name or other audit detail is written. The run
# fails (exit 2) if the device's serial or a dropped wallet name would appear
# in the output.
#
# Modes:
#   (default)  dry-run — print the generated host file and the flake.nix diff.
#   --apply    create branch add-host/<host> in a /tmp worktree from
#              origin/main, commit, push, open a PR (gh), remove the worktree.
#
# Other flags (mainly for tests/offline use):
#   --config-service URL   instead of the fleet resolver (pin → probe)
#   --audit-file F --gaps-file F --cask-db F   local JSON instead of fetching
#   --base-ref REF         read flake.nix/roles from REF (default origin/main)
#   --no-fetch             do not `git fetch origin main` first
#   --out DIR              also write the generated files to DIR
#
# Exit: 0 ok, 1 error (no audit, entry exists, invalid nix…), 2 hygiene guard,
#       64 usage.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_API_URL="${NEW_HOST_CASK_API_URL:-https://formulae.brew.sh/api/cask.json}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rh7-new-host"
OWNER_ACCOUNTS="rouven rouvenheck"

HOST=""; ROLE=household; PUSER=""; APPLY=false; CS=""; AUDIT_FILE=""; GAPS_FILE=""
CASK_DB=""; BASE_REF=origin/main; FETCH=true; OUT_DIR=""

die()  { echo "new-host: $*" >&2; exit 1; }
info() { echo "new-host: $*" >&2; }
usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --role)            [ $# -ge 2 ] || { usage >&2; exit 64; }; ROLE="$2"; shift 2 ;;
    --user)            [ $# -ge 2 ] || { usage >&2; exit 64; }; PUSER="$2"; shift 2 ;;
    --apply)           APPLY=true; shift ;;
    --config-service)  [ $# -ge 2 ] || { usage >&2; exit 64; }; CS="${2%/}"; shift 2 ;;
    --audit-file)      [ $# -ge 2 ] || { usage >&2; exit 64; }; AUDIT_FILE="$2"; shift 2 ;;
    --gaps-file)       [ $# -ge 2 ] || { usage >&2; exit 64; }; GAPS_FILE="$2"; shift 2 ;;
    --cask-db)         [ $# -ge 2 ] || { usage >&2; exit 64; }; CASK_DB="$2"; shift 2 ;;
    --base-ref)        [ $# -ge 2 ] || { usage >&2; exit 64; }; BASE_REF="$2"; shift 2 ;;
    --no-fetch)        FETCH=false; shift ;;
    --out)             [ $# -ge 2 ] || { usage >&2; exit 64; }; OUT_DIR="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "new-host: unknown option $1" >&2; usage >&2; exit 64 ;;
    *)                 [ -z "$HOST" ] || { echo "new-host: one hostname only" >&2; exit 64; }; HOST="$1"; shift ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 64; }
# The hostname becomes a flake attr, a file name and a branch name.
[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "invalid hostname '$HOST' (letters, digits, dashes)"
case "$ROLE" in household|personal|workstation) ;; *) die "--role must be household, personal or workstation" ;; esac
[ -z "$PUSER" ] || [[ "$PUSER" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "invalid --user '$PUSER'"
command -v jq >/dev/null || die "needs jq"
command -v git >/dev/null || die "needs git"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/new-host.XXXXXX")
WT=""
cleanup() {
  if [ -n "$WT" ] && [ -d "$WT" ]; then git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── base: origin/main, never the working tree ───────────────────────────────
if $FETCH; then git -C "$REPO" fetch --quiet origin main || die "git fetch origin main failed"; fi
git -C "$REPO" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || die "unknown ref $BASE_REF"
show() { git -C "$REPO" show "$BASE_REF:$1"; }
show flake.nix >"$WORK/flake.base.nix" || die "no flake.nix at $BASE_REF"

# Case-insensitively: macOS hostnames and the default APFS volume are, so
# `foo-mac` next to an existing `Foo-Mac` would be a second entry for the same
# Mac and could overwrite its host module.
host_lc=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
existing=$(sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*=[[:space:]]*mk(Mac|NixOS)[[:space:]]*\{.*/\1/p' "$WORK/flake.base.nix" |
  awk -v h="$host_lc" 'tolower($0) == h { print; exit }')
[ -z "$existing" ] || die "'$existing' already has a flake entry at $BASE_REF — nothing to generate (run adopt.sh on the Mac; rename it with scutil if the names differ only by case)"
existing=$(git -C "$REPO" ls-tree --name-only "$BASE_REF" configurations/macos/ |
  awk -v f="configurations/macos/$host_lc.nix" 'tolower($0) == f { print; exit }')
[ -z "$existing" ] || die "$existing already exists at $BASE_REF"

# ── inputs ───────────────────────────────────────────────────────────────────
if [ -z "$AUDIT_FILE" ] || [ -z "$GAPS_FILE" ]; then
  if [ -z "$CS" ]; then
    # shellcheck source=lib/config-service.sh
    . "$REPO/scripts/lib/config-service.sh"
    load_config_service_resolver "$REPO" || die "could not load the config-service resolver"
    CS=$(find_config_service)
    [ -n "$CS" ] || die "config service unreachable (Tailscale?) — or pass --config-service URL"
  fi
fi
if [ -z "$AUDIT_FILE" ]; then
  AUDIT_FILE="$WORK/audit.json"
  curl -sf --max-time 30 "$CS/api/audit/$HOST" -o "$AUDIT_FILE" ||
    die "no audit for $HOST at $CS — on the Mac run adopt.sh (it offers one audit) or: curl -fsSL https://config.rh7labs.com/collector-runner | bash"
fi
if [ -z "$GAPS_FILE" ]; then
  GAPS_FILE="$WORK/gaps.json"
  curl -sf --max-time 30 "$CS/api/audit/gaps/$HOST" -o "$GAPS_FILE" || die "could not fetch $CS/api/audit/gaps/$HOST"
fi
jq -e 'type == "object" and (.applications | type == "array")' "$AUDIT_FILE" >/dev/null ||
  die "audit for $HOST has no applications list"
jq -e 'type == "object"' "$GAPS_FILE" >/dev/null || die "gaps payload for $HOST is not an object"

if [ -z "$CASK_DB" ]; then
  mkdir -p "$CACHE_DIR"
  CASK_DB="$CACHE_DIR/cask.json"
  if [ -z "$(find "$CASK_DB" -mmin -1440 2>/dev/null)" ]; then
    info "downloading Homebrew's cask catalogue ($CASK_API_URL)"
    curl -fsSL --max-time 120 "$CASK_API_URL" -o "$CASK_DB.tmp" && mv -f "$CASK_DB.tmp" "$CASK_DB" ||
      { rm -f "$CASK_DB.tmp"; [ -s "$CASK_DB" ] && info "download failed — using the cached copy" || die "cannot download $CASK_API_URL and no cached copy"; }
  fi
fi
jq -e 'type == "array" and length > 0 and (.[0] | has("token"))' "$CASK_DB" >/dev/null || die "$CASK_DB is not a Homebrew cask catalogue"

# ── primary user ─────────────────────────────────────────────────────────────
if [ -z "$PUSER" ]; then
  users=$(jq -r '.user_accounts.users[]?.username // empty' "$AUDIT_FILE")
  others=""
  for u in $users; do case " $OWNER_ACCOUNTS " in *" $u "*) ;; *) others="$others $u" ;; esac; done
  set -- $others
  if [ $# -eq 1 ]; then PUSER="$1"
  elif [ $# -eq 0 ] && [ -n "$users" ] && [ "$ROLE" = workstation ]; then
    PUSER=$(printf '%s\n' $users | head -n 1)
  else
    die "cannot pick the primary (daily) user from the audit (accounts:$(printf ' %s' $users)) — pass --user <name>"
  fi
  [[ "$PUSER" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "audit account name '$PUSER' is not a valid username — pass --user"
fi
if ! jq -e --arg u "$PUSER" '[.user_accounts.users[]?.username] | index($u) != null' "$AUDIT_FILE" >/dev/null; then
  info "warning: '$PUSER' is not among the audited accounts — check --user"
fi

# ── casks the role already declares (personal/workstation) ──────────────────
# Text extraction over the role file and the modules it imports (origin/main):
# quoted tokens inside `homebrew.casks = [ … ];`. A dedupe aid only — the role
# would install them anyway.
ROLE_FILE=""
case "$ROLE" in
  personal)    ROLE_FILE=modules/roles/personal-mac.nix ;;
  workstation) ROLE_FILE=modules/roles/workstation-mac.nix ;;
esac
# A role that hard-codes another account's home (personal-mac.nix's Dock is
# Kassie's: /Users/kassie/Applications/CC.app) would write broken entries into
# this user's Dock. Refuse rather than generate that.
if [ -n "$ROLE_FILE" ]; then
  foreign=$(show "$ROLE_FILE" | sed 's/#.*//' | grep -oE '/Users/[A-Za-z0-9_.-]+/' | sort -u |
    grep -vx "/Users/$PUSER/" || true)
  [ -z "$foreign" ] || die "role $ROLE ($ROLE_FILE) hard-codes $(echo $foreign | tr ' ' ',') — it only fits that user; use --role household (or make the role use system.primaryUser)"
fi
role_casks() {
  local f="$1" seen="$2" dir imp
  case " $seen " in *" $f "*) return 0 ;; esac
  seen="$seen $f"
  show "$f" 2>/dev/null >"$WORK/role.cur" || return 0
  sed 's/#.*//' "$WORK/role.cur" | awk '
    /homebrew\.casks[[:space:]]*=[[:space:]]*\[/ { f=1 }
    f { while (match($0, /"[^"]+"/)) { print substr($0, RSTART+1, RLENGTH-2); $0 = substr($0, RSTART+RLENGTH) } }
    f && /\]/ { f=0 }'
  dir=$(dirname "$f")
  for imp in $(sed 's/#.*//' "$WORK/role.cur" | grep -oE '\.\./[A-Za-z0-9_./-]+\.nix|\./[A-Za-z0-9_./-]+\.nix'); do
    role_casks "$(printf '%s/%s\n' "$dir" "$imp" | sed -e 's|/\./|/|g' -e ':a' -e 's|[^/][^/]*/\.\./||' -e 'ta')" "$seen"
  done
}
if [ -n "$ROLE_FILE" ]; then
  role_casks "$ROLE_FILE" "" | sort -u | jq -R . | jq -s . >"$WORK/role-casks.json"
else
  echo '[]' >"$WORK/role-casks.json"
fi

# ── classify (one jq program; deny lists live here) ──────────────────────────
jq -n \
  --slurpfile db "$CASK_DB" --slurpfile audit "$AUDIT_FILE" --slurpfile gaps "$GAPS_FILE" \
  --slurpfile rolec "$WORK/role-casks.json" '
  # Crypto wallets: dropped and only counted (never named in the public repo).
  # By name (apps without a cask, App Store names) AND by the cask catalogue
  # (description/display name), so e.g. a wallet whose token is a company
  # name is still caught.
  def wallet: test("wallet|ledger|trezor|exodus|electrum|keepkey|cypherock|mycrypto|metamask|sparrow|wasabi|coinomi|bitbox|monero|bitcoin|ethereum|beaconchain|zerion|wagyu|staking|blockstream|coinbase|binance|kraken|rabby|onekey|zengo|tangem|bitkey|muun|coldcard|^crypto pro$|cryptowatch"; "i");
  def walletdesc: test("\\bwallet|bitcoin|ethereum|cryptocurrenc|blockchain|monero|litecoin|cardano|\\bcoins\\b|\\bdefi\\b|web3|\\bnft|ledger"; "i");
  def vendor: test("^adobe|maxon|cinema[- ]?4d|^redshift|creative[- ]cloud"; "i");
  def network: test("^tailscale"; "i");
  def vpn: test("vpn|tunnelblick|private-internet-access|wireguard|globalprotect|forticlient|viscosity|windscribe|surfshark|openvpn|cisco"; "i");
  def clean: gsub("[^[:print:]]"; "") | .[0:80];
  def appnames: [ .artifacts[]? | select(type == "object" and has("app")) | .app[]
                  | if type == "string" then . elif type == "object" then (.target // empty) else empty end
                  | sub(".*/"; "") | sub("\\.app$"; "") ];
  def haspkg: [ .artifacts[]? | select(type == "object") | keys[] ] | any(. == "pkg" or . == "installer");
  # pkg casks ship no app artifact; their uninstall stanza names the bundle.
  def pkgapps: [ .artifacts[]? | select(type == "object" and has("uninstall")) | .uninstall[]?
                 | select(type == "object") | (.delete // empty) | if type == "array" then .[] else . end
                 | select(type == "string" and test("^/Applications/[^/]+\\.app$"))
                 | sub(".*/"; "") | sub("\\.app$"; "") ];

  ($db[0] | map({ token, apps: (appnames as $n | if ($n | length) > 0 then $n else pkgapps end),
                  names: [ .name[]? | select(type == "string") ],
                  walletcask: (((.desc // "") | walletdesc) or ([ .name[]? | select(type == "string") ] | any(wallet))),
                  deprecated: (.deprecated // false), disabled: (.disabled // false), pkg: haspkg })) as $casks
  | ($casks | map({ key: .token, value: . }) | from_entries) as $bytoken
  | (reduce ($casks[] | . as $c | .apps[] | { n: ., t: $c.token }) as $x ({}; .[$x.n] += [$x.t])) as $byapp
  | $audit[0] as $a | $gaps[0] as $g | ($rolec[0] // []) as $rc
  | (($a.mas_apps | type) == "object" and $a.mas_apps.installed == true) as $hasmas
  | (if $hasmas then [ $a.mas_apps.apps[]? | .name | select(type == "string") ] else [] end) as $masnames
  # Where each app lives: application_bundles (location + App Store receipt)
  # when the audit has it; else the merged name list, which cannot tell
  # ~/Applications or App Store copies apart (only `mas` names help then).
  | (($a.application_bundles | type) == "array") as $hasbundles
  | (if $hasbundles then [ $a.application_bundles[] | select(type == "object" and (.name | type) == "string") ] else [] end) as $bundles
  | (if $hasbundles then [ $bundles[] | select(.location == "system") | .name ]
     else ($a.applications | map(select(type == "string"))) end) as $sysapps
  | (if $hasbundles then [ $bundles[] | select(.location == "user") | .name ] else [] end) as $userapps
  | ([ $bundles[] | select(.app_store == true) | .name ] + $masnames) as $storenames
  | ($storenames | map({ key: ., value: true }) | from_entries) as $isstore
  | ($sysapps | map({ key: ., value: true }) | from_entries) as $issys
  | ($sysapps | map(select($isstore[.] | not))) as $apps
  | ($sysapps + $userapps + $storenames | unique) as $allnames
  | def pick($app; $c):
      if ($c | length) == 1 then $c[0]
      else ($c | map(select(contains("@") | not))) as $plain
        | if ($plain | length) == 1 then $plain[0]
          else ($app | ascii_downcase | gsub("[[:space:]]+"; "-")) as $slug
            | ($plain | map(select(. == $slug))) as $s
            | if ($s | length) == 1 then $s[0] else null end
          end
      end;
    # 1) exact app-bundle matches for every system-wide, non-App-Store app
    ([ $apps[] | . as $n | ($byapp[$n] // []) as $c
       | select($c | length > 0) | { app: $n, token: pick($n; $c), cands: $c } ]) as $matched
  | ($matched | map(select(.token == null))) as $ambiguous
  | ($matched | map(select(.token != null)) | map({ app, token })) as $exact
  # 2) the server gap lists (catalogue aliases + brew-installed casks)
  | ([ (($g.present_unmanaged // []) + ($g.unmanaged_casks // []))[] | select(type == "string") ]
     | unique | map(select(. as $t | ($exact | map(.token) | index($t)) == null))
     | map({ app: null, token: ., gap: true })) as $fromgaps
  | ($exact + $fromgaps) as $cands
  | [ $cands[] | . as $x | ($bytoken[$x.token] // null) as $c
      | ([ $x.app // empty ] + ($c.apps // [])) as $names
      | if ($names | any(wallet)) or ($x.token | wallet) or ($c.walletcask // false) then . + { class: "wallet" }
        elif ($names | any($isstore[.] // false)) then . + { class: "store" }
        # A gap-list app present only in ~/Applications: declaring it would
        # install a second, system-wide copy.
        elif ($x.gap // false) and ($c != null) and ($c.apps | length) > 0
             and ($c.apps | any($issys[.] // false) | not) and ($c.apps | any(. as $n | $userapps | index($n))) then . + { class: "user" }
        elif ($rc | index($x.token)) != null then . + { class: "role" }
        elif ($x.token | vendor) or ($names | any(vendor)) then . + { class: "manual", why: "licensed vendor installer (Adobe/Maxon) — keeps its own updater" }
        elif ($x.token | network) then . + { class: "manual", why: "network-critical — adopt later, deliberately, with local access" }
        elif ($x.token | vpn) or ($names | any(vpn)) then . + { class: "manual", why: "VPN client — network-critical, system extension/pkg" }
        elif $c == null then . + { class: "manual", why: "not in Homebrew'"'"'s cask catalogue (renamed or removed?)" }
        elif $c.disabled then . + { class: "manual", why: "cask DISABLED upstream" }
        elif $c.pkg then . + { class: "manual", why: "pkg installer (needs root on install)" }
        else . + { class: "adopt", deprecated: $c.deprecated }
        end ] as $classified
  | ([ $apps[] | select(wallet | not) | select(($byapp[.] // []) | length == 0) ] | length) as $unmatched
  # App Store apps: ids when `mas` ran, else receipt names; wallets dropped.
  | (if $hasmas then [ $a.mas_apps.apps[]? | { id: (.id | tostring), name: (.name | clean) } ] else [] end) as $masids
  | ($masids + [ $bundles[] | select(.app_store == true) | .name | clean
                 | . as $n | select(($masids | map(.name) | index($n)) == null) | { id: null, name: $n } ]) as $mas
  # Names that must never be written: every wallet-looking app, cask token and
  # cask display name (the hygiene guard greps the output for each).
  | ([ ($classified[] | select(.class == "wallet") | (.app // empty), .token, (($bytoken[.token].names // [])[])),
       ($allnames[] | select(wallet)) ] | unique) as $wnames
  | {
      adopt:     [ $classified[] | select(.class == "adopt") | { token, deprecated } ] | unique_by(.token),
      manual:    [ $classified[] | select(.class == "manual") | { token, why } ] | unique_by(.token),
      role:      [ $classified[] | select(.class == "role") | .token ] | unique,
      # Dropped when one of its casks is already classified (e.g. via the
      # server gap list) or when it is a wallet.
      ambiguous: [ $ambiguous[] | select(.app | wallet | not)
                   | select(.cands | any(. as $t | ($bytoken[$t].walletcask // false)) | not)
                   | select(.cands | any(. as $t | $classified | map(.token) | index($t)) | not)
                   | { app: (.app | clean), cands: (.cands | map(select(contains("@") | not))) } ],
      mas:       [ $mas[] | select(.name | wallet | not) ] | sort_by(.name | ascii_downcase),
      # every wallet-looking app, with or without a cask, App Store or not
      wallets:   ([ ($classified[] | select(.class == "wallet") | (.app // .token)),
                    ($allnames[] | select(wallet)) ] | unique | length),
      wallet_names: $wnames,
      user_only: ($userapps | length),
      unmatched: $unmatched,
      mas_source: (if $hasbundles then "bundles" elif $hasmas then "mas" else "none" end),
      audited_at: ($a.audited_at // "unknown"),
      serial: ($a.system.hardware.serial // "")
    }' >"$WORK/plan.json" || die "classification failed"

# ── render configurations/macos/<host>.nix ───────────────────────────────────
render_host() {
  local p="$WORK/plan.json" role_line
  case "$ROLE" in
    household)   role_line="shared household Mac, ADOPTED in place (role household-mac.nix)" ;;
    personal)    role_line="personal Mac, ADOPTED in place (role personal-mac.nix)" ;;
    workstation) role_line="workstation Mac, ADOPTED in place (role workstation-mac.nix)" ;;
  esac
  cat <<EOF
{ ... }:

{
  # ── $HOST: $role_line ──
  # Generated by scripts/new-host.sh from the device's audit of
  # $(jq -r .audited_at "$p") (UTC). Review before merging; edit freely after.
  # Primary (daily) user: $PUSER.
  #
  # Casks below ADOPT apps that were already installed by hand in
  # /Applications and have an exact Homebrew cask. Nothing new is added.
  # rebuild.sh replaces each hand-installed bundle with the Homebrew copy
  # inside its single authentication (rh7/dotfiles#116).
EOF
  if [ "$(jq '.role | length' "$p")" -gt 0 ]; then
    echo "  # Already declared by the role (not repeated): $(jq -r '.role | join(", ")' "$p")."
  fi
  if [ "$(jq '.adopt | length' "$p")" -eq 0 ]; then
    echo "  homebrew.casks = [ ];"
  else
    echo "  homebrew.casks = ["
    jq -r '.adopt[] | if .deprecated
      then "    \("\"" + .token + "\"" | . + (" " * ([22 - length, 1] | max)))# DEPRECATED upstream — plan a replacement"
      else "    \"\(.token)\"" end' "$p"
    echo "  ];"
  fi
  echo
  echo "  # ── Deliberately NOT declared (manual, by design) ──────────────────────────"
  local w; w=$(jq .wallets "$p")
  if [ "$w" -gt 0 ]; then
    echo "  # Crypto wallets — $w present; installed and updated by hand, never by"
    echo "  # Homebrew (a wallet must never auto-upgrade). Not enumerated: public repo."
    echo "  #"
  fi
  if [ "$(jq '.manual | length' "$p")" -gt 0 ]; then
    echo "  # Candidates — the owner decides whether to adopt, keep manual, or remove:"
    jq -r '.manual[] | "  #   \("\"" + .token + "\"" | . + (" " * ([22 - length, 1] | max)))# \(.why)"' "$p"
  fi
  if [ "$(jq '.ambiguous | length' "$p")" -gt 0 ]; then
    echo "  # Ambiguous exact matches (several casks ship this app) — pick one or none:"
    jq -r '.ambiguous[] | "  #   \(.app): \(.cands | map("\"" + . + "\"") | join(" | "))"' "$p"
  fi
  if [ "$(jq .unmatched "$p")" -gt 0 ]; then
    echo "  # $(jq .unmatched "$p") other app(s) have no exact Homebrew cask (built-in, App Store-less"
    echo "  # vendor apps, …) — not listed; see the audit."
  fi
  if [ "$(jq .user_only "$p")" -gt 0 ]; then
    echo "  # $(jq .user_only "$p") app(s) live in a user's ~/Applications — never adopted (a cask would"
    echo "  # install a second, system-wide copy); not listed."
  fi
  echo
  echo "  # ── Mac App Store apps present (NOT declared) ──────────────────────────────"
  case "$(jq -r .mas_source "$p")" in
    mas|bundles)
          echo "  # Installed under an Apple ID; declaring them would make activation run"
          echo "  # \`mas install\` against whichever Apple ID is signed in, and a cask"
          echo "  # would replace the App Store copy. Owner decides later."
          if [ "$(jq '[.mas[] | select(.id == null)] | length' "$p")" -gt 0 ]; then
            echo "  # (No id where \`mas\` was not installed — App Store receipt in the bundle.)"
          fi ;;
    none) echo "  # The audit predates application_bundles and \`mas\` was not installed: check"
          echo "  # that none of the casks above is an App Store or ~/Applications copy." ;;
  esac
  if [ "$(jq '.mas | length' "$p")" -gt 0 ]; then
    jq -r '.mas[] | if .id then "  #   \(.id + (" " * ([11 - (.id | length), 1] | max)))\(.name)" else "  #   \(.name)" end' "$p"
  fi
  echo "  # Already auto-updated by the App Store (software-update.nix: AutoUpdate)."
  echo "}"
}

render_entry() {
  local note
  case "$ROLE" in
    household)   note="household Mac, adopted in place (scripts/new-host.sh)" ;;
    personal)    note="personal Mac, adopted in place (scripts/new-host.sh)" ;;
    workstation) note="workstation Mac, adopted in place (scripts/new-host.sh)" ;;
  esac
  echo ""
  echo "      # ── $HOST: $note ──"
  echo "      \"$HOST\" = mkMac {"
  echo "        hostname = \"$HOST\";"
  echo "        username = \"$PUSER\";"
  echo "        autoUpdate = \"fleet/stable\";"
  case "$ROLE" in
    household)
      echo "        role = ./modules/roles/household-mac.nix;"
      echo "        homeProfile = \"household\";"
      echo "        needsSecrets = false;" ;;
    personal)
      echo "        role = ./modules/roles/personal-mac.nix;"
      # "full" is the maintainer's shell takeover — never someone else's account.
      case " $OWNER_ACCOUNTS " in *" $PUSER "*) ;; *) echo "        homeProfile = \"household\";" ;; esac
      echo "        needsSecrets = false;" ;;
    workstation) ;;  # default role + needsSecrets = true (sops recipient first)
  esac
  echo "        extraModules = [ ./configurations/macos/$HOST.nix ];"
  echo "      };"
}

render_host >"$WORK/host.nix"
render_entry >"$WORK/entry.nix"

# Insert before the `    };` that closes darwinConfigurations.
awk -v entry="$WORK/entry.nix" '
  /^    darwinConfigurations = \{/ { inblk=1 }
  inblk && /^    };[[:space:]]*$/ { while ((getline l < entry) > 0) print l; inblk=0; done=1 }
  { print }
  END { if (!done) exit 3 }' "$WORK/flake.base.nix" >"$WORK/flake.nix" ||
  die "could not find the end of darwinConfigurations in flake.nix"

# ── checks: nix syntax + public-repo hygiene ────────────────────────────────
if command -v nix-instantiate >/dev/null 2>&1; then
  nix-instantiate --parse "$WORK/host.nix" >/dev/null || die "generated host file does not parse"
  nix-instantiate --parse "$WORK/flake.nix" >/dev/null || die "generated flake.nix does not parse"
else
  info "nix-instantiate not found — nix syntax NOT checked"
fi
serial=$(jq -r .serial "$WORK/plan.json")
if [ -n "$serial" ] && [ "${#serial}" -ge 6 ] && grep -qF "$serial" "$WORK/host.nix" "$WORK/flake.nix"; then
  echo "new-host: HYGIENE: the device serial would be written — refusing" >&2; exit 2
fi
while IFS= read -r wname; do
  [ -n "$wname" ] || continue
  if grep -qiwF -- "$wname" "$WORK/host.nix" "$WORK/entry.nix"; then
    echo "new-host: HYGIENE: a dropped wallet name would be written — refusing" >&2; exit 2
  fi
done < <(jq -r '.wallet_names[]' "$WORK/plan.json")

if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  cp "$WORK/host.nix" "$OUT_DIR/$HOST.nix"
  cp "$WORK/flake.nix" "$OUT_DIR/flake.nix"
  jq 'del(.wallet_names, .serial)' "$WORK/plan.json" >"$OUT_DIR/plan.json"
fi

summary_line() {
  jq -r '"adopt \(.adopt | length) cask(s), \(.manual | length) manual candidate(s), \(.ambiguous | length) ambiguous, \(.mas | length) App Store app(s) commented, \(.wallets) wallet(s) omitted, \(.unmatched) app(s) without a cask"' "$WORK/plan.json"
}

if ! $APPLY; then
  echo "=== configurations/macos/$HOST.nix (new) ==="
  cat "$WORK/host.nix"
  echo
  echo "=== flake.nix ==="
  diff -u --label "a/flake.nix" --label "b/flake.nix" "$WORK/flake.base.nix" "$WORK/flake.nix" || true
  echo
  echo "new-host: $(summary_line)"
  echo "new-host: DRY RUN — nothing written. Re-run with --apply to open the PR."
  if [ "$(jq -r .mas_source "$WORK/plan.json")" = none ]; then
    echo "new-host: WARNING: this audit predates application_bundles and has no mas list — it cannot tell"
    echo "          App Store or ~/Applications copies apart. Re-run after the Mac's next audit (the"
    echo "          collector gains the section when this merges), or prune those casks by hand."
  fi
  [ "$ROLE" = workstation ] && echo "new-host: workstation = needsSecrets: run scripts/sops-add-host.sh $HOST <age1…> on a recipient before the Mac's first rebuild."
  exit 0
fi

# ── --apply: branch + PR from a /tmp worktree ────────────────────────────────
command -v gh >/dev/null || die "--apply needs gh"
BRANCH="add-host/$HOST"
git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null && die "branch $BRANCH already exists locally"
git -C "$REPO" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 && die "branch $BRANCH already exists on origin"
WT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-new-host-$HOST.XXXXXX")
rmdir "$WT"
git -C "$REPO" worktree add --quiet -b "$BRANCH" "$WT" "$BASE_REF"
cp "$WORK/host.nix" "$WT/configurations/macos/$HOST.nix"
cp "$WORK/flake.nix" "$WT/flake.nix"
git -C "$WT" add flake.nix "configurations/macos/$HOST.nix"
git -C "$WT" commit --quiet -m "feat($HOST): add $ROLE mkMac entry generated by new-host.sh

Adopt-only host file from the device's audit: $(summary_line).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git -C "$WT" push --quiet -u origin "$BRANCH"
cat >"$WORK/pr-body.md" <<EOF
Generated by \`scripts/new-host.sh $HOST --role $ROLE --user $PUSER\` from the device's latest audit ($(jq -r .audited_at "$WORK/plan.json")).

- $(summary_line)
- role **$ROLE**, primary user \`$PUSER\`, \`autoUpdate = "fleet/stable"\`

Review the cask list (each one replaces a hand-installed app on the first rebuild) and the commented candidates.

After merge, on the Mac (admin account, GUI session):

\`\`\`
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/adopt.sh | bash
\`\`\`
EOF
[ "$ROLE" = workstation ] && printf '\nneedsSecrets: run `scripts/sops-add-host.sh %s <age1…>` on a recipient and merge that first.\n' "$HOST" >>"$WORK/pr-body.md"
url=$(cd "$WT" && gh pr create --base main --head "$BRANCH" --title "feat($HOST): add $ROLE host (new-host.sh)" --body-file "$WORK/pr-body.md")
echo "new-host: $(summary_line)"
echo "new-host: PR $url"
