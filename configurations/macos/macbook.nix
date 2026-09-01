{ config, lib, ... }:

{
  imports = [
    ../../modules/darwin/profiles/office.nix
  ];

  # ── MacBook-specific casks (not needed on desktop/studio) ────────────────
  homebrew.casks = [
    # ── Finance (Germany + US + Crypto) ──
    # "quicken"           # uncomment when needed
    # "finanzguru"
    # "starmoney"
    # "ibkr"              # Interactive Brokers

    # ── Creative ──
    # "adobe-creative-cloud"  # manual install recommended (license)

    # ── Personal ──
    "vlc"

  ];

  # ── Host-side tooling for the Omarchy ARM VM build (UTM, Apple Silicon) ──
  # build-omarchy-arm.sh gates on `brew list --formula`, so these must be
  # Homebrew formulas — a nixpkgs qemu on PATH would not satisfy its check.
  homebrew.brews = [
    "qemu"       # headless aarch64 build VM (HVF)
    "expect"     # drives the Alpine/Arch installer over the serial console
    "aria2"      # parallel fetch of the Alpine ISO + Arch Linux ARM rootfs
  ];

  # ── MacBook-specific dock pins (appended after workstation-mac.nix list) ──
  # mkAfter keeps the shared dock intact and tacks personal apps on the end.
  system.defaults.dock.persistent-apps = lib.mkAfter [
    "/Users/${config.system.primaryUser}/Applications/Kubera.app"
  ];

  # ── MacBook Mac App Store apps (mas_install helper from modules/darwin/mas.nix) ──
  # QR Scanner re-added after a stale-checkout rebuild (cleanup="uninstall")
  # removed it; cleanup="none" now prevents recurrence. ID from the uninstall log.
  # (Crypto Pro is already declared in finance.nix + workstation-mac.nix.)
  system.activationScripts.postActivation.text = ''
    mas_install 1225393668 "QR Scanner"
  '';
}
