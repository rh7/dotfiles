{ config, lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  secretsFile = ../secrets/secrets.yaml;
  # Detect the primary user — nix-darwin uses system.primaryUser, NixOS doesn't
  primaryUser = if isDarwin
    then config.system.primaryUser or "rouvenheck"
    else builtins.head (builtins.attrNames (lib.filterAttrs (n: v: v.isNormalUser or false) config.users.users));
  homeDir = if isDarwin then "/Users/${primaryUser}" else "/home/${primaryUser}";
in {
  # ── sops-nix configuration ──────────────────────────────────────────────
  sops = {
    defaultSopsFile = secretsFile;
    age.keyFile = "${homeDir}/.config/sops/age/keys.txt";

    # ── Secrets declarations ──────────────────────────────────────────────
    secrets = {
      github_token = {
        owner = lib.mkIf (!isDarwin) primaryUser;
      };
      tailscale_auth_key = {
        owner = lib.mkIf (!isDarwin) primaryUser;
      };
      catalog_agent_token = {
        owner = lib.mkIf (!isDarwin) primaryUser;
      };
    };
  };
}
