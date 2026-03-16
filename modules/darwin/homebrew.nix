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
      "1password" "google-chrome"
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

      # ── AI ──
      "claude"
      "chatgpt" "claude-code"
      "superwhisper"

      # ── Media ──
      "spotify"
      "pocket-casts"

      # ── Crypto / Finance ──

      # ── VPN / Network ──
      "expressvpn"
      "private-internet-access"
      "tailscale-app"
      "tripmode"
    ];
  };
}
