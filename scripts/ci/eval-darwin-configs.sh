#!/usr/bin/env bash
# Evaluate every darwinConfiguration's system derivation (no build).
#
# Shared by .github/workflows/flake-check.yml and update-flake-lock.yml. The
# lock bot cannot rely on flake-check running on its PR — pushes and PRs made
# with the workflow's GITHUB_TOKEN do not trigger other workflows — so it runs
# this same gate in its own job. One script keeps the two gates identical.
#
# Evaluation is cross-platform, so a Linux runner validates the aarch64-darwin
# configs. `nix flake check --all-systems` is intentionally NOT used: it
# cross-evaluates the aarch64-linux nixos-vm config against an x86_64-only
# package and false-fails.
#
# Exit: 0 all evaluate, 1 any failed or none were found.
set -euo pipefail

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
if [ -z "$hosts" ]; then
  echo "::error::no darwinConfigurations found — this gate would be silently vacuous"
  exit 1
fi
echo "darwinConfigurations: $(echo "$hosts" | tr '\n' ' ')"
fail=0
for h in $hosts; do
  echo "::group::eval $h"
  if nix eval ".#darwinConfigurations.\"$h\".system.drvPath" >/dev/null; then
    echo "$h: OK"
  else
    echo "$h: EVAL FAILED"
    fail=1
  fi
  echo "::endgroup::"
done
if [ "$fail" -ne 0 ]; then
  echo "::error::one or more darwinConfigurations failed to evaluate"
  exit 1
fi
echo "all darwinConfigurations evaluate cleanly"
