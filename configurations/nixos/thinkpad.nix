{ pkgs, lib, ... }:

{
  # ── Hardware config ────────────────────────────────────────────────────────
  imports = [ ./thinkpad-hardware.nix ];

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

  system.stateVersion = "24.11";
}
