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
    mkMac = { hostname, extraModules ? [] }:
      nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        modules = [
          ./modules/common.nix
          ./modules/darwin/defaults.nix
          ./modules/darwin/homebrew.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.rouvenheck = import ./configurations/macos/home.nix;
            networking.hostName = hostname;
            networking.computerName = hostname;
          }
        ] ++ extraModules;
      };

    # ── Helper: Linux home-manager only (OrbStack VM / Jetson / servers) ─────
    mkLinux = { system ? "aarch64-linux", modules ? [] }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs { inherit system; };
        modules = [
          ./configurations/linux/home.nix
          ./modules/common.nix
          ./modules/editors/vim.nix
          ./modules/dev-tools/docker.nix
        ] ++ modules;
      };
  in {

    # ── macOS machines ────────────────────────────────────────────────────────
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

    # ── Linux configs ─────────────────────────────────────────────────────────
    homeConfigurations = {
      # OrbStack NixOS VM (aarch64)
      "linux" = mkLinux { system = "aarch64-linux"; };
      # Jetson AGX Orin
      "jetson" = mkLinux { system = "aarch64-linux"; };
      # Contabo VPS (x86)
      "contabo" = mkLinux { system = "x86_64-linux"; };
    };

    # ── Dev shell for working on dotfiles ─────────────────────────────────────
    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value.default = let pkgs = import nixpkgs { inherit system; }; in
        pkgs.mkShell {
          packages = with pkgs; [ git curl nixpkgs-fmt nil ];
        };
    }) [ "aarch64-linux" "aarch64-darwin" "x86_64-linux" ]);
  };
}
