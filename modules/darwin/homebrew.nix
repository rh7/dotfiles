{ ... }:

{
  # ── Homebrew (managed declaratively by nix-darwin) ───────────────────────
  homebrew = {
    enable = true;

    onActivation = {
      autoUpdate = true;
      upgrade = true;
      # "zap" removes anything not listed — uncomment once you're confident
      # cleanup = "zap";
      cleanup = "uninstall";  # safe default: removes unlisted but doesn't zap
    };

    taps = [
      "homebrew/bundle"
    ];

    # ── CLI tools better installed via Homebrew (faster updates) ───────────
    brews = [
      "mas"        # Mac App Store CLI
      "mackup"     # settings sync
      "railway"    # Railway CLI
    ];

    # ── GUI apps ───────────────────────────────────────────────────────────
    casks = [
      # ── Core ──
      "1password"
      "arc"
      "obsidian"
      "raycast"
      "dropbox"

      # ── Dev ──
      "cursor"
      "zed"
      "orbstack"
      "wezterm"
      "termius"

      # ── Communication ──
      "telegram"
      "franz"
      "slack"
      "signal"
      "discord"
      "zoom"

      # ── Productivity ──
      "superhuman"
      "granola"
      "clockify"
      "notion"
      "linear-linear"
      "trello"

      # ── AI ──
      "claude"
      "chatgpt"
      "superwhisper"

      # ── Media ──
      "spotify"
      "pocket-casts"
      "endel"

      # ── Crypto / Finance ──
      "ledger-live"

      # ── VPN / Network ──
      "expressvpn"
      "private-internet-access"
      "wireguard-tools"
      "tailscale"
      "tripmode"
    ];
  };
}
