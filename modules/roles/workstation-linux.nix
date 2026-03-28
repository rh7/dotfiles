{ ... }:

{
  # ── Linux Workstation: full developer desktop ────────────────────────────
  # Composes all desktop profiles for a NixOS developer machine.
  imports = [
    ../nixos/desktop.nix
    ../nixos/profiles/dev-apps.nix
    ../nixos/profiles/communication.nix
    ../nixos/profiles/productivity.nix
    ../nixos/profiles/media.nix
  ];
}
