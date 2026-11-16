{ pkgs, ... }:

{
  # ── Mac Studio overrides ─────────────────────────────────────────────────
  # AI inference apps are in modules/roles/ai-inference.nix (imported via flake.nix)

  # Application firewall ON with a per-app allow-list (rh7/mac-studio-services#920).
  imports = [ ./mac-studio-firewall.nix ];

  # Lima is the native hypervisor boundary for isolated Linux workloads such as
  # the knowledge VM. Use nixpkgs rather than Homebrew so the reviewed flake.lock
  # pins the version and a nix-darwin generation can roll it back.
  #
  # This installs only the CLI/runtime. VM definitions, mounts, credentials,
  # startup policy, and guest lifecycle belong to the workload repository.
  environment.systemPackages = [
    pkgs.lima
  ];

  # ── Power: an always-on server (rh7/mac-studio-services#913, #920) ────────
  # Declares what the Studio already runs (pmset -g, 2026-11-15): never sleeps,
  # disks never sleep, comes back by itself after a power cut and answers
  # wake-on-LAN. After that automatic restart it waits at the FileVault unlock
  # for a person (mac-studio-services scripts/power-prep.sh) — the restart is
  # still wanted: it is what makes a remote pre-boot unlock possible at all.
  # Display sleep is left as set by hand.
  #
  # Native nix-darwin options (systemsetup, as root, during activation):
  power.sleep.computer = "never";             # pmset sleep 0
  power.sleep.harddisk = "never";             # pmset disksleep 0
  power.restartAfterPowerFailure = true;      # pmset autorestart 1
  networking.wakeOnLan.enable = true;         # pmset womp 1 (systemsetup -setWakeOnNetworkAccess)

  # No nix-darwin option for Power Nap: pmset, for every power source (-a).
  # It is 1 on the Studio today; re-asserting it is a no-op. A failure warns
  # instead of aborting the rest of activation.
  system.activationScripts.postActivation.text = ''
    if ! /usr/bin/pmset -a powernap 1; then
      echo "warning: pmset could not set powernap=1 (Power Nap)" >&2
    fi

    # ── FileVault (rh7/mac-studio-services#913): required ON, checked here ──
    # nix cannot turn FileVault on (`fdesetup enable` is interactive and prints
    # the recovery key), so activation only WARNS when it is not On — it never
    # fails, so a rebuild still goes through. The owner enables it by hand:
    # `sudo fdesetup enable`, recovery key to 1Password.
    fv_status=$(/usr/bin/fdesetup status 2>/dev/null || true)
    case "$fv_status" in
      "FileVault is On."*) ;;
      *)
        printf '\e[1;33mwarning: FileVault is not On on this Mac Studio (fdesetup status: %s). Policy: rh7/mac-studio-services#913.\e[0m\n' \
          "''${fv_status%%$'\n'*}" >&2
        ;;
    esac
  '';
}
