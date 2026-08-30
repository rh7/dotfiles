{ ... }:

{
  # ── AI apps — day-to-day only ─────────────────────────────────────────
  # For experimental/lab AI tools, see ai-lab.nix
  homebrew.casks = [
    "claude"
    "chatgpt"
    "codex-app"
    # "claude-code"  # moved to dev-apps profile
    "superwhisper"
    "lm-studio"     # local LLM runner; MLX backend selectable in-app on Apple Silicon
    "block-goose"   # Block's open-source AI agent (Goose.app)
    "block-buzz"    # Block's workspace for humans and AI agents (Buzz.app)
  ];

  homebrew.brews = [
    "ollama"           # LLM CLI / inference
    # "block-goose-cli"  # → goose-cli in modules/common.nix (all machines)
  ];
}
