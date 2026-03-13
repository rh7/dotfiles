{ ... }:

{
  # ── Homebrew — declarative cask management ───────────────────────────────
  # nix-darwin drives Homebrew; anything NOT listed here gets removed on `nrs`
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate  = true;
      upgrade     = true;
      cleanup     = "zap";  # removes unlisted casks/brews
    };

    taps = [
      "homebrew/bundle"
    ];

    # ── Installed on every machine ───────────────────────────────────────
    casks = [
      # Security
      "1password"

      # Browsers
      "arc"

      # Productivity
      "raycast"
      "obsidian"
      "notion"
      "linear-linear"
      "granola"
      "superwhisper"
      "superhuman"
      "clockify"

      # Communication
      "telegram"
      "slack"
      "signal"
      "franz"          # multi-account WhatsApp
      "discord"
      "zoom"

      # Dev
      "cursor"
      "zed"
      "wezterm"
      "termius"
      "docker"
      "orbstack"

      # Storage & sync
      "dropbox"

      # Finance / crypto
      "ledger-live"
      "crypto-pro"

      # VPN / security
      "expressvpn"
      "wireguard"
      "gpg-suite"

      # AI
      "claude"
      "chatgpt"

      # Media
      "spotify"
      "pocket-casts"
      "endel"

      # Utilities
      "tailscale"
      "tripmode"

      # Fonts
      "font-jetbrains-mono-nerd-font"
      "font-inter"
    ];

    # ── CLI tools better managed via Homebrew than Nix on macOS ─────────
    brews = [
      "mas"      # Mac App Store CLI
      "mackup"   # App settings sync
    ];
  };
}
