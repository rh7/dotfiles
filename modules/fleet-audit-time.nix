# The fleet's daily audit time — ONE value for every scheduler that runs it:
# the home-manager LaunchAgent / systemd timer (modules/home/profiles/
# fleet-audit.nix) and the household system LaunchDaemon (modules/darwin/
# fleet-audit.nix). Plain data, imported with `import`, not a module.
#
# Fixed, not staggered: the hostname is NOT threaded into home-manager (mkMac/
# mkNixOS pass no extraSpecialArgs; only mkLinux passes `username`). To
# stagger, add `extraSpecialArgs = { inherit hostname; }` to the mk* helpers and
# hash it into `minute`. A synchronized ~dozen-host POST at 08:17 is harmless
# for the single-writer config service.
{
  hour = 8;
  minute = 17;
}
