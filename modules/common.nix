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
    settings = {
      user.name = "Pip";
      user.email = "rpip@fastmail.com";
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
