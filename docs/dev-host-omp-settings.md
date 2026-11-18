# Dev-host OMP global settings

Owns [dotfiles#145](https://github.com/rh7/dotfiles/issues/145), part of the
[approved token plan](https://github.com/rh7/repo-management/issues/1209).
The live apply is **after this change merges**, not an effect of merging.

## Ownership

`hosts/rhdevvps/omp-settings.json` is a flat setting-path manifest, not an OMP
startup overlay. JSON avoids an additional YAML parser dependency. It manages:

- Lane compaction: threshold 120,000 tokens; idle compaction enabled above
  60,000 tokens after 300 seconds.
- Tool artifacts: spill threshold 16 KB; tail 150 lines.
- Reviewer compaction: 120,000 tokens for `reviewer-openai`, `reviewer-claude`,
  `reviewer-grok`, `gate-reviewer`, `reviewer`, and `security-reviewer`.
- Retry: `fallbackOn: usage-limit`, `usageAwareFallback: true`.

No `modelRoles`, `retry.fallbackChains`, credentials, account-pool settings, or
seat overlays are managed. Model routing remains with repo-management's
`scripts/portfolio model-route`. Other `task`/`retry` keys and custom reviewer
threshold entries survive apply. The six managed reviewer names override their
old values; they do not replace unrelated reviewer names.

Repo-management's existing coordinator/planner/lead overlays remain at 400,000
tokens with `idleEnabled: false`. Do not change them to adopt this manifest.

## Preview and apply

Requirements: Linux dev host, Python 3, and OMP with `config list --scope global
--json` support (verified with OMP 18.22.2). This entrypoint targets the existing
regular `config.yml` in `PI_CODING_AGENT_DIR`, or `~/.omp/agent` when unset. It
is not a profile migration tool; use an explicit agent directory for a relocated
configuration.

From the reviewed, merged dotfiles revision:

```bash
PI_CODING_AGENT_DIR="$HOME/.omp/agent" ./scripts/apply-omp-settings --dry-run
PI_CODING_AGENT_DIR="$HOME/.omp/agent" ./scripts/apply-omp-settings
```

Preview reads a temporary copy with isolated profile/home/project settings. It
prints only the managed-key diff and does not create a DB, lock, backup, or
configuration in the target profile. Apply takes a private
`config.yml.bak-<UTC>` backup before the first write. Keep this backup outside
Git: it contains the **whole original config**, which may contain private data.

Writes use `omp config set <key> <value>` and OMP's settings lock, not a YAML
rewrite. Before/after output is limited to the managed keys from `omp config
list`; every managed value is read back. A failed write/read or mismatch exits
nonzero. A partial apply is not rolled back automatically: retain the printed
backup path and inspect the failure. Reapplying converges the managed values.

Serialize this operation with other global writers. The script serializes its
own apply/rollback invocations; this is **not** OMP's lock. OMP locks each
individual setting write, not the whole multi-key operation. In particular, do
not concurrently change `task.agentCompactionThresholdOverrides` elsewhere.
Disjoint model-route keys are not written by this script.

## Rollback

Quiesce **all** global-config writers, including `model-route`, interactive
`/settings`, and other apply processes, before rollback:

```bash
PI_CODING_AGENT_DIR="$HOME/.omp/agent" \
  ./scripts/apply-omp-settings --rollback "$HOME/.omp/agent/config.yml.bak-<UTC>"
```

Use the exact backup path printed by apply. Rollback takes a recovery backup
of the current file, then atomically restores the supplied backup's exact
bytes. It restores the **whole file**, not only managed keys, so it also undoes
any routing/settings changes made since that backup. This full-file restore is
a maintenance-window operation, not an OMP per-key write. The script's own lock
does not exclude OMP's other writers. Missing, foreign, symlinked, or malformed
backups are refused. Do not paste backups or unfiltered configuration on GitHub.

## Adoption evidence

After merge, the dotfiles lane runs apply once and posts UTC, merged revision,
OMP version, backup path and filtered before/after on parent #1209. A code-only
PR uses `Refs #145`; the child remains open until these live gates pass:

1. Fresh lane effective settings: threshold 120,000, idle enabled, idle
   threshold 60,000, timeout 300, spill 16 KB.
2. Fresh seat launched through its unchanged overlay: threshold 400,000 and
   idle disabled. Check effective settings, not only raw global YAML.
3. `omp usage accounts` reports the owner's Anthropic identities. Report counts
   only; never publish account identifiers or credential material. If no usable
   provider account pool exists, prepare the owner step under parent #1209.

[repo-management#1210](https://github.com/rh7/repo-management/issues/1210) owns
cross-role docs and post-apply measured proof, including a real lane compaction
entry with reason `idle` after five idle minutes above 60,000 tokens. Coordinate
one writer: that lane must not also apply the global block. Neither successful
settings resolution nor dry-run proves a real idle-compaction event or measured
token savings. The parent's three-/seven-day re-measure remains separate.

Pre-merge account check on 2026-11-18, OMP 18.22.2: `omp usage accounts --json`
returned 5 visible identities, 2 Anthropic; the Anthropic-only usage query
returned 2 reports, 0 unreported accounts and 0 disabled credentials. No account
identifiers were retained here. An empty `task.agentAccountPools` is not an
absent provider pool: it sets optional per-agent restrictions, not the provider's
stored account inventory. No auth/account-pool change is part of this rollout.

## Verification

```bash
bash scripts/tests/apply-omp-settings.test.sh
```

The deterministic CLI fixture exercises the real entrypoint with temporary
profiles, including a read that writes a DB. CI discovers this test through
`scripts/tests/*.test.sh`; no installed OMP or provider credentials are required.
Real-OMP smoke checks use disposable profiles, never the live global file.
