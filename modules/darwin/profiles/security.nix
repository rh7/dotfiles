{ ... }:

{
  # ── VPN and security apps ────────────────────────────────────────────────
  homebrew.casks = [
    # expressvpn, tripmode — moved to core profile
    # "private-internet-access"  # install manually — quarantine issues with Homebrew cask
    "protonvpn"
    "tunnelblick"
    # wireguard-tools — moved to hacker.nix as a brew formula
    "cryptomator"
  ];
  # Crypto Pro — moved to finance profile
}
