{ ... }:

{
  # ── AI Lab / Development tools (experimental, not day-to-day) ────────────
  homebrew.casks = [
    # "anythingllm"  # run in Docker on lab, connect to Mac Studio LLMs
    # "gpt4all"  # run in Docker on lab, connect to Mac Studio LLMs
    "lm-studio"
    "mindmac"
    # "langgraph-studio"  # deprecated, disabled 2026-08-30
    # enchanted — Mac App Store only
  ];

  # Note: Goose, MORagents, OpenCode, Hyprnote — not in Homebrew, manual install
}
