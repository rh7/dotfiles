{ pkgs, lib, ... }:

{
  # ── Hardware config ────────────────────────────────────────────────────────
  imports = [
    ./thinkpad-hardware.nix
    # Opt-in network/security tooling — thinkpad only, not the shared role.
    ../../modules/nixos/profiles/hacker.nix
  ];

  # ── ThinkPad power management (use TLP, not power-profiles-daemon) ─────────
  services.thermald.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    };
  };
  services.power-profiles-daemon.enable = false;
  services.fwupd.enable = true;

  # ── Fingerprint reader (uncomment if available) ────────────────────────────
  # services.fprintd.enable = true;

  # ── Timezone ───────────────────────────────────────────────────────────────
  time.timeZone = "Europe/Berlin";

  # ── Ollama (local LLM inference) ─────────────────────────────────────────
  # Host-scoped rather than in modules/nixos/system.nix: nixos-vm has no use
  # for a serving stack, and the fleet's shared inference host is the Mac Studio
  # (see modules/roles/ai-inference.nix).
  services.ollama.enable = true;

  system.stateVersion = "24.11";
}
