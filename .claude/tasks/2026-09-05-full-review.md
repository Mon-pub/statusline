# Full review & modernisation — 2026-09-05

Context: last commit 2026-07-01 (CC 2.1.160 era). Host now runs Claude Code 2.1.261,
node 22, jq 1.7, bash 5.2. Live stdin sample captured to `.sample-stdin.json`
(gitignored). Docs re-read: statusline, hooks, pricing, CHANGELOG 2.1.238–2.1.261.

## Findings (bugs)

- [x] B1 `trigger-backup.mjs` never calls `shouldBackup()`; every 5k-token bash delta
      writes a full backup (log: backup every ~40s). `_pendingTokens` never set. After a
      compaction the token thresholds would also stall (prevTokens > total).
- [x] B2 Pricing drift: Fable/Mythos **5.1** cache-read is $0.25 (0.025x), not $1.00;
      Sonnet 5 $2/$10 is now permanent; Opus 4.0/4.1 were $15/$75; Haiku 3.5 $0.80/$4;
      fast mode (`usage.speed=="fast"`) bills Opus at $10/$50. Family-only matching
      cannot express any of this → make rates version-aware.
- [x] B3 `CLAUDE_CONFIG_DIR` ignored by context-lib/backup-bridge node-dir default,
      credit-summary projects dir, backup-core `findTranscript`.
- [x] B4 `~/.cache/claude-statusline` grows unbounded (343 files, 250 older than 30d,
      plus leftover test junk). No sweep anywhere.
- [x] B5 Backup project dir = `CLAUDE_PROJECT_DIR` or `$(pwd)`; statusline has neither
      guaranteed. stdin carries `workspace.project_dir` — use it.
- [x] B6 `findTranscript` scans every project dir although bash already knows
      `transcript_path` (unused arg in `maybe_trigger_backup`).
- [x] B7 Compactor never archives old-format names (`2-backup-24th-May-2026-6-53pm.md`).
- [x] B8 README: Sonnet intro-pricing note stale; "first backup at 50k" false today.
- [x] B9 shellcheck: SC2174 (`mkdir -p -m`), SC2034 unused arg.

## Enhancements

- [x] E1 Single `jq` extraction pass (20 spawns → 1) with all coercion/sanitising in jq.
- [x] E2 `prompt_cache`: warm/cold + TTL countdown on ctx line (2.1.251+).
- [x] E3 `rate_limits.spend_limit` bar + reset (2.1.251+ gateway users).
- [x] E4 Line 1 tail: git branch, PR number, worktree name, agent name.
- [x] E5 `refreshInterval: 60` in installer so countdowns tick while idle.
- [x] E6 Streaming `context-breakdown.mjs` (127 MB transcript → 495 MB RSS today).
- [x] E7 SessionEnd hook → final backup update for sessions that already have one;
      PreCompact re-arms token thresholds.
- [x] E8 Per-version cost buckets (`fable-5.1`, `opus-4.8+fast`) in credit tools.
- [x] E9 `tests/run.sh` fixture suite + shellcheck + `node --check`.
- [x] E10 Compactor summariser model → `claude-sonnet-5` (cheaper than 4.6, current).

## Amendments log

- 2026-09-05 B1: also re-arm thresholds on PreCompact (prevTokens=0) and detect a
  live count 10k+ below the baseline as a compaction — otherwise post-compaction
  growth stalls until prev+10k.
- 2026-09-05 E2: kept the per-request `cache NN%` share AND added the TTL
  countdown; the separator `·` only appears when both are present.
- 2026-09-05 E4: branch comes from `git symbolic-ref` (short SHA when detached);
  agent name renders as an `agent:<name>` prefix, not in the tail.
- 2026-09-05 E10: model configurable via STATUSLINE_SUMMARY_MODEL; summariser
  now runs `--bare --no-session-persistence` (retry without `--bare` on old CLIs).
- 2026-09-05 E9: 87 checks; fixture pinned (the live probe kept overwriting the
  copied sample, which caused 5 false failures on first run).
- 2026-09-05 project_cap: durations ≥24h render as `4d20h` instead of `116h26m`.
- 2026-09-05 Live estimate vs native cost on this Fable 5.1 session: within ~4%
  (the remainder is untranscribed title-generation calls on the haiku slot).
- Not done / out of scope: submodule bump for reference/claude-context-visualizer
  (reference material only; report upstream state instead).
- 2026-09-06 Folded `credit-project.sh` and `credit-summary.sh` into
  `credit-report.sh`. Both were missing every `<session>/subagents/**`
  transcript, and `credit-summary.sh` date-filtered on file mtime and then
  billed whole session lifetimes into the window (the bug fixed for the report
  in f0abf22). Measured on ~/google-earth for `--since 2026-09-01`:
  summary $849.72 vs report $723.78 vs $1,642.20 all-time. Fixing them would
  have left three pipelines that must agree forever, so both names are now thin
  wrappers that exec the report (old argv translated, flags forwarded, note on
  stderr). 145 checks.
