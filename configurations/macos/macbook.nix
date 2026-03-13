{ ... }:

{
  # ── MacBook-specific Homebrew casks ──────────────────────────────────────
  homebrew.casks = [
    # Writing (until fully migrated to Obsidian)
    "ulysses"

    # Finance — Germany
    "quicken"

    # Crypto / trading
    "electrum"
    "exodus"

    # Dev extras
    "pgadmin4"

    # Personal
    "vlc"
    "remarkable"
    "headway"

    # Note: Adobe CC — install manually (license-managed, no cask)
    # Note: IBKR Desktop — install from ibkr.com
    # Note: StarMoney, Finanzguru, Bank X — no casks available
  ];

  # ── Slightly smaller dock on laptop screens ───────────────────────────────
  system.defaults.dock.tilesize = 40;
}
