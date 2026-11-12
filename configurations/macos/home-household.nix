{ config, lib, ... }:

{
  # ── Household home: the smallest home-manager config a fleet Mac can have ──
  # Selected by mkMac `homeProfile = "household"` (flake.nix) INSTEAD of
  # configurations/macos/home.nix + modules/common.nix. mkMac still adds
  # modules/home/profiles/fleet-audit.nix, the one per-user thing a household
  # Mac needs (the daily audit LaunchAgent).
  #
  # The primary user here is the person who uses the Mac every day, with
  # dotfiles of her own. So: no programs.zsh / starship / git, no home.file,
  # no packages, no session variables — her ~/.zshrc, ~/.zshenv, ~/.zprofile,
  # ~/.gitconfig and editor settings are never linked, moved to *.hm-backup
  # or rewritten. modules/roles/household-mac.nix fails evaluation if the
  # primary user's home-manager links any file into her home beyond the two
  # empty markers it always writes (~/.cache/.keep, ~/.local/state/.keep);
  # check which files a profile would take over before adding one.
  home.stateVersion = "24.11";  # same as configurations/macos/home.nix

  # No ~/Applications/"Home Manager Apps" link (the 24.11 default) and no
  # ~/Library/Fonts/HomeManager sync: this profile installs no apps or fonts.
  targets.darwin.linkApps.enable = false;
  home.file."Library/Fonts/.home-manager-fonts-version".enable = false;
  # No man-db / home-manager manual in her per-user profile either.
  programs.man.enable = false;
  manual.manpages.enable = false;

  # ── Activation while the primary user is LOGGED OUT ─────────────────────
  # The owner adopts this Mac from his own account and the nightly
  # fleet-update runs as root, so home-manager often activates for her while
  # she has no login session. home-manager's setupLaunchAgents
  # (modules/launchd/default.nix) then fails: it bootstraps every agent into
  # gui/$UID, which only exists during a GUI login ("Bootstrap failed: 125:
  # Domain does not support specified action"), turns that into `exit 1`, and
  # nix-darwin's activate script (`set -e`) aborts in postActivation — before
  # /run/current-system is switched. Upstream: nix-community/home-manager#9629.
  #
  # Without a GUI session the agent cannot run anyway, and launchd loads
  # ~/Library/LaunchAgents at her next GUI login. So, ONLY when gui/$UID does
  # not exist: the plist is still installed by setupLaunchAgents, and its
  # `run /bin/launchctl bootstrap gui/$UID …` (and nothing else) is skipped.
  # The wrapper is removed right after setupLaunchAgents. The marker line is
  # matched by scripts/fleet-update.sh and scripts/rebuild.sh — keep in sync.
  # Covered by scripts/tests/household-no-gui-session.test.sh.
  home.activation.rh7NoGuiSessionGuard = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
    if ! /bin/launchctl print "gui/$UID" >/dev/null 2>&1; then
      noteEcho "rh7: no GUI login session for $(id -un) — LaunchAgents installed; they load at the next login"
      eval "$(declare -f run | sed '1s/^run /_rh7HmRun /')"
      run() {
        if [[ "''${1:-}" == /bin/launchctl && "''${2:-}" == bootstrap && "''${3:-}" == "gui/$UID" ]]; then
          verboseEcho "skipped (no GUI session): launchctl bootstrap $3 ''${4:-}"
          return 0
        fi
        _rh7HmRun "$@"
      }
      _rh7NoGuiSession=1
    fi
  '';
  home.activation.rh7NoGuiSessionGuardEnd = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    if [[ -n "''${_rh7NoGuiSession:-}" ]]; then
      eval "$(declare -f _rh7HmRun | sed '1s/^_rh7HmRun /run /')"
      unset -f _rh7HmRun
      unset _rh7NoGuiSession
    fi
  '';
  # The guard hooks home-manager's `run` helper; a home-manager bump that stops
  # bootstrapping through it must fail the build, not silently drop the guard.
  assertions = [{
    assertion = lib.hasInfix ''run /bin/launchctl bootstrap "$domain"''
      config.home.activation.setupLaunchAgents.data;
    message = "home-household.nix: home-manager's setupLaunchAgents no longer runs "
      + "`run /bin/launchctl bootstrap \"$domain\"` — re-check rh7NoGuiSessionGuard "
      + "against the new modules/launchd/default.nix.";
  }];
}
