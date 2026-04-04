{ ... }:

{
  # ── AI Inference: Mac Studio / GPU workloads ─────────────────────────────
  # lm-studio moved to ai-lab.nix profile
  # ollama is in darwin/profiles/ai-tools.nix (shared by all dev Macs)
  imports = [
    ../darwin/profiles/ai-lab.nix
  ];
}
