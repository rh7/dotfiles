#!/usr/bin/env bash
# Summarize what changed between two flake.lock files as a Markdown table.
#
# Usage: scripts/ci/flake-lock-diff.sh OLD_LOCK NEW_LOCK
#
# One row per lock node whose locked revision changed, was added, or was
# removed (transitive inputs included — they ship to devices too):
#   | input | old | new | compare |
# with each side as `<rev12> (<lastModified as YYYY-MM-DD, UTC>)`. GitHub
# inputs get an old...new compare link. Prints "No input changes." when the
# locks pin the same revisions.
#
# Exit: 0 summary printed, 2 usage / unreadable or malformed lock. A malformed
# lock must not render as "No input changes." — that would describe a broken
# update as a no-op in the PR body.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 OLD_LOCK NEW_LOCK" >&2
  exit 2
fi
for f in "$1" "$2"; do
  if ! jq -e '.nodes | type == "object"' "$f" >/dev/null 2>&1; then
    echo "flake-lock-diff: not a readable flake.lock: $f" >&2
    exit 2
  fi
done

jq -rn --slurpfile old "$1" --slurpfile new "$2" '
  def side:
    if . == null then "—"
    else ((.locked.rev // .locked.narHash // "?") | .[0:12]) as $r
      | (if .locked.lastModified then (.locked.lastModified | strftime("%Y-%m-%d")) else "?" end) as $d
      | "`\($r)` (\($d))"
    end;
  def compare($o; $n):
    if $o != null and $n != null
       and $o.locked.type == "github" and $n.locked.type == "github"
       and $o.locked.owner == $n.locked.owner and $o.locked.repo == $n.locked.repo
       and $o.locked.rev != null and $n.locked.rev != null
    then "[diff](https://github.com/\($n.locked.owner)/\($n.locked.repo)/compare/\($o.locked.rev)...\($n.locked.rev))"
    else "" end;
  ($old[0].nodes) as $O | ($new[0].nodes) as $N
  | [ (($O | keys) + ($N | keys)) | unique[] | select(. != "root")
      | . as $k | {k: $k, o: $O[$k], n: $N[$k]}
      | select((.o.locked // null) != (.n.locked // null)) ]
  | if length == 0 then "No input changes."
    else
      ( "| input | old | new | compare |",
        "|---|---|---|---|",
        ( .[] | "| `\(.k)` | \(.o | side) | \(.n | side) | \(compare(.o; .n)) |" ) )
    end
'
