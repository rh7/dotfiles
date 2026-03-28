{ pkgs, ... }:

{
  # ── Dev toolchains (shared across all developer machines) ─────────────────
  home.packages = with pkgs; [
    # Node
    nodejs_22

    # Python
    python312
    uv              # fast pip/venv replacement

    # Rust
    rustup

    # Dev tools
    git-lfs
    pre-commit
    supabase-cli
  ];

  # ── Tools installed via npm/brew instead of Nix ──────────────────────────
  # Claude Code   → npm i -g @anthropic-ai/claude-code  (nixpkgs version lags)
  # Railway CLI   → brew install railway                 (not reliably in nixpkgs)
  # Bun           → brew install oven-sh/bun/bun         (better updates via brew)
}
