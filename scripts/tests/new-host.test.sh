#!/usr/bin/env bash
# scripts/new-host.sh generation from a fixture audit — no network, no gh.
#
# The fixture Mac has: plain casks, a deprecated cask, a @beta variant, crypto
# wallets (with and without a cask, one from the App Store), an App Store copy
# of an app that also has a cask, Tailscale, a VPN, an Adobe app, a disabled
# cask, a pkg cask found only through its uninstall stanza, an app without a
# cask, and a serial number. Checks: what is adopted, what is commented, that
# no wallet name or serial reaches the output, that both generated files parse
# (nix-instantiate --parse, skipped without nix), and the refusals.
#
# Run: bash scripts/tests/new-host.test.sh   (needs jq + git; nix optional)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NH="$REPO_ROOT/scripts/new-host.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()    { echo "  ok   — $1"; pass=$((pass + 1)); }
bad()   { echo "  FAIL — $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /' | head -40; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got:  $2"$'\n'"want: $3"; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing: $3"; fi; }
hasnt() { if grep -qiF -- "$3" <<<"$2"; then bad "$1" "unexpected: $3"; else ok "$1"; fi; }
# uncommented cask line: `    "token"` at the start of a non-comment line
declared() { grep -Eq "^    \"$2\"" <<<"$1"; }

command -v jq >/dev/null || { echo "new-host.test.sh: jq missing — cannot run"; exit 1; }

cat >"$T/audit.json" <<'EOF'
{
  "hostname": "fixture-mac",
  "audited_at": "2026-11-12 10:00:00",
  "system": { "hardware": { "serial": "C02FIXTURE9Z", "model": "MacBookPro18,3" } },
  "user_accounts": { "users": [ { "username": "dana", "uid": 502 }, { "username": "rouven", "uid": 501 } ], "current_user": "rouven" },
  "applications": [ "Firefox", "Arc", "Exodus", "Ledger Live", "Electrum", "Slack", "Tailscale", "ExpressVPN",
                    "Adobe Photoshop 2025", "Skype", "zoom.us", "Obscure Tool", "1Password", "Telegram", "Safari",
                    "Blockstream Green", "Crypto Pro", "Notion", "Discord", "Harbor" ],
  "application_bundles": [
    { "name": "Firefox", "location": "system", "app_store": false },
    { "name": "Arc", "location": "system", "app_store": false },
    { "name": "Exodus", "location": "system", "app_store": false },
    { "name": "Ledger Live", "location": "system", "app_store": false },
    { "name": "Electrum", "location": "system", "app_store": false },
    { "name": "Slack", "location": "system", "app_store": true },
    { "name": "Tailscale", "location": "system", "app_store": false },
    { "name": "ExpressVPN", "location": "system", "app_store": false },
    { "name": "Adobe Photoshop 2025", "location": "system", "app_store": false },
    { "name": "Skype", "location": "system", "app_store": false },
    { "name": "zoom.us", "location": "system", "app_store": false },
    { "name": "Obscure Tool", "location": "system", "app_store": false },
    { "name": "1Password", "location": "system", "app_store": false },
    { "name": "Telegram", "location": "system", "app_store": false },
    { "name": "Safari", "location": "system", "app_store": false },
    { "name": "Blockstream Green", "location": "system", "app_store": false },
    { "name": "Crypto Pro", "location": "system", "app_store": true },
    { "name": "Notion", "location": "user", "app_store": false },
    { "name": "Discord", "location": "user", "app_store": false },
    { "name": "Harbor", "location": "system", "app_store": false }
  ],
  "mas_apps": { "installed": true, "apps": [ { "id": 803453959, "name": "Slack" }, { "id": 980888073, "name": "Crypto Pro" } ] },
  "homebrew": { "casks": [ "miniconda" ] }
}
EOF
cat >"$T/gaps.json" <<'EOF'
{ "present_unmanaged": [ "tailscale", "zoom", "1password", "slack", "notion" ], "unmanaged_casks": [ "miniconda" ] }
EOF
cat >"$T/casks.json" <<'EOF'
[
  { "token": "firefox", "artifacts": [ { "app": [ "Firefox.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "firefox@beta", "artifacts": [ { "app": [ "Firefox.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "arc", "artifacts": [ { "app": [ "Arc.app" ] } ], "deprecated": true, "disabled": false },
  { "token": "exodus", "artifacts": [ { "app": [ "Exodus.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "ledger-live", "artifacts": [ { "app": [ "Ledger Live.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "slack", "artifacts": [ { "app": [ "Slack.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "tailscale-app", "artifacts": [ { "app": [ "Tailscale.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "tailscale", "artifacts": [ { "binary": [ "tailscale" ] } ], "deprecated": false, "disabled": false },
  { "token": "expressvpn", "artifacts": [ { "uninstall": [ { "delete": "/Applications/ExpressVPN.app" } ] }, { "pkg": [ "x.pkg" ] } ], "deprecated": false, "disabled": false },
  { "token": "adobe-photoshop", "artifacts": [ { "app": [ "Adobe Photoshop 2025.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "skype", "artifacts": [ { "app": [ "Skype.app" ] } ], "deprecated": true, "disabled": true },
  { "token": "zoom", "artifacts": [ { "uninstall": [ { "delete": [ "/Applications/zoom.us.app", "/Library/x" ] } ] }, { "pkg": [ "zoomusInstallerFull.pkg" ] } ], "deprecated": false, "disabled": false },
  { "token": "miniconda", "artifacts": [ { "installer": [ { "script": { "executable": "x" } } ] } ], "deprecated": false, "disabled": false },
  { "token": "1password", "artifacts": [ { "app": [ "1Password.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "telegram", "artifacts": [ { "app": [ "Telegram.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "telegram-desktop", "artifacts": [ { "app": [ "Telegram.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "blockstream", "name": [ "Blockstream Green" ], "desc": "Multi-platform Bitcoin and Liquid wallet", "artifacts": [ { "app": [ "Blockstream.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "blockstream-green", "name": [ "Green" ], "desc": "Bitcoin wallet", "artifacts": [ { "app": [ "Blockstream Green.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "notion", "artifacts": [ { "app": [ "Notion.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "discord", "artifacts": [ { "app": [ "Discord.app" ] } ], "deprecated": false, "disabled": false },
  { "token": "harbor-app", "name": [ "Harbor" ], "desc": "Companion app for a hardware wallet", "artifacts": [ { "app": [ "Harbor.app" ] } ], "deprecated": false, "disabled": false }
]
EOF

gen() {  # gen <outdir> [args…] → OUT, RC
  local out="$1"; shift
  OUT=$("$NH" fixture-mac --no-fetch --base-ref HEAD --audit-file "$T/audit.json" --gaps-file "$T/gaps.json" \
        --cask-db "$T/casks.json" --out "$out" "$@" 2>&1)
  RC=$?
}

echo "== household (default) =="
gen "$T/hh"
check "exit 0" "$RC" 0
HOSTF=$(cat "$T/hh/fixture-mac.nix" 2>/dev/null)
FLAKE=$(cat "$T/hh/flake.nix" 2>/dev/null)
for t in firefox arc 1password telegram; do
  if declared "$HOSTF" "$t"; then ok "adopts $t"; else bad "adopts $t" "$HOSTF"; fi
done
has "deprecated cask marked" "$(grep '"arc"' <<<"$HOSTF")" "DEPRECATED upstream"
for t in "firefox@beta" telegram-desktop slack tailscale tailscale-app expressvpn adobe-photoshop skype zoom miniconda notion discord blockstream blockstream-green harbor-app; do
  if declared "$HOSTF" "$t"; then bad "does not declare $t" "$HOSTF"; else ok "does not declare $t"; fi
done
has "tailscale commented as network-critical" "$HOSTF" '#   "tailscale"'
has "VPN commented" "$HOSTF" '#   "expressvpn"'
has "Adobe commented" "$HOSTF" '#   "adobe-photoshop"'
has "disabled cask commented" "$(grep '"skype"' <<<"$HOSTF")" "DISABLED upstream"
has "pkg cask (found via uninstall path) commented" "$(grep '"zoom"' <<<"$HOSTF")" "pkg installer"
has "installer cask commented" "$(grep '"miniconda"' <<<"$HOSTF")" "pkg installer"
has "MAS app listed with id, commented" "$HOSTF" "#   803453959  Slack"
has "wallets counted (name list + cask catalogue description)" "$HOSTF" "Crypto wallets — 6 present"
for w in Exodus exodus "Ledger Live" ledger-live Electrum "Crypto Pro" 980888073 Blockstream "Blockstream Green" blockstream-green Harbor harbor-app; do
  hasnt "no wallet name in host file: $w" "$HOSTF" "$w"
  hasnt "no wallet name in flake: $w" "$FLAKE" "$w"
done
hasnt "no serial in host file" "$HOSTF" "C02FIXTURE9Z"
hasnt "no serial in flake" "$FLAKE" "C02FIXTURE9Z"
hasnt "no serial in --out plan" "$(cat "$T/hh/plan.json")" "C02FIXTURE9Z"
hasnt "no app without a cask named" "$HOSTF" "Obscure Tool"
has "apps without a cask only counted (Obscure Tool, Safari)" "$HOSTF" "2 other app(s) have no exact Homebrew cask"
has "user-Applications-only apps (incl. one on the gap list) only counted" "$HOSTF" "2 app(s) live in a user's ~/Applications"
hasnt "no ~/Applications app named" "$HOSTF" "Notion"
BLK=$(sed -n '/"fixture-mac" = mkMac/,/};/p' <<<"$FLAKE")
has "flake entry" "$BLK" '"fixture-mac" = mkMac {'
has "primary user = the non-owner account" "$BLK" 'username = "dana";'
has "household role" "$BLK" "role = ./modules/roles/household-mac.nix;"
has "household home profile" "$BLK" 'homeProfile = "household";'
has "no secrets" "$BLK" "needsSecrets = false;"
has "fleet/stable" "$BLK" 'autoUpdate = "fleet/stable";'
has "host module wired" "$BLK" "extraModules = [ ./configurations/macos/fixture-mac.nix ];"
check "entry lands inside darwinConfigurations (before nixosConfigurations)" \
  "$(awk '/"fixture-mac" = mkMac/ {f=NR} /nixosConfigurations = \{/ {n=NR} END {print (f && n && f < n) ? "yes" : "no"}' <<<"$FLAKE")" yes
hasnt "no Dock list (household)" "$HOSTF" "persistent-apps"
has "dry-run prints the flake diff" "$OUT" '+      "fixture-mac" = mkMac {'
has "dry-run says nothing written" "$OUT" "DRY RUN — nothing written"
if git -C "$REPO_ROOT" status --porcelain -- flake.nix configurations/macos | grep -q fixture; then
  bad "dry-run wrote nothing into the repo"
else
  ok "dry-run wrote nothing into the repo"
fi

echo "== nix syntax =="
if command -v nix-instantiate >/dev/null 2>&1; then
  if nix-instantiate --parse "$T/hh/fixture-mac.nix" >/dev/null 2>&1; then ok "host file parses"; else bad "host file parses"; fi
  if nix-instantiate --parse "$T/hh/flake.nix" >/dev/null 2>&1; then ok "flake.nix parses"; else bad "flake.nix parses"; fi
else
  echo "  skip — nix-instantiate not installed"
fi

echo "== workstation: role-declared casks are not repeated =="
gen "$T/ws" --role workstation --user dana
check "exit 0" "$RC" 0
WS=$(cat "$T/ws/fixture-mac.nix" 2>/dev/null); WSF=$(cat "$T/ws/flake.nix" 2>/dev/null)
if declared "$WS" 1password; then bad "1password (core.nix) not repeated" "$WS"; else ok "1password (core.nix) not repeated"; fi
has "role-declared list noted" "$WS" "Already declared by the role"
WSBLK=$(sed -n '/"fixture-mac" = mkMac/,/};/p' <<<"$WSF")
hasnt "workstation: default role (no role line)" "$WSBLK" "role ="
hasnt "workstation: secrets stay on" "$WSBLK" "needsSecrets = false"

echo "== refusals =="
gen "$T/x1" --role nonsense
check "bad role → 1" "$RC" 1
OUT=$("$NH" 'bad host!' --no-fetch --base-ref HEAD --audit-file "$T/audit.json" --gaps-file "$T/gaps.json" --cask-db "$T/casks.json" 2>&1); RC=$?
check "bad hostname → 1" "$RC" 1
OUT=$("$NH" rouvens-mac-studio --no-fetch --base-ref HEAD --audit-file "$T/audit.json" --gaps-file "$T/gaps.json" --cask-db "$T/casks.json" 2>&1); RC=$?
check "existing flake entry → 1" "$RC" 1
has "says it exists" "$OUT" "already has a flake entry"
OUT=$("$NH" Rouvens-Mac-Studio --no-fetch --base-ref HEAD --audit-file "$T/audit.json" --gaps-file "$T/gaps.json" --cask-db "$T/casks.json" 2>&1); RC=$?
check "entry that differs only by case → 1" "$RC" 1
has "names the existing entry" "$OUT" "'rouvens-mac-studio' already has a flake entry"
jq '.user_accounts.users += [{"username":"eve","uid":503}]' "$T/audit.json" >"$T/audit2.json"
OUT=$("$NH" fixture-mac --no-fetch --base-ref HEAD --audit-file "$T/audit2.json" --gaps-file "$T/gaps.json" --cask-db "$T/casks.json" 2>&1); RC=$?
check "two non-owner accounts without --user → 1" "$RC" 1
has "asks for --user" "$OUT" "pass --user"
gen "$T/x2" --role personal --user dana
check "personal role hard-codes another user's home → 1" "$RC" 1
has "explains the hard-coded path" "$OUT" "hard-codes /Users/kassie/"

echo "== legacy audit (no application_bundles, no mas) =="
jq 'del(.application_bundles) | .mas_apps = {"installed": false} | .applications -= ["Notion","Discord","Crypto Pro"]' "$T/audit.json" >"$T/audit-legacy.json"
OUT=$("$NH" fixture-mac --no-fetch --base-ref HEAD --audit-file "$T/audit-legacy.json" --gaps-file "$T/gaps.json" --cask-db "$T/casks.json" --out "$T/legacy" 2>&1); RC=$?
check "exit 0" "$RC" 0
has "warns it cannot tell App Store / ~/Applications copies apart" "$OUT" "cannot tell"
has "host file carries the same caveat" "$(cat "$T/legacy/fixture-mac.nix")" "predates application_bundles"

echo
echo "new-host.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
