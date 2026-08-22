# shellcheck shell=bash
#
# Shared helper: which packages does the flake actually DECLARE?
#
# Covers Homebrew formulae/casks (declared_brew_names) and Mac App Store apps
# (declared_mas_ids). Named declared-packages.sh, not declared-brew.sh, because
# MAS is in scope too.
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

  # Shape is validated SEPARATELY from extraction, and deliberately without
  # `jq -e` around the extraction: `-e` exits 4 when nothing is output, so an
  # empty array — a host that legitimately declares no casks — would be
  # reported as a failure. Splitting them keeps "wrong shape" (error) distinct
  # from "empty list" (success, no output).
  jq -e 'if type=="array" then true
         else error("homebrew list was \(type), expected array") end' \
    >/dev/null <<<"$raw" 2>/dev/null || return 1

  # error() makes jq exit nonzero on its own, so an entry missing .name fails
  # rather than printing the string "null" as if it were a package.
  jq -r '.[] | (.name // error("homebrew entry without .name"))' \
    <<<"$raw" 2>/dev/null || return 1
}

# declared_mas_ids <flake_ref>
#
# Prints one Mac App Store app ID per line. Returns nonzero if evaluation or
# parsing fails. Zero declarations is a SUCCESS with empty output.
#
# MAS apps are not a nix-darwin option — they are `mas_install <id> "<name>"`
# calls that profiles append to postActivation (helper in modules/darwin/mas.nix).
# So the declared set has to be recovered by scraping the merged activation
# script. audit-config-drift.sh's eval_mas_ids() does the same; if the
# mas_install call convention changes, both must change together.
#
# The scrape is deliberately STRICT, because this output selects upgrade
# targets and a false positive would upgrade something undeclared:
#   - anchored to the start of a line (leading whitespace allowed), so a
#     commented-out `# mas_install 123` or a mid-line mention is not a
#     declaration;
#   - the id must be followed by whitespace or end-of-line, so `mas_install
#     123abc` does not match;
#   - optional surrounding quotes are tolerated (`mas_install "123"`).
# Fixtures for these cases live in scripts/tests/declared-mas-ids.test.sh.
declared_mas_ids() {
  local flake_ref="$1"
  local dir="${flake_ref%#*}" host="${flake_ref##*#}"
  local raw text

  raw=$(nix eval --json \
    "${dir}#darwinConfigurations.\"${host}\".config.system.activationScripts.postActivation.text" \
    2>/dev/null) || return 1

  # Shape validated first, same split as declared_brew_names. An unexpected type
  # must FAIL: `if type=="string" then . else empty end` exited 0 with no
  # output, which the caller read as "this host declares no MAS apps" — the
  # encode-errors-as-emptiness bug this library exists to prevent.
  jq -e 'if type=="string" then true
         else error("postActivation.text was \(type), expected string") end' \
    >/dev/null <<<"$raw" 2>/dev/null || return 1

  text=$(jq -r '.' <<<"$raw" 2>/dev/null) || return 1

  printf '%s\n' "$text" | scrape_mas_ids
}

# scrape_mas_ids  — reads activation-script text on stdin, prints ids.
#
# Split out as its own function so the fixture tests can drive the REAL parser
# instead of a copy of it. An earlier test duplicated this awk program while
# claiming to extract it, which meant the library and its tests could diverge
# and the suite would still pass.
#
# awk rather than `grep | awk | sort -u || true`: awk exits 0 when nothing
# matches, so "no declarations" needs no status masking — whereas the old
# trailing `|| true` swallowed EVERY failure in the pipeline (grep, awk, sort,
# write errors), not just grep's no-match, despite a comment claiming otherwise.
#
# Quotes must MATCH. `"?[0-9]+"?` accepted `mas_install "123` and
# `mas_install 123"`, so the two forms are spelled out as alternatives instead.
scrape_mas_ids() {
  awk '
    /^[[:space:]]*mas_install[[:space:]]+[0-9]+([[:space:]]|$)/ ||
    /^[[:space:]]*mas_install[[:space:]]+"[0-9]+"([[:space:]]|$)/ {
      match($0, /[0-9]+/)
      print substr($0, RSTART, RLENGTH)
    }
  ' | LC_ALL=C sort -u
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
