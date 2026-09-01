{ ... }:

{
  home.file.".local/bin/omp-coordinator" = {
    source = ../../../scripts/omp-coordinator;
    executable = true;
  };

  xdg.configFile."omp/coordinator-lean.yml".source = ./omp-coordinator.yml;
}
