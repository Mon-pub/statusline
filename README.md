# claude-statusline

A rich statusline for [Claude Code](https://docs.claude.com/en/docs/claude-code) that shows the current model, thinking level, context window usage, rate limits, and **estimated API cost of the current session** — plus a companion script that totals cost across every session in a project.

```
Opus 4.7 (max)  ctx:41%  [██████░░░░░░░░░░]  |  5h:73% rst@18:00  7d:22% rst@04-29 09:00    $1.2473 (in:$0.3091 out:$0.9382)
```

## Why

Claude Code's built-in statusline shows model + context. It does **not** show how much the current session has cost you. For long sessions, plan work, or cost-conscious usage, that number matters. This statusline reads the session transcript JSONL directly (same file Claude Code itself writes), deduplicates by message id, applies the published per-family pricing, and caches the result so it doesn't re-scan on every redraw.

## Features

- **Live cost estimate** per session (input / output / total), from the transcript — survives `/resume` because it reads the JSONL not the in-memory counter.
- **Per-family pricing** — Opus / Sonnet / Haiku each use their own rate card. Cache-read and cache-create tokens are billed correctly (10% and 125% of base input rate, disjoint buckets).
- **Unknown-family fallback** — future models (e.g. a hypothetical `claude-mythos-5`) are labelled with their real family name and priced at Opus rates until you update the script.
- **Context window bar** (16 chars, unicode blocks).
- **Rate-limit display** for Claude.ai subscribers — 5-hour window, 7-day window, and Sonnet-specific quota. Resets shown as `HH:MM` (today) or `MM-DD HH:MM` (future day). Hidden entirely on API-only setups.
- **Thinking-level badge** (`low`/`med`/`high`/`xhigh`/`max`) read from `settings.json`.
- **Cross-platform** `date` / `stat` calls (Linux `-d`/`-c`, macOS `-r`/`-f`).
- **Persistent cache** at `$XDG_CACHE_HOME/claude-statusline/` — re-uses cost result until the transcript mtime changes.
- **Companion tool** `credit-project.sh` that walks every `.jsonl` in a Claude Code project directory and totals cost by session, by model family, and grand total.

## Requirements

- `bash` 4+
- `jq`
- `awk`, `grep`, `date`, `stat` (standard GNU or BSD variants)

## Install

This is a three-file bash tool. Read the scripts before installing — they are short and do exactly one thing.

```bash
git clone https://github.com/<you>/claude-statusline.git
cd claude-statusline
./install.sh          # copies bin/*.sh into $CLAUDE_CONFIG_DIR (default ~/.claude)
                      # AND merges the statusLine entry into settings.json
```

Flags:
- `--no-write` — copy scripts only, print the settings.json snippet instead of editing
- `--force`    — overwrite an existing different `statusLine` value without prompting

If `settings.json` does not exist it is created. If it already contains a matching `statusLine` the second run is a no-op. Existing values for other keys are preserved (`jq` merge, atomic write, `.bak` backup).

Manual install:

```bash
cp bin/statusline-command.sh bin/credit-lib.sh bin/credit-project.sh ~/.claude/
chmod +x ~/.claude/statusline-command.sh ~/.claude/credit-project.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

Reload Claude Code (or start a new session) and the statusline will appear at the bottom.

## Usage

### Statusline

Runs automatically once configured. No flags, no options — Claude Code pipes session JSON into it on stdin and renders whatever it prints.

### Project-wide cost total

```bash
bash ~/.claude/credit-project.sh ~/.claude/projects/-home-me-my-project
```

Output:

```
01a2…       $0.4210  (in:$0.0832  out:$0.3378)
02b3…       $1.2473  (in:$0.3091  out:$0.9382)
03c4…       $0.0184  (in:$0.0040  out:$0.0144)
TOTAL       $1.6867  (in:$0.3963  out:$1.2904)

MODELS:
  opus-*         $  1.5112  (in:$0.3471  out:$1.1641  89.6%)
  sonnet-*       $  0.1755  (in:$0.0492  out:$0.1263  10.4%)
```

Point it at any directory containing `.jsonl` transcripts.

## Pricing (as of 2026-04-22)

Per 1M tokens. Sourced from [anthropic.com/pricing](https://www.anthropic.com/pricing) and [openrouter.ai](https://openrouter.ai/anthropic).

| Family | Input | Cache read | Cache create | Output |
|--------|-------|------------|--------------|--------|
| Opus   | $5.00 | $0.50      | $6.25        | $25.00 |
| Sonnet | $3.00 | $0.30      | $3.75        | $15.00 |
| Haiku  | $1.00 | $0.10      | $1.25        | $5.00  |

If Anthropic changes a rate, edit `set_rates()` in `bin/credit-lib.sh` — it's the single source of truth for both scripts.

## How cost is computed

For each line in the transcript JSONL:

1. Keep only `"type":"assistant"` entries.
2. Deduplicate by `message.id` (a single API call produces multiple JSONL lines, one per streaming content block — all share the same `id` and `usage`).
3. Extract the model family from `message.model` by stripping `claude-` and taking the first non-numeric hyphen-delimited token. Handles both `claude-3-5-sonnet-*` and `claude-opus-4-7-*` forms.
4. Apply the rate card for that family. The four token buckets (`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `output_tokens`) are disjoint in Anthropic's API, so they are summed directly.

The statusline caches the result at `$XDG_CACHE_HOME/claude-statusline/credit-<session-id>.cache` keyed on the transcript's mtime. It only re-scans when the file actually changes.

## Privacy

The scripts read only files that already exist on your disk:

- The session JSON that Claude Code pipes in on stdin.
- The transcript path that session JSON points at (inside `~/.claude/projects/…`).
- `settings.json` to read the thinking level.

They write only to `$XDG_CACHE_HOME/claude-statusline/`. No network calls. No telemetry.

## Configuration

All paths come from environment:

- `CLAUDE_CONFIG_DIR` — overrides `~/.claude` for locating `settings.json`.
- `XDG_CACHE_HOME` — overrides `~/.cache` for the credit cache.
- `HOME` — used as the final fallback for both.

## Why plain bash and not a plugin?

1. The scripts are ~250 lines total. You can read them in 5 minutes before running anything.
2. Claude Code plugins still execute bash — wrapping these in a plugin manifest wouldn't change what runs, only who knows what runs.
3. No install framework = no implicit trust, no auto-update pipeline, no background behavior.
4. Install is three commands (`git clone`, `cp`, edit `settings.json`). That's simpler than any plugin lifecycle.

If you want a plugin version later, the scripts are structured to drop into one unchanged.

## License

MIT — see [LICENSE](LICENSE).
