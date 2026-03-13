{ pkgs, ... }:

{
  home.username     = "rouvenheck";
  home.homeDirectory = "/Users/rouvenheck";
  home.stateVersion  = "24.11";
  programs.home-manager.enable = true;

  # ── Dev toolchains (Nix-managed — no more manual installs) ───────────────
  home.packages = with pkgs; [
    # Node
    nodejs_22

    # Python
    python312
    uv              # fast pip replacement, use instead of pip directly

    # Rust
    rustup

    # Claude Code
    nodePackages."@anthropic-ai/claude-code"

    # Railway CLI
    nodePackages."@railway/cli"

    # Supabase CLI
    supabase-cli

    # Other dev tools
    git-lfs
    pre-commit
  ];

  # ── Zed editor config ─────────────────────────────────────────────────────
  home.file.".config/zed/settings.json".text = builtins.toJSON {
    ui_font_size     = 14;
    buffer_font_family = "JetBrainsMono Nerd Font";
    buffer_font_size = 13;
    theme            = "One Dark";
    tab_size         = 2;
    format_on_save   = "on";
    autosave         = { after_delay = { milliseconds = 1000; }; };
    terminal.font_family = "JetBrainsMono Nerd Font";
    vim_mode         = false;
  };
}
