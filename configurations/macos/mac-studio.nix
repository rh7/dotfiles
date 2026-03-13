{ ... }:

{
  # ── Mac Studio AI Lab specific ───────────────────────────────────────────
  homebrew.casks = [
    "lm-studio"
  ];

  homebrew.brews = [
    "ollama"     # GPU inference — must be native (Metal)
  ];
}
