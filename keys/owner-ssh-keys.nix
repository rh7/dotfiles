# The owner's SSH public keys for services.rh7.remoteMaintenance
# (modules/darwin/remote-maintenance.nix). Public keys only. Each was checked
# 2026-11-16 against the device's own ~/.ssh/id_ed25519.pub fingerprint in its
# latest fleet audit (the registry's ssh_public_key is only a reference).
# Adding or rotating a key = a PR here; it reaches the Macs on their next switch.
[
  # m5-air (owner's MacBook Air M5)        SHA256:R4107IHRoT1zAmyHooXKKZKAT2YPrl6PEH8R/hT0w+Q
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMuPtbeTk2rlx6c7UJThcB+iJif5/iDOWD/ukah+SVbs rouvenheck@m5-air"
  # rouven-m5-pro (owner's MacBook Pro M5) SHA256:3Q7SjlJutfYcwo/5o4Oda7RJaq1PJI59veQRTOcWeqQ
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDnfJRNf+IXGwkXD2E9i5LEA4lJyiuVJD0FEETxGneto rouven@rouven-m5-pro"
]
