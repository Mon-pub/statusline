# claude-statusline

A rich multi-line statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) with ANSI colors, rate-limit bars with burn-rate projection, context-fill breakdown, session cost tracking, and automatic context backup.

```
Opus 4.8 (1M context) (xhigh) | 219k/1m (22% used) | 748k 74% free
ctx: ●●●○○○○○○○○○○○○○ cache 87% | fill: tool out 33% · attached 24% · tool cmd 23% · chat In+Out 20%
5h: ●●●●●●○○○○ 60% ->cap 40m | 7d: ●●●●●●●○○○ 74%
resets 7:52pm (4h0m) | resets Tue, 5:52pm (3d2h) | $19.34 | $7.03/h | 2h45m | +1739/-223
-> .claude/backups/3-backup-2026-06-02-1459.md
```

## Features

### Display (bash)
- **ANSI-colored multi-line output** — 4 lines (5 when a backup exists), colored with RGB escape sequences.
- **Model name + effort badge** — effort level (`low`/`med`/`high`/`xhigh`/`max`, or any new level shown raw) read from the live status JSON (`.effort.level`), so mid-session `/effort` changes update immediately. Falls back to `settings.json` on older Claude Code.
- **Mode badges** — a `fast` badge when fast mode is on and a `no-think` badge when thinking is disabled. Both appear only in their non-default state, so the default layout stays clean.
- **Context bar** — 16-char `●○` bar with color thresholds (green < 50%, orange 50-69%, yellow 70-89%, red 90%+). The `% used` figure prefers Claude Code's own `used_percentage` so it matches the built-in UI exactly.
- **Context fill breakdown** — a `fill: tool out 33% · attached 29% · chat In+Out 21% · tool cmd 16%` line showing *what* is consuming the live window (tool output vs. attachments vs. chat messages vs. tool calls), so you can see what to trim. Only content after the latest `/compact` is counted. Tokens are approximated locally (chars/4, zero deps); the parse runs in the background (node) and the statusline only reads a small cache, so long sessions never re-parse on every render. Hidden until data exists.
- **Cache hit-rate** — `cache 78%` on the context line: the share of input tokens served from the prompt cache (`cache_read / total input`), a high-signal proxy for how cost-efficient a long session is. Hidden until there's input (e.g. right after `/compact`).
- **Free tokens until compact** — subtracts the 33k autocompact buffer to show real usable space.
- **Rate-limit bars** — 5-hour and 7-day (weekly) windows with colored progress bars, driven by Claude Code's own `rate_limits.{five_hour,seven_day}.used_percentage`. Percentages are clamped to 0–100 so a transient bogus value Claude Code can emit before a window has data is ignored rather than rendered.
- **Burn-rate projection** — when your current pace is on track to hit a window's limit *before* it resets, the bar gains a red `->cap 1h12m` marker (projected time to 100%). It stays clean when you're not on track. Computed purely from that window's `used_percentage` + `resets_at`.
- **Friendly reset times** — `5:00pm (3h16m)` for the 5-hour window; the weekly reset shows day + time + countdown, e.g. `Tue, 5:35pm (3d2h)` (a calendar date replaces the weekday when it is more than 7 days out). The countdown makes the true distance to the weekly reset visible — it lands at an account-assigned fixed time, not always a fixed weekday.
- **Session cost** — headline uses Claude Code's authoritative `cost.total_cost_usd` when present (the transcript-JSONL estimate supplies the dim `in/out` split). Falls back to the per-model JSONL estimate on older Claude Code. Survives `/resume`.
- **Cost burn rate** — `$/hr` spend velocity (`total_cost_usd` ÷ session duration), shown dim next to the cost (e.g. `$7.03/h`). Hidden until both the cost and a positive duration are known.
- **Session duration** — wall-clock session time from `cost.total_duration_ms`, shown dim next to the cost (e.g. `2h45m`).
- **Lines changed** — `+added/-removed` diff stat for the session, from `cost.total_lines_*`.

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
  context-lib.sh          — context-fill breakdown: reads node cache, spawns parse
node/
  backup-core.mjs         — JSONL parsing, backup creation, state management
  context-breakdown.mjs   — buckets live context by category (msgs/tools/results/attach)
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

**Node.js backup layer** handles JSONL transcript parsing and backup creation. Called in the background by the bash statusline (via `backup-bridge.sh`) and by the PreCompact hook (via `conv-backup.mjs`). The optional **backup compaction** step (`backup-compactor.mjs`) summarizes backups older than 14 days by invoking the `claude` CLI.

## Configuration

Environment variables:
- `CLAUDE_CONFIG_DIR` — overrides `~/.claude` for script + settings location
- `XDG_CACHE_HOME` — overrides `~/.cache` for credit cache
- `STATUSLINE_PROJECT_DIR` — project root for backup files (auto-set by hooks)
- `STATUSLINE_NODE_DIR` — overrides `~/.claude/statusline-node` for node scripts
- `STATUSLINE_LOG_DIR` — overrides default log directory for backup system

## Privacy

The **statusline display** and **backup capture** read only local files (the stdin JSON Claude Code provides and your existing transcript JSONL) and make **no network calls and send no telemetry**.

One optional component does leave the machine: the **backup compactor** (`backup-compactor.mjs`) sends summaries of your own backups that are older than 14 days to the Anthropic API via the `claude` CLI, so they can be condensed. If you require strict no-egress, disable it by removing `node/backup-compactor.mjs` (or the `maybeSpawnCompactor()` call in `backup-core.mjs`). Backup files are written to your project's `.claude/backups/` with `0600` permissions and contain verbatim conversation content — treat them as sensitive and keep them gitignored.

See [SECURITY.md](SECURITY.md) for the full trust model and how to report issues.

## License

MIT — see [LICENSE](LICENSE).
