{ pkgs, ... }:

{
  # ── Mac Studio overrides ─────────────────────────────────────────────────
  # AI inference apps are in modules/roles/ai-inference.nix (imported via flake.nix)

  # Lima is the native hypervisor boundary for isolated Linux workloads such as
  # the knowledge VM. Use nixpkgs rather than Homebrew so the reviewed flake.lock
  # pins the version and a nix-darwin generation can roll it back.
  #
  # Colima is the production container runtime since mac-studio-services#734
  # Phase 2 (2026-08-18): OrbStack is a GUI app and died with the Aqua session,
  # so every compose project now runs on colima under the com.rh7.colima
  # LaunchDaemon. Same nixpkgs-over-Homebrew reasoning as lima.
  #
  # Transition note: the host currently runs a brew-installed colima and the
  # LaunchDaemon points at /opt/homebrew/bin/colima. After the first rebuild
  # that ships this declaration, repoint the daemon to
  # /run/current-system/sw/bin/colima (plist lives in
  # mac-studio-services/colima/systemd/) during a supervised restart, then
  # `brew uninstall colima`. Tracked on mac-studio-services#734.
  #
  # This installs only the CLI/runtime. VM definitions, mounts, credentials,
  # startup policy, and guest lifecycle belong to the workload repository —
  # colima's VM profile and service plists live in mac-studio-services.
  environment.systemPackages = [
    pkgs.lima
    pkgs.colima
  ];
}
