{ pkgs, config, ... }:

let
  npmPrefix = "${config.home.homeDirectory}/.npm-global";
in
{
  # ── Dev toolchains (shared across all developer machines) ─────────────────
  home.packages = with pkgs; [
    # Node
    nodejs_22

    # Python
    python312
    uv # fast pip/venv replacement

    # Rust
    rustup

    # Dev tools
    git-lfs
    pre-commit
    supabase-cli
    zellij # terminal multiplexer
  ];

  # ── Tools installed via npm/brew instead of Nix ──────────────────────────
  # Nix-provided npm defaults its global prefix to the immutable Nix store.
  # Keep mutable npm-installed CLIs in the user profile instead.
  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionPath = [ "${npmPrefix}/bin" ];
  # Persist the prefix in ~/.npmrc too: session vars only reach login shells, but
  # npm reads ~/.npmrc in ANY context — so the LaunchAgent/systemd audit job (and
  # other non-session `npm i -g`) resolve ~/.npm-global instead of the read-only
  # Nix store. Without this the audit's collect_npm_config would report a false
  # prefix_in_nix_store=true on every managed Mac. (No auth tokens live here.)
  home.file.".npmrc".text = "prefix=${npmPrefix}\n";

  # Claude Code   → npm i -g @anthropic-ai/claude-code  (nixpkgs version lags)
  # Railway CLI   → brew install railway                 (not reliably in nixpkgs)
  # Bun           → brew install oven-sh/bun/bun         (better updates via brew)
}
