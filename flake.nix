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
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
  let
    # ── Helper: full macOS system config (nix-darwin + home-manager) ─────────
    mkMac = { hostname, extraModules ? [], extraHomeModules ? [] }:
      nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        modules = [
          # System-level only (no home.* options here)
          ./modules/darwin/defaults.nix
          ./modules/darwin/homebrew.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.users.rouvenheck = { pkgs, ... }: {
              imports = [
                ./configurations/macos/home.nix  # user config + dev tools
                ./modules/common.nix             # CLI tools + git + shell
              ] ++ extraHomeModules;
            };
            networking.hostName = hostname;
          }
        ] ++ extraModules;
      };

    # ── Helper: full NixOS system config (NixOS + home-manager) ─────────────
    mkNixOS = { hostname, system ? "aarch64-linux", username ? "rouvenheck", extraModules ? [], extraHomeModules ? [] }:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit username; };
        modules = [
          ./modules/nixos/system.nix
          ./modules/nixos/desktop.nix
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
    mkLinux = { username ? "rouvenheck", system ? "aarch64-linux" }:
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
        ];
      };

  in {
    # ── Mac configurations ──────────────────────────────────────────────────
    darwinConfigurations = {
      "m5-air" = mkMac {
        hostname = "m5-air";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouven-air-m3" = mkMac {
        hostname = "rouven-air-m3";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouven-pro-m4" = mkMac {
        hostname = "rouven-pro-m4";
        extraModules = [ ./configurations/macos/macbook.nix ];
      };

      "rouvens-mac-mini" = mkMac {
        hostname = "rouvens-mac-mini";
        extraModules = [ ./configurations/macos/mac-mini-office.nix ];
      };

      "rouvens-mac-studio" = mkMac {
        hostname = "rouvens-mac-studio";
        extraModules = [ ./configurations/macos/mac-studio.nix ];
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
      };
    };

    # ── Linux (OrbStack VM / servers) ───────────────────────────────────────
    homeConfigurations = {
      "linux" = mkLinux { username = "rouvenheck"; };           # default (OrbStack)
      "linux-rouven" = mkLinux { username = "rouven"; };        # alternate username
      "linux-x86" = mkLinux { username = "rouvenheck"; system = "x86_64-linux"; };
    };
  };
}
