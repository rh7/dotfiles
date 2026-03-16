{ pkgs, ... }:

{
  # ── Zsh ──────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      ignoreAllDups = true;
      share = true;
    };
    shellAliases = {
      # Navigation
      ll  = "eza -la --icons --git";
      la  = "eza -a --icons";
      lt  = "eza --tree --level=2 --icons";
      cat = "bat";
      # zoxide init already hooks into cd

      # Git
      gs  = "git status";
      gp  = "git push";
      gl  = "git pull";
      gd  = "git diff";
      gc  = "git commit";
      gca = "git commit -a";
      gco = "git checkout";
      gb  = "git branch";
      glog = "git log --oneline --graph --decorate -20";

      # Nix
      nrs = "sudo darwin-rebuild switch --flake ~/dotfiles#m5-air";
      nup = "nix flake update ~/dotfiles";

      # Quick access
      dots = "cd ~/dotfiles && zed .";
    };
    initContent = ''
      # 1Password SSH Agent
      export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

      # zoxide init
      eval "$(zoxide init zsh)"

      # direnv hook
      eval "$(direnv hook zsh)"

      # Homebrew (Apple Silicon)
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
  };

  # ── Starship prompt ──────────────────────────────────────────────────────
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol   = "[❯](bold red)";
      };
      directory.truncation_length = 3;
      git_branch.symbol = " ";
      nix_shell.symbol = " ";
      nodejs.symbol = " ";
      python.symbol = " ";
      rust.symbol = " ";
    };
  };

  # ── mackup config (iCloud) ──────────────────────────────────────────────
  home.file.".mackup.cfg".text = ''
    [storage]
    engine = icloud

    [applications_to_sync]
    cursor
    zed
    terminal
    ssh
    git
    zsh
    telegram_macos
    franz
    spotify
    wezterm
    starship
    gnupg
    claude-code
    tripmode
  '';
}
