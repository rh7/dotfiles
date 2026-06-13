{ ... }:

{
  # ── macOS Server: lean headless AI-inference box (Mac Studio) ─────────────
  # A trimmed role for an always-on compute node reached over SSH/Tailscale.
  # Drops the desktop profiles a workstation gets (communication, productivity,
  # media, security) plus the consumer dock and laptop-only MAS apps.
  # AI inference apps come from ai-inference.nix (added via flake extraModules).
  imports = [
    ../darwin/profiles/core.nix      # base: Tailscale, 1Password, Dropbox, mas
    ../darwin/profiles/dev-apps.nix  # OrbStack, Ghostty, zellij, editors
    ../darwin/profiles/ai-tools.nix  # Claude, ChatGPT, LM Studio, Ollama
  ];

  # ── Minimal dock — only what's useful when screen-sharing into the box ──
  system.defaults.dock.persistent-others = [];
  system.defaults.dock.persistent-apps = [
    "/Applications/Ghostty.app"
    "/Applications/Google Chrome.app"
    "/Applications/Cursor.app"
    "/Applications/Claude.app"
    "/Applications/ChatGPT.app"
    "/Applications/LM Studio.app"
  ];
}
