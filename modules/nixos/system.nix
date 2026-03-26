{ pkgs, lib, username, ... }:

{
  # ── Boot ────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking ──────────────────────────────────────────────────────────
  networking.networkmanager.enable = true;

  # ── Locale ──────────────────────────────────────────────────────────────
  time.timeZone = lib.mkDefault "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── User ────────────────────────────────────────────────────────────────
  users.users.${username} = {
    isNormalUser = true;
    description = "Rouven Heck";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    shell = pkgs.zsh;
  };
  programs.zsh.enable = true;

  # ── System packages (available before Home Manager activates) ───────────
  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    vim
  ];

  # ── Nix settings ────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # ── Docker ──────────────────────────────────────────────────────────────
  virtualisation.docker.enable = true;

  # ── SSH ─────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # ── Root access (set a password after first boot with `sudo passwd root`) ─
  users.users.root.initialPassword = "nixos";

  system.stateVersion = lib.mkDefault "24.11";
}
