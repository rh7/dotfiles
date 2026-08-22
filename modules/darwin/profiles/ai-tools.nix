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
    "buzz"          # offline Whisper transcription/translation (chidiwilliams/buzz)
    "lm-studio"     # local LLM runner; MLX backend selectable in-app on Apple Silicon
    "block-goose"   # Block's open-source AI agent (Goose.app)
  ];

  homebrew.brews = [
    "ollama"           # LLM CLI / inference
    "block-goose-cli"  # Goose agent CLI (pairs with the block-goose cask)
  ];
}
