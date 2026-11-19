#!/usr/bin/env bash
# Eval-level check for dotfiles.homebrew.dailyUserOwnedCasks
# (modules/darwin/homebrew.nix): casks whose app updates itself as the daily
# user (system.primaryUser), so its bundle is hers, not homebrew.user's.
#
# Pins:
#   - kassie-mbp-m1 lists exactly claude → Claude.app, with homebrew.user
#     (rouven) ≠ primaryUser (kassie);
#   - every other darwinConfiguration lists nothing;
#   - kassie-mbp-m1 (only) writes SquirrelMacEnableDirectContentsWrite = true
#     to /Library/Preferences/com.anthropic.claudefordesktop: without it
#     Claude's Squirrel updater needs /Applications writable too, and owning
#     the bundle alone would not spare Kassie the admin prompt;
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

# Per host, as JSON booleans/values only — like check-fleet-audit-scheduler.sh.
# Printing activation TEXT (`nix eval --raw …postActivation.text`) fails on
# the Linux runner ("experimental Nix feature 'dynamic-derivations' is
# disabled"), so the text is searched inside the evaluation instead.
# CustomSystemPreferences keys are written verbatim (`defaults write <key>`),
# so the absolute /Library/Preferences key is what makes it system-wide.
SQUIRREL_DOMAIN="/Library/Preferences/com.anthropic.claudefordesktop"
SUMMARY="c: {
  daily = c.dotfiles.homebrew.dailyUserOwnedCasks;
  brewUser = c.homebrew.user;
  primaryUser = c.system.primaryUser;
  postTouchesClaude = builtins.length (builtins.split \"Claude[.]app\"
    (builtins.unsafeDiscardStringContext c.system.activationScripts.postActivation.text)) > 1;
  squirrel = (c.system.defaults.CustomSystemPreferences.\"$SQUIRREL_DOMAIN\" or { })
    .SquirrelMacEnableDirectContentsWrite or null;
  squirrelAnywhere = builtins.any (d: (c.system.defaults.CustomSystemPreferences.\${d})
    ? SquirrelMacEnableDirectContentsWrite) (builtins.attrNames c.system.defaults.CustomSystemPreferences);
}"

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  s=$(nix eval --json ".#darwinConfigurations.\"$h\".config" --apply "$SUMMARY")
  got=$(jq -cS .daily <<<"$s")
  if [[ "$(jq -r .postTouchesClaude <<<"$s")" != false ]]; then
    bad "$h: an activation script touches Claude.app — App Management blocks it from launchd; rebuild.sh owns the hand-over"
  fi
  if [[ "$h" == "$EXPECTED_HOST" ]]; then
    [[ "$got" == "$EXPECTED" ]] || bad "$h: dailyUserOwnedCasks = $got, expected $EXPECTED"
    bu=$(jq -r .brewUser <<<"$s"); pu=$(jq -r .primaryUser <<<"$s")
    [[ "$bu" == rouven && "$pu" == kassie ]] || bad "$h: homebrew.user=$bu primaryUser=$pu, expected rouven/kassie"
    [[ "$(jq -r .squirrel <<<"$s")" == true ]] \
      || bad "$h: SquirrelMacEnableDirectContentsWrite is not true in CustomSystemPreferences.\"$SQUIRREL_DOMAIN\""
    echo "$h: dailyUserOwnedCasks $got (homebrew.user=$bu, primaryUser=$pu), Squirrel direct-contents on"
  else
    [[ "$got" == "{}" ]] || bad "$h: dailyUserOwnedCasks = $got, expected none"
    [[ "$(jq -r .squirrelAnywhere <<<"$s")" == false ]] \
      || bad "$h: sets the Claude Squirrel default but is not $EXPECTED_HOST"
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
