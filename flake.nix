{
  description = "My universal Nix setup for Mac and Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, home-manager, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        hm = pkgs.callPackage (import home-manager { inherit pkgs; }) {};
      in {
        # Build home config for any machine
        homeConfigurations = {
          # Mac users
          mac1 = hm.lib.homeManagerConfiguration {
            pkgs = pkgs;
            modules = [
              ./configurations/macos/home.nix
              ./modules/common.nix
              (import ./modules/editors/vim.nix)
            ];
          };

          # Linux user
          linux1 = hm.lib.homeManagerConfiguration {
            pkgs = pkgs;
            modules = [
              ./configurations/linux/home.nix
              ./modules/common.nix
              (import ./modules/dev-tools/docker.nix)
            ];
          };
        };

        # For new machines: make it easy
        packages = {
          install-macos = pkgs.writeShellScriptBin "install-macos" ''
            echo "Setting up your macOS machine with Nix..."
            nix run .#homeConfigurations.mac1 -- switch --flake .
          '';
        };
      }
    );
}
