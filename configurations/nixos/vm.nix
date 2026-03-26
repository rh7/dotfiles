{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # ── UTM / QEMU virtio hardware ─────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci" "virtio_pci" "virtio_scsi" "virtio_blk" "virtio_net"
    "usbhid" "usb_storage" "sr_mod"
  ];
  boot.kernelModules = [ ];

  # ── Filesystems ────────────────────────────────────────────────────────
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/c9b5514c-1aba-4ff3-817a-c6a4fcc14a87";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/499E-4F4A";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
  swapDevices = [
    { device = "/dev/disk/by-uuid/36047060-54e1-4390-b406-d4564b973576"; }
  ];

  # ── Platform ───────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = "aarch64-linux";

  # ── Timezone (Puerto Rico) ─────────────────────────────────────────────
  time.timeZone = "America/Puerto_Rico";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "es_PR.UTF-8";
    LC_IDENTIFICATION = "es_PR.UTF-8";
    LC_MEASUREMENT = "es_PR.UTF-8";
    LC_MONETARY = "es_PR.UTF-8";
    LC_NAME = "es_PR.UTF-8";
    LC_NUMERIC = "es_PR.UTF-8";
    LC_PAPER = "es_PR.UTF-8";
    LC_TELEPHONE = "es_PR.UTF-8";
    LC_TIME = "es_PR.UTF-8";
  };

  # ── Shared clipboard & display ─────────────────────────────────────────
  services.spice-vdagentd.enable = true;

  system.stateVersion = "25.11";
}
