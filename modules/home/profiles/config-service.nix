{ pkgs, lib, config, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDir = config.home.homeDirectory;
in {
  # ── Config service auto-start (runs on the Mac Studio / server) ──────────
  # Keeps the device management config service running via launchd (macOS)
  # or systemd (Linux).

  launchd.agents.config-service = lib.mkIf isDarwin {
    enable = true;
    config = {
      Label = "com.rh.config-service";
      ProgramArguments = [
        "${pkgs.nodejs_22}/bin/node"
        "--import" "tsx"
        "src/index.ts"
      ];
      WorkingDirectory = "${homeDir}/rh-device-management/services/config-service";
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "${homeDir}/Library/Logs/config-service.log";
      StandardErrorPath = "${homeDir}/Library/Logs/config-service.error.log";
      EnvironmentVariables = {
        PORT = "3456";
        PATH = "${pkgs.nodejs_22}/bin:/usr/bin:/bin";
      };
    };
  };

  systemd.user.services.config-service = lib.mkIf (!isDarwin) {
    Unit = {
      Description = "Device management config service";
      After = [ "network.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "${homeDir}/rh-device-management/services/config-service";
      ExecStart = "${pkgs.nodejs_22}/bin/node --import tsx src/index.ts";
      Restart = "on-failure";
      RestartSec = 5;
      Environment = [
        "PORT=3456"
        "PATH=${pkgs.nodejs_22}/bin:/usr/bin:/bin"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
