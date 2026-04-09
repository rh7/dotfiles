{ pkgs, ... }:

{
  # ── AI Inference: Mac Studio / GPU workloads ─────────────────────────────
  # lm-studio moved to ai-lab.nix profile
  # ollama is in darwin/profiles/ai-tools.nix (shared by all dev Macs)
  imports = [
    ../darwin/profiles/ai-lab.nix
  ];

  # ── System monitoring (GPU, ANE, memory bandwidth) ─────────────────────
  homebrew.casks = [
    "stats"          # menu bar: CPU, GPU, memory, disk, network
  ];

  homebrew.brews = [
    "asitop"         # terminal: Apple Silicon GPU/ANE/CPU (run: sudo asitop)
  ];
}
