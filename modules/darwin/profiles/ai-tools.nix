{ ... }:

{
  # ── AI apps — day-to-day only ─────────────────────────────────────────
  # For experimental/lab AI tools, see ai-lab.nix
  homebrew.casks = [
    "claude"
    "chatgpt"
    # "claude-code"  # moved to dev-apps profile
    "superwhisper"
  ];

  homebrew.brews = [
    "ollama"     # LLM CLI / inference
  ];
}
