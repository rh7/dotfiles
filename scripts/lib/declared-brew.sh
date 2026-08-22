# shellcheck shell=bash
#
# Shared helper: which Homebrew packages does the flake actually DECLARE?
#
# WHY THIS EXISTS: `brew outdated` lists everything installed on the machine,
# but `brew bundle` only ever upgrades what the Brewfile declares. Conflating
# the two makes rebuild.sh promise upgrades that activation will not perform,
# and makes weekly-update.sh silently upgrade software the flake deliberately
# does not manage. Both scripts need the same answer, so it lives here rather
# than being reimplemented (and drifting) in each.
#
# Sourced by scripts/rebuild.sh and scripts/weekly-update.sh.
#
# nix-darwin wraps each homebrew.brews/casks entry as an attrset ({name,
# brewfileLine, ...}), so the name has to be projected out — a bare
# `.[]` yields objects, not strings. Same shape both lists, hence one function.
# This mirrors eval_casks() in audit-config-drift.sh; keep them consistent.

# declared_brew_names <brews|casks> <host> <flake_dir>
# Prints one name per line. Empty output on any failure — callers must treat
# "couldn't determine" as distinct from "nothing declared", since acting on an
# empty set would mean upgrading nothing (or, worse, everything).
declared_brew_names() {
  local kind="$1" host="$2" flake_dir="$3"
  nix eval --json \
    "${flake_dir}#darwinConfigurations.\"${host}\".config.homebrew.${kind}" \
    2>/dev/null \
    | jq -r 'if type=="array" then .[].name else empty end' 2>/dev/null \
    || true
}

# intersect_lines <file_a> <file_b>  — lines present in BOTH (sorted, unique)
intersect_lines() {
  comm -12 <(sort -u "$1") <(sort -u "$2")
}

# subtract_lines <file_a> <file_b>   — lines in A but NOT in B (sorted, unique)
subtract_lines() {
  comm -23 <(sort -u "$1") <(sort -u "$2")
}
