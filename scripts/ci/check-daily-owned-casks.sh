#!/usr/bin/env bash
# Eval-level check for dotfiles.homebrew.dailyUserOwnedCasks
# (modules/darwin/homebrew.nix): casks whose app updates itself as the daily
# user (system.primaryUser), so its bundle is hers, not homebrew.user's.
#
# Pins:
#   - kassie-mbp-m1 lists exactly claude → Claude.app, with homebrew.user
#     (rouven) ≠ primaryUser (kassie);
#   - every other darwinConfiguration lists nothing;
#   - no activation script chowns an app bundle: macOS App Management blocks
#     that from the launchd-run activations (fleet-update, Deploy now), so
#     the hand-over lives in rebuild.sh (run in Terminal at the Mac);
#   - the option's assertions fire for an undeclared cask, a bundle value
#     that is not a bare "<Name>.app", and a host whose homebrew.user already
#     is the primary user.
#
# Run from the repo root (flake-check.yml). Exit 0 ok, 1 any failure.
set -euo pipefail

EXPECTED_HOST="kassie-mbp-m1"
EXPECTED='{"claude":["Claude.app"]}'

fail=0
bad() { echo "::error::$*"; fail=1; }

cfg() { printf '.#darwinConfigurations."%s".config.%s' "$1" "$2"; }

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  got=$(nix eval --json "$(cfg "$h" dotfiles.homebrew.dailyUserOwnedCasks)" | jq -cS .)
  post=$(nix eval --raw "$(cfg "$h" system.activationScripts.postActivation.text)")
  if [[ "$post" == *"Claude.app"* ]]; then
    bad "$h: an activation script touches Claude.app — App Management blocks it from launchd; rebuild.sh owns the hand-over"
  fi
  if [[ "$h" == "$EXPECTED_HOST" ]]; then
    [[ "$got" == "$EXPECTED" ]] || bad "$h: dailyUserOwnedCasks = $got, expected $EXPECTED"
    bu=$(nix eval --raw "$(cfg "$h" homebrew.user)")
    pu=$(nix eval --raw "$(cfg "$h" system.primaryUser)")
    [[ "$bu" == rouven && "$pu" == kassie ]] || bad "$h: homebrew.user=$bu primaryUser=$pu, expected rouven/kassie"
    echo "$h: dailyUserOwnedCasks $got (homebrew.user=$bu, primaryUser=$pu)"
  else
    [[ "$got" == "{}" ]] || bad "$h: dailyUserOwnedCasks = $got, expected none"
    echo "$h: no daily-user-owned casks"
  fi
done

# failed_assertions <module expr> — the failed assertion messages of
# kassie-mbp-m1 extended with <module expr>, one per line.
failed_assertions() {
  nix eval --json ".#darwinConfigurations.\"$EXPECTED_HOST\"" --apply "c: map (a: a.message)
    (builtins.filter (a: !a.assertion) (c.extendModules { modules = [ ({ lib, ... }: $1) ]; }).config.assertions)" \
    | jq -r '.[]'
}

out=$(failed_assertions '{ dotfiles.homebrew.dailyUserOwnedCasks.not-declared = "X.app"; }')
[[ "$out" == *"lists casks not declared in homebrew.casks: not-declared"* ]] \
  || bad "undeclared cask: assertion did not fire (got: $out)"
for v in '"../X.app"' '"Claude"' '"/Applications/Claude.app"' '".app"'; do
  out=$(failed_assertions "{ dotfiles.homebrew.dailyUserOwnedCasks.claude = lib.mkForce $v; }" 2>&1 || true)
  [[ "$out" == *"each value must be an app bundle name"* ]] \
    || bad "bundle value $v: assertion did not fire (got: $out)"
done
out=$(failed_assertions '{ homebrew.user = lib.mkForce "kassie"; }')
[[ "$out" == *"homebrew.user is system.primaryUser"* ]] \
  || bad "homebrew.user = primaryUser: assertion did not fire (got: $out)"
out=$(failed_assertions '{ }')
[[ "$out" != *dailyUserOwnedCasks* ]] || bad "$EXPECTED_HOST as committed fails an assertion: $out"
echo "assertions: undeclared cask, bad bundle value, homebrew.user = primaryUser all refused"

[[ $fail -eq 0 ]] || exit 1
echo "daily-user-owned casks: OK"
