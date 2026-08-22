# shellcheck shell=bash
#
# Shared helper: which Homebrew packages does the flake actually DECLARE?
#
# WHY THIS EXISTS: `brew outdated` lists everything installed, but `brew bundle`
# only upgrades what the Brewfile declares. Conflating the two made rebuild.sh
# promise upgrades activation never performed, and made weekly-update.sh act on
# software the flake deliberately does not manage. Both scripts need the same
# answer, so it lives here rather than drifting apart in each.
#
# Sourced by scripts/rebuild.sh and scripts/weekly-update.sh.
#
# ── ERRORS ARE NOT EMPTINESS ────────────────────────────────────────────────
# An earlier version ended these pipelines with `|| true`. That encoded failure
# as empty output, and callers could only detect it by testing whether BOTH
# categories came back empty — so a failure in ONE category (brews evaluates,
# casks does not) sailed straight through: every outdated cask silently became
# "undeclared drift", the weekly job skipped that whole class of upgrade, and it
# exited 0 looking successful.
#
# So: these functions return NONZERO on failure and print nothing. An empty
# result WITH a zero status means "genuinely nothing declared", which is a
# legitimate state for a host with no casks. Callers MUST check the status per
# category — do not infer failure from empty output, and do not add `|| true`
# at a call site, which would reintroduce exactly this bug.

# declared_brew_names <brews|casks> <flake_ref>
#
# flake_ref is a full reference like "/path/to/dotfiles#hostname" — the SAME one
# used to build and activate. It is taken whole rather than reassembled from a
# host plus a directory, because those could disagree: with `--flake other#host`
# the preview would evaluate the default dotfiles dir while the build used the
# other flake, describing a configuration that was never activated.
#
# Prints one name per line on stdout. Returns nonzero if evaluation fails.
declared_brew_names() {
  local kind="$1" flake_ref="$2"
  local dir="${flake_ref%#*}" host="${flake_ref##*#}"
  local raw

  # nix-darwin wraps each homebrew.brews/casks entry as an attrset ({name,
  # brewfileLine, ...}), so the name must be projected out — a bare `.[]` yields
  # objects. Mirrors eval_casks() in audit-config-drift.sh; keep consistent.
  raw=$(nix eval --json \
    "${dir}#darwinConfigurations.\"${host}\".config.homebrew.${kind}" \
    2>/dev/null) || return 1

  jq -r 'if type=="array" then .[].name else empty end' <<<"$raw" 2>/dev/null \
    || return 1
}

# intersect_lines <file_a> <file_b>  — lines present in BOTH (sorted, unique)
# LC_ALL=C so comm's ordering assumption always matches how sort ordered the
# input, regardless of the caller's locale.
intersect_lines() {
  LC_ALL=C comm -12 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$2")
}

# subtract_lines <file_a> <file_b>   — lines in A but NOT in B (sorted, unique)
subtract_lines() {
  LC_ALL=C comm -23 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$2")
}
