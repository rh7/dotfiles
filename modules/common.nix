{ pkgs, ... }:

{
  # ── CLI tools available on every machine ─────────────────────────────────
  home.packages = with pkgs; [
    # Core utils
    curl
    wget
    jq
    yq
    git
    gh           # GitHub CLI
    ripgrep      # better grep
    fd           # better find
    bat          # better cat
    eza          # better ls
    fzf          # fuzzy finder
    zoxide       # smarter cd
    htop
    bottom       # better htop
    tldr
    tree

    # Dev
    gnupg
    mkcert
    nixpkgs-fmt  # Nix formatter
    nil          # Nix LSP

    # Network
    nmap
  ];

  # ── Git ──────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    userName = "Rouven Heck";
    userEmail = "rouven@fidenexum.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "zed --wait";
    };
    ignores = [
      ".DS_Store"
      ".env"
      ".env.local"
      "*.local"
      ".direnv"
      ".claude"
    ];
  };

  # ── Shell — import from shell module ─────────────────────────────────────
  imports = [ ../modules/shell/zsh.nix ];
}
