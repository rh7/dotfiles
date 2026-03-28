{ ... }:

{
  # ── AI Inference: Mac Studio / GPU workloads ─────────────────────────────
  # ollama is already in darwin/profiles/ai-tools.nix (shared by all dev Macs).
  # This role adds heavier inference tools specific to GPU workstations.
  homebrew.casks = [
    "lm-studio"
  ];
}
