{ ... }:

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
}
