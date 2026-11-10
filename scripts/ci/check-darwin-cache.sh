#!/usr/bin/env bash
# Would activating the current flake.lock make a Mac COMPILE something heavy?
#
# For every darwinConfiguration (same enumeration as eval-darwin-configs.sh),
# compute the derivations a Mac would have to build because their outputs are
# not in the binary cache, drop the trivial local ones, and report what is left
# as a Markdown table (host → package names). Used by update-flake-lock.yml:
# a lock bump that evaluates fine can still point at a nixpkgs revision Hydra
# has not finished building for aarch64-darwin (2026-11-10, bot PR #109: a
# from-source .NET SDK 8 bootstrap plus pre-commit and opencode — >1h of
# compiling on every Mac, and long/failed nightly unattended updates).
#
# Method — the same decision Nix's own `queryMissing` makes, but from the
# derivation graph and the cache alone, so it is identical on any machine:
#   1. `nix derivation show -r .#darwinConfigurations.<host>.system` gives the
#      full build graph. Evaluation is platform-independent, so an
#      x86_64-linux runner gets the exact aarch64-darwin graph without a
#      darwin builder.
#   2. Walk it from the system derivation. A derivation is BUILT when it may
#      not be substituted (allowSubstitutes = false) or any of its output
#      paths is missing from the cache (HEAD <cache>/<hash>.narinfo → 404);
#      only then are its inputs walked too. Cached outputs end the walk.
#   3. Built derivations that are trivial (preferLocalBuild or
#      allowSubstitutes = false: system-path, etc, launchd plists,
#      home-manager files, activation scripts, ...) are not reported. Fixed-
#      output derivations (sources) are downloads, not compiles: never walked.
# Why not `nix build --dry-run`: its "will be built" list also omits anything
# already valid in the LOCAL store, so on a Mac that once compiled a package it
# under-reports, and its text format is not a stable interface. This method
# does not read the local store at all.
#
# Allowlist: packages that are expected to always build locally — one glob per
# line (matched against the derivation name, e.g. `foo-*`) in
# scripts/ci/darwin-cache-allowlist.txt, plus whitespace-separated globs in
# $DARWIN_CACHE_ALLOWLIST. Allowlisted builds are still listed, separately, but
# do not fail the check.
#
# Env: CACHE_URL (default https://cache.nixos.org — the only substituter the
# fleet configures), CACHE_RETRIES (curl --retry, default 4),
# DARWIN_CACHE_ALLOWLIST, DARWIN_CACHE_ALLOWLIST_FILE.
# Test seams (scripts/tests/check-darwin-cache.test.sh): CHECK_DARWIN_CACHE_FIXTURES
# = dir of <host>.json `nix derivation show -r` outputs used instead of nix;
# CHECK_DARWIN_CACHE_PRESENT = file of output hashes the "cache" has (one per
# line) used instead of HTTP.
#
# Output: the Markdown report on stdout; progress on stderr.
# Exit: 0 no heavy uncached derivation, 1 at least one, 2 could not decide
# (eval / nix / network error — fail closed, never a silent pass).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CACHE_URL=${CACHE_URL:-https://cache.nixos.org}
CACHE_URL=${CACHE_URL%/}
CACHE_RETRIES=${CACHE_RETRIES:-4}
allowlist_file=${DARWIN_CACHE_ALLOWLIST_FILE:-$here/darwin-cache-allowlist.txt}

