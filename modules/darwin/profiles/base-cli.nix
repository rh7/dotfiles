{ pkgs, ... }:

{
  # ── Fleet-wide CLI tools in the SYSTEM profile — every Mac, every account ──
  # Imported by mkMac (flake.nix) for every darwinConfiguration. Lands in
  # /run/current-system/sw/bin, so it reaches accounts home-manager does not
  # manage (household Macs' daily user, the maintainer's account there) and
  # Macs where Homebrew is off (the Studio). Home-manager profiles that also
  # carry a tool (modules/common.nix: gh) are harmless duplicates on PATH.
  environment.systemPackages = with pkgs; [
    gh   # GitHub CLI — `gh auth login` once per account
  ];
}
