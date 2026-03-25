{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # ── UTM / QEMU virtio hardware ─────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci" "virtio_pci" "virtio_scsi" "virtio_blk" "virtio_net"
  ];
  boot.kernelModules = [ ];

  # ── Filesystems (adjust after installation) ─────────────────────────────
  fileSystems."/" = {
    device = "/dev/vda2";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/vda1";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # ── Shared clipboard & display ──────────────────────────────────────────
  services.spice-vdagentd.enable = true;

  networking.hostName = "nixos-vm";
}
