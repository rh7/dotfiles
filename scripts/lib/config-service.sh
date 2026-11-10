# shellcheck shell=bash
#
# Load the fleet's ONE config-service resolver (find_config_service) into a
# script that runs from a dotfiles checkout.
#
# The resolver lives as a marked block inside scripts/collector-runner.sh (and a
# verbatim copy in scripts/audit-device.sh, pinned by
# scripts/tests/find-config-service.test.sh). Those two cannot source a library —
# they are distributed as single self-contained files over HTTP. Scripts that
# always run from a clone (setup-secrets.sh, sops-add-host.sh) CAN read a sibling
# file, so they load that same block instead of carrying a third copy that could
# drift: pin files, CONFIG_SERVICE_URL, the impostor check and fail-closed-on-pin
# all behave identically.
#
# Sourced by scripts/setup-secrets.sh and scripts/sops-add-host.sh.
# Returns nonzero (and defines nothing) if the block cannot be found.

load_config_service_resolver() {
  local repo="$1" src=""
  src=$(sed -n '/^# >>> BEGIN SHARED CONFIG-SERVICE RESOLVER >>>/,/^# <<< END SHARED CONFIG-SERVICE RESOLVER <<</p' \
    "$repo/scripts/collector-runner.sh" 2>/dev/null) || return 1
  [[ "$src" == *'find_config_service()'* ]] || return 1
  eval "$src"
}
