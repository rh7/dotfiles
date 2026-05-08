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
    nixpkgs-fmt  # Nix formatter
    nil          # Nix LSP
    nvd          # Nix version diff — preview changes before rebuild

    # Secrets
    age          # encryption for sops-nix
    sops         # secret management

    # Network
    gh

    # nmap, mkcert — moved to hacker.nix profile
  ];

  # ── Git ──────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    # Silence home-manager 25.05 deprecation: format default changed
    # "openpgp" → null. We don't sign commits yet (1Password SSH block
    # below is commented out), so null = no gpg.format written to
    # .gitconfig. Switch to "ssh" when SSH signing is enabled.
    signing.format = null;
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

  # ── direnv — installed via Homebrew on macOS due to nixpkgs build bug
  # programs.direnv = {
  #   enable = true;
  #   nix-direnv.enable = true;
  # };

  # ── Desktop shortcut — double-click to rebuild ───────────────────────────
  home.file."Desktop/Update.command" = {
    text = ''
      #!/bin/bash
      ~/dotfiles/scripts/rebuild.sh
    '';
    executable = true;
  };

  # ── Shell — import from shell module ─────────────────────────────────────
  imports = [ ./shell/zsh.nix ];
}
