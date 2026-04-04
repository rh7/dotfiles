{ ... }:

{
  # ── Network/security tools (not needed on every device) ──────────────────
  homebrew.casks = [
    "wifiman"
    "wireshark"
    "burp-suite"
    "angry-ip-scanner"
    # "transmission"  # rarely used, run in Docker if needed
    "balenaetcher"
  ];

  homebrew.brews = [
    "wireguard-tools"  # WireGuard CLI for direct connections / testing
    "nmap"             # network scanning (moved from common.nix)
    "mkcert"           # local HTTPS dev certs (moved from common.nix)
    "nikto"            # web server scanner
    "sqlmap"           # SQL injection testing
    "hydra"            # password testing
    "gobuster"         # directory/DNS bruteforcing
  ];
}
