{ ... }:

{
  # ── VPN and security apps ────────────────────────────────────────────────
  homebrew.casks = [
    # expressvpn — moved to core profile (installed manually; cask needs GUI auth)
    # tripmode — provisioned from the App Store in productivity.nix, not a cask
    # "private-internet-access"  # install manually — quarantine issues with Homebrew cask
    "protonvpn"
    "tunnelblick"
    # wireguard-tools — moved to hacker.nix as a brew formula
    "cryptomator"
  ];
  # Crypto Pro — moved to finance profile
}
