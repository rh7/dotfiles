{ ... }:

{
  # ── AI apps — day-to-day ──────────────────────────────────────────────
  homebrew.casks = [
    "claude"
    "chatgpt"
    "claude-code"
    "superwhisper"

    # AI lab / experimental
    "anythingllm"
    "enchanted"
    "gpt4all"
    "mindmac"
  ];

  homebrew.brews = [
    "ollama"     # LLM CLI / inference
  ];

  # Note: Goose, MORagents, OpenCode, Hyprnote — not in Homebrew, manual install
}
