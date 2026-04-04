{ ... }:

{
  # ── Network/security tools (not needed on every device) ──────────────────
  homebrew.casks = [
    "wifiman"
    # "transmission"  # rarely used, run in Docker if needed
    "balenaetcher"
  ];
}
