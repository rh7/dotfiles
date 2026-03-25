{ pkgs, ... }:

{
  # ── ThinkPad hardware (generate with nixos-generate-config) ─────────────
  # TODO: Replace with actual hardware-configuration.nix from the ThinkPad
  # Run: nixos-generate-config --show-hardware-config

  boot.initrd.availableKernelModules = [
    "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # ── ThinkPad-specific ───────────────────────────────────────────────────
  services.thermald.enable = true;
  services.tlp.enable = true;           # battery management
  services.fwupd.enable = true;         # firmware updates

  # ── Fingerprint reader (if available) ───────────────────────────────────
  # services.fprintd.enable = true;

  networking.hostName = "thinkpad";
}
