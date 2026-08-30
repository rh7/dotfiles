{ pkgs, lib, ... }:

# Buzz — Block's open-source workspace for humans and AI agents.
#
# macOS installs it via the `block-buzz` Homebrew cask (see
# modules/darwin/profiles/ai-tools.nix). nixpkgs has no Buzz package, and the
# project ships only an official AppImage / .deb for Linux, so we wrap the
# AppImage with appimageTools — self-contained, pinned by hash, no imperative
# install step.
#
# x86_64 only: the release ships `amd64` exclusively, and the only other Linux
# host (nixos-vm) is aarch64, where this evaluates to an empty package list.
# Bump `version` + `hash` together to update; get the hash with
#   nix store prefetch-file <url>

let
  pname = "buzz";
  version = "0.5.20";

  src = pkgs.fetchurl {
    url = "https://github.com/block/buzz/releases/download/desktop-v${version}/Buzz_${version}_amd64.AppImage";
    hash = "sha256-j6qvBOygHA5sFeadNzSCd1R3pub3d6nrmOof6d6Ut84=";
  };

  # Pull the bundled .desktop entry and icons back out for desktop integration.
  contents = pkgs.appimageTools.extract { inherit pname version src; };

  buzz = pkgs.appimageTools.wrapType2 {
    inherit pname version src;

    extraInstallCommands = ''
      # The AppImage's own entry has Exec/Icon=buzz-desktop (its internal binary
      # name); wrapType2 installs the binary as `buzz`, so repoint Exec at it.
      # StartupWMClass is left as buzz-desktop — that is the class the running
      # window actually reports, and it must match for the taskbar icon to bind.
      install -Dm444 ${contents}/usr/share/applications/Buzz.desktop \
        $out/share/applications/Buzz.desktop
      substituteInPlace $out/share/applications/Buzz.desktop \
        --replace-fail 'Exec=buzz-desktop' 'Exec=buzz'

      cp -r ${contents}/usr/share/icons $out/share/
    '';
  };
in
{
  environment.systemPackages =
    lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [ buzz ];
}
