{ pkgs, ... }:

{
  # ── Boot ────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking ──────────────────────────────────────────────────────────
  networking.networkmanager.enable = true;

  # ── Locale ──────────────────────────────────────────────────────────────
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── User ────────────────────────────────────────────────────────────────
  users.users.rouvenheck = {
    isNormalUser = true;
    description = "Rouven Heck";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;

  # ── Nix settings ────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # ── Docker ──────────────────────────────────────────────────────────────
  virtualisation.docker.enable = true;

  # ── SSH ─────────────────────────────────────────────────────────────────
  services.openssh.enable = true;

  system.stateVersion = "24.11";
}
