{ pkgs, config, ... }:

let
  npmPrefix = "${config.home.homeDirectory}/.npm-global";
  localBin = "${config.home.homeDirectory}/.local/bin";
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
  home.sessionPath = [
    "${npmPrefix}/bin"
    localBin
  ];
  # NOTE: this only reaches login/interactive shells. Non-session npm (the audit
  # LaunchAgent/systemd job, cron) still sees the /nix/store prefix — tracked as a
  # follow-up to persist it in a *mutable* ~/.npmrc (not home.file, which would be
  # an immutable symlink that breaks `npm login`/`npm config set`).

  # Claude Code   → native installer in ~/.local/bin    (nixpkgs version lags)
  # Railway CLI   → brew install railway                 (not reliably in nixpkgs)
  # Bun           → brew install oven-sh/bun/bun         (better updates via brew)
}
