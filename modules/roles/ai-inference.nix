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

  # Grafana Alloy ships from the grafana tap — declare it so cleanup keeps it.
  homebrew.taps = [
    "grafana/grafana"
  ];

  # Inference + observability stack for the always-on Studio. These run as
  # services or are load-bearing for inference/remote access, so they must be
  # declared or `homebrew.onActivation.cleanup = "uninstall"` would remove them.
  homebrew.brews = [
    "asitop"                # terminal: Apple Silicon GPU/ANE/CPU (run: sudo asitop)
    "llama.cpp"             # local LLM inference engine
    "grafana/grafana/alloy" # metrics/log collector (runs as a service)
    "tailscale"             # tailnet daemon (runs as root — headless remote access)
    "ffmpeg"                # audio/video pipeline for transcription workloads
    "cmake"                 # build toolchain for compiling inference deps
  ];
}
