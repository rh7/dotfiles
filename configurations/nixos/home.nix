{ pkgs, ... }:

{
  # username and homeDirectory are set by home-manager.users.<name> in flake.nix
  home.stateVersion = "24.11";
  programs.home-manager.enable = true;

  # ── Profiles (shared, deduplicated) ──────────────────────────────────────
  imports = [
    ../../modules/home/profiles/development.nix
    ../../modules/home/profiles/editor.nix
    ../../modules/home/profiles/docker.nix
    ../../modules/home/profiles/browser.nix
  ];

  # ── GNOME Search Light (Spotlight-style launcher) ────────────────────────
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = [ "search-light@icedman.github.com" ];
    };
    "org/gnome/shell/extensions/search-light" = {
      shortcut-search = [ "<Super>space" ];
    };
  };

  # ── NixOS-specific tools ─────────────────────────────────────────────────
  home.packages = with pkgs; [
    claude-code
    gnomeExtensions.search-light
  ];
}
