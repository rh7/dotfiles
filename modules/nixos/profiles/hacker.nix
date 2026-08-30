{ pkgs, ... }:

{
  # ── Network / security tools (NixOS) ─────────────────────────────────────
  # Opt-in, not part of the workstation-linux role — imported per-host (see
  # configurations/nixos/thinkpad.nix), matching the "not needed on every
  # device" scoping of modules/darwin/profiles/hacker.nix on the mac side.
  #
  # The mac profile leans on Homebrew casks (wireshark, burp-suite); this is the
  # nixpkgs equivalent set, weighted toward the Wi-Fi tooling that has no cask.
  environment.systemPackages = with pkgs; [
    aircrack-ng     # Wi-Fi WEP/WPA cracking suite
    hcxdumptool     # capture WPA handshakes / PMKIDs
    hcxtools        # convert captures for hashcat
    wifite2         # automated wireless auditing wrapper
    wirelesstools   # iwconfig / iwlist — legacy wireless CLI
    metasploit      # exploitation framework
    ptunnel         # tunnel TCP over ICMP
  ];
}
