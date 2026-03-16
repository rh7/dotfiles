{ pkgs, ... }:

{
  # ── CLI tools available on every machine ─────────────────────────────────
  home.packages = with pkgs; [
    # Core utils
    curl
    wget
    jq
    yq
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
    watch

    # Dev
    gnupg
    mkcert
    direnv       # per-project env/shells
    nixpkgs-fmt  # Nix formatter
    nil          # Nix LSP

    # Network
    nmap
    gh
  ];

  # ── Git ──────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    settings.user.name = "Rouven Heck";
    settings.user.email = "dev@heck.cc";
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "zed --wait";
      credential."https://github.com".helper = "!gh auth git-credential";
      credential."https://gist.github.com".helper = "!gh auth git-credential";
      # 1Password SSH signing (optional, enable when ready)
      # gpg.format = "ssh";
      # user.signingkey = "ssh-ed25519 ...";  # from 1Password
      # commit.gpgsign = true;
      # gpg.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    };
    ignores = [
      ".DS_Store"
      ".env"
      ".env.local"
      "*.local"
      ".direnv"
      ".claude"
      "node_modules"
      "__pycache__"
      ".venv"
    ];
  };

  # ── Shell — import from shell module ─────────────────────────────────────
  imports = [ ./shell/zsh.nix ];
}
