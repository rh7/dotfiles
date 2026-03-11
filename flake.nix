{
  description = "My universal Nix setup for Mac and Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      # Helper to build a home configuration for a given system
      mkHome = { system, modules }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs { inherit system; };
          modules = modules;
        };
    in {
      homeConfigurations = {
        # Mac (Apple Silicon)
        mac = mkHome {
          system = "aarch64-darwin";
          modules = [
            ./configurations/macos/home.nix
            ./modules/common.nix
            ./modules/editors/vim.nix
          ];
        };

        # Linux (ARM64 — OrbStack VM / Docker)
        linux = mkHome {
          system = "aarch64-linux";
          modules = [
            ./configurations/linux/home.nix
            ./modules/common.nix
            ./modules/editors/vim.nix
            ./modules/dev-tools/docker.nix
          ];
        };
      };

      # Dev shell for working on the dotfiles themselves
      devShells = builtins.listToAttrs (map (system: {
        name = system;
        value = {
          default = let pkgs = import nixpkgs { inherit system; }; in
            pkgs.mkShell {
              packages = with pkgs; [ git curl jq ];
            };
        };
      }) [ "aarch64-linux" "aarch64-darwin" "x86_64-linux" ]);
    };
}
