{ ... }:

{
  # ── VPN and security apps ────────────────────────────────────────────────
  homebrew.casks = [
    # expressvpn, tripmode — moved to core profile
    "private-internet-access"
    "protonvpn"
    "tunnelblick"
    # wireguard-tools — moved to hacker.nix as a brew formula
    "cryptomator"
  ];
  # Crypto Pro — moved to finance profile
}
