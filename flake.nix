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

    # ── Helper: Linux (Home Manager standalone — for OrbStack/servers) ──────
    mkLinux = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
      modules = [
        ./configurations/linux/home.nix
        ./modules/common.nix
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

    # ── Linux (OrbStack VM / servers) ───────────────────────────────────────
    homeConfigurations."linux" = mkLinux;
  };
}
