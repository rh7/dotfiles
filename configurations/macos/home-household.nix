{ ... }:

{
  # ── Household home: the smallest home-manager config a fleet Mac can have ──
  # Selected by mkMac `homeProfile = "household"` (flake.nix) INSTEAD of
  # configurations/macos/home.nix + modules/common.nix. mkMac still adds
  # modules/home/profiles/fleet-audit.nix; on a household Mac
  # (services.rh7.fleetAudit.scheduler = "system-daemon") that module declares
  # no LaunchAgent — the daily audit is a system LaunchDaemon running as this
  # user — and only removes the agent earlier generations installed.
  #
  # The primary user here is the person who uses the Mac every day, with
  # dotfiles of her own. So: no programs.zsh / starship / git, no home.file,
  # no packages, no session variables — her ~/.zshrc, ~/.zshenv, ~/.zprofile,
  # ~/.gitconfig and editor settings are never linked, moved to *.hm-backup
  # or rewritten. modules/roles/household-mac.nix fails evaluation if the
  # primary user's home-manager links any file into her home beyond the two
  # empty markers it always writes (~/.cache/.keep, ~/.local/state/.keep);
  # check which files a profile would take over before adding one.
  #
  # Activation while she is LOGGED OUT (the owner adopting from his account,
  # the nightly fleet-update) needs nothing special because this profile has
  # no LaunchAgent: home-manager's setupLaunchAgents bootstraps agents into
  # gui/<uid>, which exists only during a GUI login, and fails the whole
  # switch without one (nix-community/home-manager#9629). The household role
  # asserts that no agent comes back; a scheduled job goes into a system
  # LaunchDaemon with UserName instead.
  home.stateVersion = "24.11";  # same as configurations/macos/home.nix

  # No ~/Applications/"Home Manager Apps" link (the 24.11 default) and no
  # ~/Library/Fonts/HomeManager sync: this profile installs no apps or fonts.
  targets.darwin.linkApps.enable = false;
  home.file."Library/Fonts/.home-manager-fonts-version".enable = false;
  # No man-db / home-manager manual in her per-user profile either.
  programs.man.enable = false;
  manual.manpages.enable = false;
}
