{ pkgs, ... }:

{
  # ── Mac Studio overrides ─────────────────────────────────────────────────
  # AI inference apps are in modules/roles/ai-inference.nix (imported via flake.nix)

  # Lima is the native hypervisor boundary for isolated Linux workloads such as
  # the knowledge VM. Use nixpkgs rather than Homebrew so the reviewed flake.lock
  # pins the version and a nix-darwin generation can roll it back.
  #
  # This installs only the CLI/runtime. VM definitions, mounts, credentials,
  # startup policy, and guest lifecycle belong to the workload repository.
  environment.systemPackages = [
    pkgs.lima
  ];
}
