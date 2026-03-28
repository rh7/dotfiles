{ ... }:

{
  # ── AI apps and tools ────────────────────────────────────────────────────
  homebrew.casks = [
    "claude"
    "chatgpt"
    "claude-code"
    "superwhisper"
  ];

  homebrew.brews = [
    "ollama"     # LLM CLI / inference
  ];
}