die() { echo "check-darwin-cache: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq not found"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- allowlist ---------------------------------------------------------------
{
  if [ -f "$allowlist_file" ]; then
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$allowlist_file"
  fi
  # read -a, not an unquoted `for`: a glob like `foo-*` must not expand
  # against the files in the current directory.
  read -r -d '' -a extra <<<"${DARWIN_CACHE_ALLOWLIST:-}" || true
  for g in ${extra[@]+"${extra[@]}"}; do printf '%s\n' "$g"; done
} | awk 'NF' | jq -R . | jq -s . > "$work/allow.json"

# --- normalize `nix derivation show -r` output into a compact graph ----------
# Accepts both the legacy format (top-level object keyed by full .drv path,
# `inputDrvs`, `env.__json`) and the current one (`{version, derivations}` keyed
# by store-path basename, `inputs.drvs`, `structuredAttrs`). Result, keyed by
# drv basename: {n: name, local: preferLocalBuild, nosub: !allowSubstitutes,
# fod, outs: [output hash parts | null when unknown], ins: [drv basenames]}.
# shellcheck disable=SC2016 # jq program, not shell
normalize_jq='
  def base: sub("^.*/"; "");
  def truthy: . == true or . == "1";
  def falsy: . == false or . == "" or . == "0";
  (if type == "object" and has("derivations") then .derivations else . end)
  | with_entries(
      .value as $d
      | ($d.structuredAttrs // ($d.env.__json // null | if . then fromjson else null end) // {}) as $sa
      # Not `//`: it skips `false`, which is exactly the value that matters here.
      | (if $sa | has("preferLocalBuild") then $sa.preferLocalBuild else $d.env.preferLocalBuild end) as $plb
      | (if $sa | has("allowSubstitutes") then $sa.allowSubstitutes else $d.env.allowSubstitutes end) as $as
      | .key |= base
      | .value = {
          n: ($d.name // $d.env.name // (.key | base | .[33:] | sub("\\.drv$"; ""))),
          local: ($plb | truthy),
          nosub: ($as != null and ($as | falsy)),
          fod: ([$d.outputs[] | has("hash")] | any),
          outs: [$d.outputs[] | if .path then (.path | base | .[0:32]) else null end],
          ins: [($d.inputs.drvs // $d.inputDrvs // {}) | keys[] | base]
        })'

# Root = the one derivation no other derivation in the closure references.
# shellcheck disable=SC2016
root_jq='
  ([.[].ins[]] | map({key: ., value: true}) | from_entries) as $ref
  | [keys[] | select($ref[.] | not)]
  | if length == 1 then .[0] else error("expected exactly one root derivation, found \(length)") end'

# --- walk: which derivations would be built, given what the cache has --------
# $known: {hash: true|false}. Stops (and reports the hash as unknown) where the
# cache has not been asked yet; the caller asks and walks again.
# shellcheck disable=SC2016
walk_jq='
  def walk($g; $root; $known):
    {q: [$root], i: 0, seen: {}, build: [], unknown: []}
    | until(.i >= (.q | length);
        .q[.i] as $d | .i += 1
        | if .seen[$d] then .
          else .seen[$d] = true
          | ($g[$d] // error("derivation \($d) missing from the graph")) as $n
          | if $n.fod then .
            elif $n.nosub then .build += [$d] | .q += $n.ins
            elif ($n.outs | any(. == null)) then error("\($d): output path unknown (content-addressed?) — cannot ask the cache")
            else [$n.outs[] | $known[.]] as $st
              | if any($st[]; . == false) then .build += [$d] | .q += $n.ins
                elif any($st[]; . == null) then .unknown += [$n.outs[] | select($known[.] == null)]
                else . end
            end
          end)
    | {build, unknown: (.unknown | unique)};'

# --- cache oracle ------------------------------------------------------------
# $1: file of output hash parts; stdout: {hash: true|false}. Fails closed on
# any answer other than present/absent, and on any hash left unanswered.
ask_cache() {
  local out="$work/answers"
  if [ -n "${CHECK_DARWIN_CACHE_PRESENT:-}" ]; then
    [ -r "$CHECK_DARWIN_CACHE_PRESENT" ] || { echo "check-darwin-cache: unreadable $CHECK_DARWIN_CACHE_PRESENT" >&2; return 1; }
    awk -v f="$CHECK_DARWIN_CACHE_PRESENT" '
      BEGIN { while ((getline h < f) > 0) have[h] = 1 }
      { print $0, (($0 in have) ? 200 : 404) }' "$1" > "$out"
  else
    # shellcheck disable=SC2016 # expanded by the inner sh
    xargs -P 16 -n 1 sh -c '
      code=$(curl -sS -I -o /dev/null --retry "$2" --retry-all-errors --max-time 30 \
        -w "%{http_code}" "$1/$3.narinfo" 2>/dev/null) || code=ERR
      echo "$3 $code"' _ "$CACHE_URL" "$CACHE_RETRIES" < "$1" > "$out" || true
  fi
  if ! awk 'NR == FNR { asked[$1] = 1; next }
            { if ($2 != 200 && $2 != 404) { bad = 1; print "check-darwin-cache: cache answered " $2 " for " $1 > "/dev/stderr" }
              delete asked[$1] }
            END { for (h in asked) { bad = 1; print "check-darwin-cache: no answer for " h > "/dev/stderr" }; exit bad }' "$1" "$out"; then
    return 1
  fi
  awk '{ printf "%s\t%s\n", $1, ($2 == 200 ? "true" : "false") }' "$out" \
    | jq -R 'split("\t") | {key: .[0], value: (.[1] == "true")}' | jq -s from_entries
}

# --- hosts and graphs --------------------------------------------------------
if [ -n "${CHECK_DARWIN_CACHE_FIXTURES:-}" ]; then
  hosts=$(cd "$CHECK_DARWIN_CACHE_FIXTURES" && for f in *.json; do [ ! -e "$f" ] || echo "${f%.json}"; done)
else
  command -v nix >/dev/null || die "nix not found"
  hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]') \
    || die "could not enumerate darwinConfigurations"
fi
[ -n "$hosts" ] || die "no darwinConfigurations found — this check would be silently vacuous"

: > "$work/hosts"
for h in $hosts; do
  echo "check-darwin-cache: $h: derivation graph" >&2
  if [ -n "${CHECK_DARWIN_CACHE_FIXTURES:-}" ]; then
    cp "$CHECK_DARWIN_CACHE_FIXTURES/$h.json" "$work/raw.json"
  else
    nix derivation show -r ".#darwinConfigurations.\"$h\".system" > "$work/raw.json" \
      || die "$h: nix derivation show failed"
  fi
  jq -c "$normalize_jq" "$work/raw.json" > "$work/graph.$h.json" || die "$h: unreadable derivation JSON"
  root=$(jq -r "$root_jq" "$work/graph.$h.json") || die "$h: no unique system derivation"
  printf '%s\t%s\n' "$h" "$root" >> "$work/hosts"
done
rm -f "$work/raw.json"
jq -s 'add' "$work"/graph.*.json > "$work/graph.json"
jq -R 'split("\t") | {key: .[0], value: .[1]}' "$work/hosts" | jq -s from_entries > "$work/roots.json"

# --- ask the cache until every walk is decided -------------------------------
# Terminates: every round answers every hash it asks (or dies), so `known`
# strictly grows over a finite set.
echo '{}' > "$work/known.json"
round=0
while :; do
  round=$((round + 1))
  jq -r --slurpfile g "$work/graph.json" --slurpfile k "$work/known.json" \
    "$walk_jq"' [.[] as $r | walk($g[0]; $r; $k[0]).unknown[]] | unique[]' \
    "$work/roots.json" > "$work/ask" || die "graph walk failed"
  [ -s "$work/ask" ] || break
  echo "check-darwin-cache: round $round: asking $CACHE_URL about $(wc -l < "$work/ask" | tr -d ' ') output paths" >&2
  ask_cache "$work/ask" > "$work/new.json" || die "could not query $CACHE_URL"
  jq -s 'add' "$work/known.json" "$work/new.json" > "$work/known.next" && mv "$work/known.next" "$work/known.json"
done

# --- report ------------------------------------------------------------------
# Per host: heavy = built and not trivial; split by the allowlist.
# shellcheck disable=SC2016
jq --slurpfile g "$work/graph.json" --slurpfile k "$work/known.json" --slurpfile a "$work/allow.json" \
  "$walk_jq"'
  def glob_re: "^" + (gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*")) + "$";
  ($a[0] | map(glob_re)) as $allow
  | to_entries
  | map(.key as $h
      | [walk($g[0]; .value; $k[0]).build[] | $g[0][.] | select((.local or .nosub) | not) | .n] | unique as $heavy
      | {host: $h,
         uncached: [$heavy[] | select(. as $n | any($allow[]; . as $re | $n | test($re)) | not)],
         allowed: [$heavy[] | select(. as $n | any($allow[]; . as $re | $n | test($re)))]})' \
  "$work/roots.json" > "$work/result.json" || die "report failed"

jq -r --arg cache "$CACHE_URL" '
  def names: map("`\(.)`") | join(", ");
  ([.[].uncached[]] | unique) as $all
  | ([.[].allowed[]] | unique) as $allowed
  | (if ($all | length) == 0
     then "✅ every darwinConfiguration substitutes from \($cache): no heavy package would compile locally."
     else "❌ **\($all | length) derivation(s) not in \($cache) would compile locally** on the Macs listed below."
     end),
    "",
    "| host | not in cache (would compile locally) |",
    "|---|---|",
    (.[] | "| `\(.host)` | \(if (.uncached | length) == 0 then "—" else (.uncached | names) end) |"),
    (if ($allowed | length) > 0
     then "", "Allowlisted by-design local builds (cheap, never on Hydra — `scripts/ci/darwin-cache-allowlist.txt`): \($allowed | names)."
     else empty end)' "$work/result.json"

if jq -e 'any(.[]; .uncached | length > 0)' "$work/result.json" >/dev/null; then
  exit 1
fi
exit 0
