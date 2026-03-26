{ pkgs, lib, ... }:

{
  # ── Hardware config (generate on ThinkPad with: nixos-generate-config --show-hardware-config) ──
  # TODO: Create thinkpad-hardware.nix with output from above command
  # imports = [ ./thinkpad-hardware.nix ];

  # ── Placeholder filesystems (REPLACE with actual UUIDs from thinkpad-hardware.nix) ──
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";  # placeholder
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";   # placeholder
    fsType = "vfat";
  };

  # ── ThinkPad hardware ──────────────────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  nixpkgs.hostPlatform = "x86_64-linux";

  # ── ThinkPad power management (use TLP, not power-profiles-daemon) ─────────
  services.thermald.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    };
  };
  services.power-profiles-daemon.enable = false;  # conflicts with TLP
  services.fwupd.enable = true;  # firmware updates

  # ── Fingerprint reader (uncomment if available) ────────────────────────────
  # services.fprintd.enable = true;

  # ── Timezone ───────────────────────────────────────────────────────────────
  time.timeZone = "Europe/Berlin";

  system.stateVersion = "24.11";
}
