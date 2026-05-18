# claude-statusline

A rich multi-line statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) with ANSI colors, rate limit bars, session cost tracking, peak/off-peak indicator, and automatic context backup.

```
Claude Opus 4.7 (max) | 50k/200k (25% used) | 117k 42% free
5h: ●●●●●○○○○○ 43% | 7d: ●●○○○○○○○○ 22% | ctx: ●●●●○○○○○○○○○○○○ | Off-peak (4h12m)
resets 5:00pm (3h16m) | resets Thu, 7:00pm | $1.2473 (in:$0.31 out:$0.94)
-> .claude/backups/3-backup-18th-May-2026-2-30pm.md
```

## Features

### Display (bash)
- **ANSI-colored multi-line output** — 3 lines (4 when a backup exists), colored with RGB escape sequences.
- **Model name + thinking level** badge (`low`/`med`/`high`/`xhigh`/`max`) from `settings.json`.
- **Context bar** — 16-char `●○` bar with color thresholds (green < 50%, orange 50-69%, yellow 70-89%, red 90%+).
- **Free tokens until compact** — subtracts the 33k autocompact buffer to show real usable space.
- **Rate limit bars** — 5-hour and 7-day windows with colored progress bars. Sonnet-specific quota when available.
- **Friendly reset times** — `5:00pm (3h16m)` for current window, `Thu, 7:00pm` for weekly, `feb 1` for monthly.
- **Peak/off-peak indicator** — weekdays 8AM-2PM ET are peak hours. Shows countdown to next transition.
- **Live session cost** — reads the transcript JSONL directly (survives `/resume`). Per-model pricing for Opus/Sonnet/Haiku with correct cache-read and cache-create billing.

### Backup system (Node.js)
- **Auto backup on thresholds** — first backup at 50k tokens, then every 10k. Percentage thresholds at 30%, 15%, 5% free as safety net.
- **PreCompact hook** — captures context before Claude Code compacts, so you never lose work.
- **Backup compaction** — old backups (>14 days) are summarized by Claude CLI into archived summaries, preserving session IDs for `--resume`.
- **Backup path display** — line 4 shows the current backup file path when one exists.

### Companion tools
- **`credit-project.sh`** — totals cost across every session in a project directory, with per-model breakdown.

## Requirements

- `bash` 4+, `jq`, `awk`, `grep`, `date`, `stat`
- `node` 18+ (for backup system only)

## Install

```bash
git clone https://github.com/<you>/claude-statusline.git
cd claude-statusline
./install.sh          # copies scripts, wires statusLine + PreCompact hook
```

Flags:
- `--no-write` — copy scripts only, print settings.json snippets
- `--force` — overwrite existing statusLine without prompting
- `--no-hooks` — skip PreCompact hook installation

What it does:
1. Copies `bin/*.sh` to `~/.claude/`
2. Copies `node/*.mjs` to `~/.claude/statusline-node/`
3. Merges `statusLine` entry into `~/.claude/settings.json`
4. Adds `PreCompact` hook for automatic context backup

Manual install:

```bash
cp bin/*.sh ~/.claude/
chmod +x ~/.claude/statusline-command.sh ~/.claude/credit-project.sh
mkdir -p ~/.claude/statusline-node
cp node/*.mjs ~/.claude/statusline-node/
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  },
  "hooks": {
    "PreCompact": [{
      "hooks": [{
        "type": "command",
        "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs",
        "async": true
      }]
    }]
  }
}
```

## File layout

```
bin/
  statusline-command.sh   — main entry point (multi-line colored output)
  display-lib.sh          — ANSI colors, bars, peak/off-peak, reset formatting
  credit-lib.sh           — per-model pricing logic (shared)
  credit-project.sh       — project-wide cost totaling
  credit-summary.sh       — cross-project cost summary with date filtering
  backup-bridge.sh        — integration: reads backup state, triggers node backup
node/
  backup-core.mjs         — JSONL parsing, backup creation, state management
  backup-compactor.mjs    — summarizes old backups via claude -p
  conv-backup.mjs         — PreCompact hook entry point
  trigger-backup.mjs      — CLI wrapper for backup triggering
install.sh                — copies everything + wires settings.json
```

## Project-wide cost total

```bash
bash ~/.claude/credit-project.sh ~/.claude/projects/-home-me-my-project
```

Output:

```
01a2…       $0.4210  (in:$0.0832  out:$0.3378)
02b3…       $1.2473  (in:$0.3091  out:$0.9382)
TOTAL       $1.6867  (in:$0.3963  out:$1.2904)

MODELS:
  opus-*         $  1.5112  (in:$0.3471  out:$1.1641  89.6%)
  sonnet-*       $  0.1755  (in:$0.0492  out:$0.1263  10.4%)
```

## Cross-project cost summary

```bash
bash ~/.claude/credit-summary.sh                  # all sessions, all time
bash ~/.claude/credit-summary.sh 2026-05-01        # sessions since May 1
bash ~/.claude/credit-summary.sh 2026-05-01 ~/.claude/projects/-home-me-proj  # since date, one project
```

Output:

```
f872e7ab-82c… $0.6563  (in:$0.2168  out:$0.4395)
49a1b74e-01e… $73.7316  (in:$67.2742  out:$6.4575)

TOTAL (2 sessions, since 2026-05-01)  $74.3879  (in:$67.4910  out:$6.8970)

MODELS:
  opus-*         $ 74.3879  (in:$67.4910  out:$6.8970  100.0%)
```

Date filtering uses file modification time — fast, no JSONL parsing. Scans all projects under `~/.claude/projects/` by default.

## Pricing (as of 2026-04-22)

Per 1M tokens. Sourced from [anthropic.com/pricing](https://www.anthropic.com/pricing).

| Family | Input | Cache read | Cache create | Output |
|--------|-------|------------|--------------|--------|
| Opus   | $5.00 | $0.50      | $6.25        | $25.00 |
| Sonnet | $3.00 | $0.30      | $3.75        | $15.00 |
| Haiku  | $1.00 | $0.10      | $1.25        | $5.00  |

Edit `set_rates()` in `bin/credit-lib.sh` to update pricing.

## Architecture

**Bash display layer** handles all output formatting. Reads stdin JSON from Claude Code, computes everything locally, outputs ANSI-colored lines. Zero network calls, fast.

**Node.js backup layer** handles JSONL transcript parsing and backup creation. Called in the background by the bash statusline (via `backup-bridge.sh`) and by the PreCompact hook (via `conv-backup.mjs`). Only modification from upstream v5.3: `STATUSLINE_PROJECT_DIR` env var for project path (2-line change in `backup-core.mjs` and `backup-compactor.mjs`).

## Upgrading from v5.3

The Node backup files are nearly identical to the v5.3 source at `.claude/hooks/ContextRecoveryHook/`. To upgrade:

1. Diff new v5.3 files against current `node/` directory
2. Apply patches
3. Re-add the `STATUSLINE_PROJECT_DIR` env var (grep for it — it's 2 lines)

## Configuration

Environment variables:
- `CLAUDE_CONFIG_DIR` — overrides `~/.claude` for script + settings location
- `XDG_CACHE_HOME` — overrides `~/.cache` for credit cache
- `STATUSLINE_PROJECT_DIR` — project root for backup files (auto-set by hooks)
- `STATUSLINE_NODE_DIR` — overrides `~/.claude/statusline-node` for node scripts
- `STATUSLINE_LOG_DIR` — overrides default log directory for backup system

## Privacy

All scripts read only local files. The backup system parses your existing transcript JSONL (already on disk). No network calls. No telemetry.

## License

MIT — see [LICENSE](LICENSE).
