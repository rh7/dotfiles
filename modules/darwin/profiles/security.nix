{ ... }:

{
  # ── VPN and security apps ────────────────────────────────────────────────
  homebrew.casks = [
    "expressvpn"
    "private-internet-access"
    "protonvpn"
    "tunnelblick"
    "wireguard-tools"
    "cryptomator"
    "tripmode"
  ];

  homebrew.masApps = {
    "Crypto Pro" = 980888073;
  };
}
