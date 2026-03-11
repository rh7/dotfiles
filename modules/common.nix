{ pkgs, ... }:

{
  home.packages = with pkgs; [
    curl
    jq
    git
    ripgrep
    fd
    tree
    htop
  ];

  programs.git = {
    enable = true;
    userName = "rh7";
    userEmail = "rh7@users.noreply.github.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      gs = "git status";
      gd = "git diff";
    };
  };
}
