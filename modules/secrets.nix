{ config, lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  secretsFile = ../secrets/secrets.yaml;
  homeDir = if isDarwin then "/Users/rouvenheck" else "/home/rouvenheck";
in {
  # ── sops-nix configuration ──────────────────────────────────────────────
  sops = {
    defaultSopsFile = secretsFile;
    age.keyFile = "${homeDir}/.config/sops/age/keys.txt";

    # ── Secrets declarations ──────────────────────────────────────────────
    # Each secret becomes a file at /run/secrets/<name> (NixOS)
    # or /etc/sops-nix/secrets/<name> (macOS)
    secrets = {
      github_token = {
        owner = lib.mkIf (!isDarwin) "rouvenheck";
      };
      tailscale_auth_key = {
        owner = lib.mkIf (!isDarwin) "rouvenheck";
      };
      catalog_agent_token = {
        owner = lib.mkIf (!isDarwin) "rouvenheck";
      };
    };
  };
}
