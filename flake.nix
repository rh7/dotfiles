{
  description = "Rouven's universal Nix setup for Mac and Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, sops-nix, nix-flatpak, ... }:
  let
    # ── Helper: full macOS system config (nix-darwin + home-manager) ─────────
    # Now accepts a `role` module and optional extra modules.
    mkMac = {
      hostname,
      username ? "rouvenheck",
      role ? ./modules/roles/workstation-mac.nix,
      needsSecrets ? true,
      extraModules ? [],
      extraHomeModules ? [],
      # Unattended nightly updates (modules/darwin/fleet-update.nix):
      # null = off, or the channel to follow — "main" (canary) | "fleet/stable".
      autoUpdate ? null,
      # Daily restic backup of the policy folders to the Studio's REST server
      # (modules/darwin/restic-backup.nix). Inert until `rh7-restic-backup setup`.
      resticBackup ? false,
      # Which home-manager config the primary user gets:
      #   "full"      — configurations/macos/home.nix + modules/common.nix: the
      #                 maintainer's shell (zsh/starship/git dotfiles become store
      #                 symlinks), CLI/dev toolchain, Update.command, zed config;
      #   "household" — configurations/macos/home-household.nix: nothing of the
      #                 above, so a daily user's own dotfiles stay untouched.
      # fleet-audit.nix is added in both cases. A switch here, not in the role:
      # roles are nix-darwin modules and cannot REMOVE home-manager imports.
      homeProfile ? "full",
    }:
      assert nixpkgs.lib.assertOneOf "mkMac homeProfile" homeProfile [ "full" "household" ];
      nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        modules = [
          # System-level
          ./modules/darwin/defaults.nix
          # NOTE: firewall hardening is NOT global — it lives in modules/darwin/firewall.nix
          # and is imported only by client roles (workstation-mac, personal-mac), to keep the
          # app firewall OFF the Mac Studio config-service host (#93).
          ./modules/darwin/homebrew.nix
          ./modules/darwin/mas.nix
          # /etc/rh7/config-service — the fleet's config-service pin.
          ./modules/darwin/config-service-pin.nix
          ./modules/darwin/xcode-license.nix
          ./modules/darwin/fleet-update.nix
          ./modules/darwin/restic-backup.nix
          # The ONE stable launcher the scheduled jobs (audit, restic) start,
          # so one optional Full Disk Access grant per Mac covers both.
          ./modules/darwin/fleet-launcher.nix
          {
            # The attr to build is baked in here, never derived at runtime.
            # Every darwinConfigurations attr below equals its hostname.
            services.rh7.fleetUpdate = {
              enable = autoUpdate != null;
              flakeAttr = hostname;
            } // nixpkgs.lib.optionalAttrs (autoUpdate != null) { channel = autoUpdate; };
            # The rewind floor for an auto-updated host's FIRST unattended run:
            # the daemon refuses any channel tip that does not descend from the
            # commit the running generation was built from.
            system.configurationRevision =
              nixpkgs.lib.mkIf (autoUpdate != null) (self.rev or self.dirtyRev or null);
            services.rh7.resticBackup.enable = resticBackup;
          }
          role
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.${username} = { pkgs, lib, ... }: {
              home.username = lib.mkForce username;
              home.homeDirectory = lib.mkForce "/Users/${username}";
              imports = {
                full = [
                  ./configurations/macos/home.nix  # user config (imports profiles)
                  ./modules/common.nix             # CLI tools + git + shell
                ];
                household = [ ./configurations/macos/home-household.nix ];
              }.${homeProfile} ++ [
                # Declarative daily fleet audit (com.rh7.collector-runner).
                # Darwin-only on purpose: mkNixOS/mkLinux hosts don't get it
                # (systemd --user timers need linger — see the module header).
                ./modules/home/profiles/fleet-audit.nix
              ] ++ extraHomeModules;
            };
            networking.hostName = hostname;
            system.primaryUser = username;
            # Timezone is left unmanaged so macOS's "Set automatically using
            # current location" stays in effect — see modules/darwin/defaults.nix
            # which enables auto-timezone in postActivation.
          }
        ] ++ nixpkgs.lib.optionals needsSecrets [
          sops-nix.darwinModules.sops
          ./modules/secrets.nix
        ] ++ extraModules;
      };

    # ── Helper: full NixOS system config (NixOS + home-manager) ─────────────
    mkNixOS = {
      hostname,
      system ? "aarch64-linux",
      username ? "rouvenheck",
      role ? ./modules/roles/workstation-linux.nix,
      extraModules ? [],
      extraHomeModules ? [],
    }:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit username; };
        modules = [
          ./modules/nixos/system.nix
          role
          nix-flatpak.nixosModules.nix-flatpak
          sops-nix.nixosModules.sops
          ./modules/secrets.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.${username} = { pkgs, ... }: {
              imports = [
                ./configurations/nixos/home.nix
                ./modules/common.nix
              ] ++ extraHomeModules;
            };
            networking.hostName = hostname;
          }
        ] ++ extraModules;
      };

    # ── Helper: Linux (Home Manager standalone — for OrbStack/servers) ──────
    mkLinux = { username ? "rouvenheck", system ? "aarch64-linux", extraModules ? [ ] }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = { inherit username; };
        modules = [
          ./configurations/linux/home.nix
          ./modules/common.nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
          }
        ] ++ extraModules;
      };

  in {
    # ── Mac configurations ──────────────────────────────────────────────────
    darwinConfigurations = {
      # ── MacBooks (all use workstation role) ──
      "m5-air" = mkMac {
        hostname = "m5-air";
        autoUpdate = "main";  # canary
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouven-m5-pro" = mkMac {
        hostname = "rouven-m5-pro";
        username = "rouven";
        autoUpdate = "main";  # canary
        resticBackup = true;  # pilot: restic to the Studio instead of Time Machine
        extraModules = [ ./configurations/macos/macbook.nix ];
        # Staged rollout — validate the weekly updater here for a few weeks
        # before promoting it to modules/common.nix for the whole fleet.
        extraHomeModules = [ ./modules/home/profiles/weekly-update.nix ];
      };

      "rouven-air-m2" = mkMac {
        hostname = "rouven-air-m2";
        autoUpdate = "fleet/stable";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouven-air-m3" = mkMac {
        hostname = "rouven-air-m3";
        autoUpdate = "fleet/stable";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouven-pro-m4" = mkMac {
        hostname = "rouven-pro-m4";
        autoUpdate = "fleet/stable";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      # ── Mac Mini (workstation + smart home) ──
      "rouvens-mac-mini-m4" = mkMac {
        hostname = "rouvens-mac-mini-m4";
        extraModules = [
          ./configurations/macos/mac-mini-office.nix
          ./modules/roles/smart-home.nix
        ];
      };

      # ── Mac Studio (fleet member — workloads owned by mac-studio-services) ──
      # Slimmed from server-mac + ai-inference on 2026-08-23: nix keeps the
      # toolchain/secrets/audit layer; Homebrew and apps are imperative, owned
      # by mac-studio-services. See modules/roles/fleet-member-mac.nix.
      "rouvens-mac-studio" = mkMac {
        hostname = "rouvens-mac-studio";
        role = ./modules/roles/fleet-member-mac.nix;
        extraModules = [
          ./configurations/macos/mac-studio.nix
        ];
      };

      # ── Kassie's MacBook Air (personal role — lighter setup) ──
      "Kassie-M5-Air13" = mkMac {
        hostname = "Kassie-M5-Air13";
        username = "kassie";
        autoUpdate = "fleet/stable";
        role = ./modules/roles/personal-mac.nix;
        needsSecrets = false;
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      # ── Shared household MacBook Pro M1 (adopted in place, NOT wiped) ──
      # primaryUser is the day-to-day user (kassie), like Kassie-M5-Air13: the
      # nightly fleet-update's home-manager step and the daily audit agent need
      # the primary user's LOGIN SESSION (launchctl gui domain), and adopted
      # casks end up owned by her. homeProfile "household": her own ~/.zshrc,
      # git config etc. are never replaced. The maintainer's account (rouven)
      # gets nothing per-user from nix. See modules/roles/household-mac.nix.
      "kassie-mbp-m1" = mkMac {
        hostname = "kassie-mbp-m1";
        username = "kassie";
        autoUpdate = "fleet/stable";
        role = ./modules/roles/household-mac.nix;
        homeProfile = "household";
        needsSecrets = false;
        extraModules = [ ./configurations/macos/kassie-mbp-m1.nix ];
      };
    };

    # ── NixOS configurations ─────────────────────────────────────────────────
    nixosConfigurations = {
      "nixos-vm" = mkNixOS {
        hostname = "nixos-vm";
        system = "aarch64-linux";
        username = "rouven";
        extraModules = [ ./configurations/nixos/vm.nix ];
      };

      "thinkpad" = mkNixOS {
        hostname = "thinkpad";
        system = "x86_64-linux";
        username = "rouven";
        extraModules = [ ./configurations/nixos/thinkpad.nix ];
        # Not in workstation-linux.nix: nixos-vm has no use for a Home Assistant
        # launcher, so this stays host-scoped rather than role-wide.
        extraHomeModules = [ ./modules/home/profiles/home-assistant.nix ];
      };
    };

    # ── Linux (OrbStack VM / servers) ───────────────────────────────────────
    homeConfigurations = {
      "linux" = mkLinux { username = "rouvenheck"; };           # default (OrbStack)
      "linux-rouven" = mkLinux { username = "rouven"; };        # alternate username
      "linux-x86" = mkLinux { username = "rouvenheck"; system = "x86_64-linux"; };
      # Omarchy 4 guest (Arch Linux ARM in UTM) — CLI only; Omarchy owns the desktop.
      "omarchy" = mkLinux { extraModules = [ ./configurations/linux/omarchy.nix ]; };
    };
  };
}
