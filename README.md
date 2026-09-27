# claude-statusline

A rich multi-line statusline for [Claude Code](https://code.claude.com/docs/en/statusline) with ANSI colors, rate-limit bars with burn-rate projection, prompt-cache TTL countdown, context-fill breakdown, session cost tracking, and automatic context backup.

```
Fable 5.1 (high) | 175k/1m (17% used) | 792k 79% free | git: main #42
ctx: ●●○○○○○○○○○○○○○○ cache 92% · 1h warm 59m | 5h: ●●●●●●○○○○ 64% ->cap 1h27m (Sat 03:02) | 7d: ●○○○○○○○○○ 13%
fill: tool out 69% · tool cmd 17% · attached 13% · chat In+Out 1% | 7d Fable: ●○○○○○○○○○ 1%
resets 4:00am (2h24m) | resets Mon, 8:00am (2d6h) | $5.65 | $33.52/h | 10m | +413/-289
-> .claude/backups/1-backup-2026-09-05-0135.md
```

Tracks Claude Code **2.1.261** (2026-09). Tested against the live stdin schema; see `tests/`.

## Features

### Display (bash)

- **ANSI-colored multi-line output** — up to 5 lines (model; context bar + cache + rate-limit bars; context-fill breakdown; resets/cost; and an optional backup path), colored with RGB escape sequences. The fill and backup lines each appear only when their data exists.
- **Model name + effort badge** — effort level (`low`/`med`/`high`/`xhigh`/`max`, or any new level shown raw) read from the live status JSON (`.effort.level`), so mid-session `/effort` changes update immediately. On modern Claude Code the badge is hidden when the model does not support effort; only older Claude Code (before 2.1.160, which never emitted the key) falls back to `settings.json`.
- **Mode badges** — a `fast` badge when fast mode is on and a `no-think` badge when thinking is disabled. Both appear only in their non-default state, so the default layout stays clean. When running as a named subagent (`subagentStatusLine`), an `agent:<name>` prefix shows.
- **Git tail** — `git: main #42 wt:feature` on line 1: current branch (short SHA when detached), the open PR/MR number from `pr.number`, and the worktree name from `worktree.name` / `workspace.git_worktree`. One cheap `git symbolic-ref` call, never a working-tree scan; hidden outside a repo.
- **Context bar** — 16-char `●○` bar with color thresholds (green < 50%, orange 50-69%, yellow 70-89%, red 90%+). The `% used` figure prefers Claude Code's own `used_percentage` so it matches the built-in UI exactly (input-only, per the docs).
- **Context fill breakdown** — a `fill: tool out 33% · attached 29% · chat In+Out 21% · tool cmd 16%` line showing _what_ is consuming the live window (tool output vs. attachments vs. chat messages vs. tool calls), so you can see what to trim. Only content after the latest `/compact` is counted. Tokens are approximated locally (chars/4, zero deps); the parse **streams** the transcript in the background (node, constant memory even on 100 MB+ transcripts) and the statusline only reads a small cache. Hidden until data exists.
- **Cache share** — `cache 92%` on the context line: the share of the current request's input served from the prompt cache (`cache_read / total input`). Hidden until there's input (e.g. right after `/compact`).
- **Prompt-cache TTL countdown** — `1h warm 59m` (Claude Code 2.1.251+): the cache TTL and how long until the cached prefix goes cold and the next turn re-pays the full write price. Green above 10 minutes, yellow at 10, red at 3; `cold` in red once it has lapsed. With `refreshInterval` set (the installer does this) the countdown ticks while you are idle — a visible nudge to send the next turn before the cache expires.
- **Free tokens until compact** — subtracts the 33k autocompact buffer (1M windows compact at ~967k) to show real usable space.
- **Rate-limit bars** — 5-hour and 7-day windows, plus the **spend-limit** bar for Claude apps gateway users (2.1.251+), driven by Claude Code's own `rate_limits.*.used_percentage`. Those stdin figures only move when the model answers in the current session, so the same 5-minute poll that feeds the per-model bar (below) is merged in: it also sees quota burnt in other sessions or on other machines, and a window that reset while you were idle. Merge rule per window: same reset time, the higher figure wins (usage inside a window only rises); different reset times, the newer window wins. A stale poll can therefore never lower a number. Without the poll (no `curl`, no credentials, or `STATUSLINE_USAGE_API=0`) the bars behave exactly as before. 5h/7d percentages are clamped to 0–100 so a transient bogus value is ignored rather than rendered; the spend figure is allowed past 100 (the bar clamps, the number turns red).
- **Per-model weekly bar** — `7d Fable: ●●○○○○○○○○ 22%` on the fill line: the per-model weekly cap that `/usage` lists as "Current week (Fable)". Claude Code does not put this on the statusline stdin, so `usage-lib.sh` fetches it from the same account usage endpoint `/usage` calls, in a detached background `curl` at most every 5 minutes, with the OAuth token Claude Code already keeps in `.credentials.json`. A render never waits on the network; it reads a small cache. Every model-scoped bucket the server returns is shown, so a future Opus or Sonnet bucket needs no code change. Data older than 15 minutes is tagged `old 3h00m` rather than hidden; older than a day it is dropped. Its reset joins line 4 only when it differs from the all-models 7d reset. Set `STATUSLINE_USAGE_API=0` to turn the feature off entirely (no token read, no network). Needs `curl`; absent on macOS Keychain-only installs where there is no credentials file.
- **Burn-rate projection** — when your current pace is on track to hit a window's limit _before_ it resets, the bar gains a red `->cap 1h12m (Tue 14:30)` marker: the projected time to 100% (days when over 24h) and the wall-clock moment it lands. It stays clean when you're not on track. Computed purely from that window's `used_percentage` + `resets_at`.
- **Friendly reset times** — `5:00pm (3h16m)` for the 5-hour window; the weekly and spend resets show day + time + countdown, e.g. `Tue, 5:35pm (3d2h)` (a calendar date replaces the weekday when more than 7 days out).
- **Session cost** — headline uses Claude Code's authoritative `cost.total_cost_usd` when present. Falls back to the per-model transcript estimate on older Claude Code (with a dim `in/out` split). Survives `/resume`.
- **Cost burn rate** — `$/hr` spend velocity (`total_cost_usd` ÷ session duration), shown dim next to the cost. Hidden until both the cost and a positive duration are known.
- **Session duration** — wall-clock session time from `cost.total_duration_ms`, shown dim (e.g. `2h45m`).
- **Lines changed** — `+added/-removed` diff stat for the session, from `cost.total_lines_*`.
- **One jq pass** — every stdin field is extracted, type-coerced and control-byte-stripped in a single `jq` invocation, so a render costs ~45 ms and Claude Code's 300 ms debounce never cancels it mid-flight.

### Backup system (Node.js)

- **Auto backup on thresholds** — first backup at 50k tokens, then every 10k. Percentage thresholds at 30%, 15%, 5% free as a safety net. The bash side only spawns node when the count moved 5k+; node applies the policy and writes only when a threshold is crossed. After a compaction the thresholds re-arm automatically.
- **PreCompact hook** — captures context before Claude Code compacts, so you never lose work.
- **SessionEnd hook** — refreshes the backup one last time when a session that already has one ends (sessions that never reached a threshold do not get a file).
- **Backup compaction** — old backups (>14 days) are summarized by the Claude CLI (`claude -p --bare --no-session-persistence`, Sonnet 5 by default; override with `STATUSLINE_SUMMARY_MODEL`) into archived summaries, preserving session IDs for `--resume`.
- **Backup path display** — the last line shows the current backup file path when one exists.
- **Cache housekeeping** — per-session cache files under `~/.cache/claude-statusline` older than 30 days are purged once a day, in the background.

### Companion tools

- **`credit-report.sh`** — one colored report for the whole account: total, over time, by model, by project, by session, **with every subagent and workflow-agent transcript billed to the session that spawned them** (`<session>/subagents/**`; on a heavy multi-agent setup those are most of the spend and the older tools never counted them). Every message is counted **on the day it was produced**, so `--since`/`--until` report money spent in the window rather than whole sessions touched in it. Sessions that used several models get a `↳` line with the per-model split. Cached per session, so it re-runs in under a second. `--since`, `--top`, `--all`, `--projects`, `--json`, or a project path.
- **`credit-project.sh`**, **`credit-summary.sh`** — deprecated. Both are now one-line wrappers that run `credit-report.sh`, so old commands keep working and can no longer report a different number. See [Deprecated cost tools](#deprecated-cost-tools).

## Requirements

- `bash` 4+, `jq`, `awk`, `grep`, `date`, `stat`; `git` optional (for the branch tail); `curl` optional (for the per-model weekly bar)
- `node` 18+ (backup system and context-fill breakdown only; the display degrades gracefully without it)

## Install

```bash
git clone https://github.com/Mon-pub/statusline.git
cd statusline
./install.sh          # copies scripts, wires statusLine + PreCompact/SessionEnd hooks
bash tests/run.sh     # optional: run the self-checks
```

Flags:

- `--no-write` — copy scripts only, print settings.json snippets
- `--force` — overwrite existing statusLine without prompting
- `--no-hooks` — skip hook installation

What it does:

1. Copies `bin/*.sh` to `~/.claude/`
2. Copies `node/*.mjs` to `~/.claude/statusline-node/`
3. Merges a `statusLine` entry (with `refreshInterval: 60`) into `~/.claude/settings.json`
4. Adds `PreCompact` (async) and `SessionEnd` (sync, 20s timeout) hooks for automatic context backup — idempotently, keeping any other hooks you have

Manual install:

```bash
cp bin/*.sh ~/.claude/
chmod +x ~/.claude/statusline-command.sh ~/.claude/credit-project.sh ~/.claude/credit-summary.sh
mkdir -p ~/.claude/statusline-node
cp node/*.mjs ~/.claude/statusline-node/
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh",
    "refreshInterval": 60
  },
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs",
            "async": true
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
```

## File layout

```
bin/
  statusline-command.sh   — main entry point (single-jq extraction, multi-line colored output)
  display-lib.sh          — ANSI colors, bars, reset/countdown formatting, cache sweep
  credit-lib.sh           — version-aware per-model pricing (shared; prices main + subagent files as one set)
  credit-report.sh        — account report: total / by model / by project / by session (+subagents)
  credit-project.sh       — deprecated wrapper → credit-report.sh --all <dir>
  credit-summary.sh       — deprecated wrapper → credit-report.sh --all [--since d]
  backup-bridge.sh        — integration: reads backup state, triggers node backup
  context-lib.sh          — context-fill breakdown: reads node cache, spawns parse
node/
  backup-core.mjs         — JSONL parsing, backup creation, threshold policy, state
  context-breakdown.mjs   — streams the transcript, buckets live context by category
  backup-compactor.mjs    — summarizes old backups via claude -p
  conv-backup.mjs         — PreCompact / SessionEnd hook entry point
  trigger-backup.mjs      — CLI wrapper: applies the threshold policy, runs a backup
tests/
  run.sh                  — self-contained checks (shellcheck, pricing, renderer, backups, hooks)
  fixtures/               — real Claude Code 2.1.261 stdin sample (sanitized)
install.sh                — copies everything + wires settings.json
```

## Account spend report

```bash
bash ~/.claude/credit-report.sh                     # everything, all time
bash ~/.claude/credit-report.sh --since 2026-08-01  # money spent from that day onward
bash ~/.claude/credit-report.sh --since 2026-08-01 --until 2026-08-31   # just August
bash ~/.claude/credit-report.sh --all ~/my-project  # every session of one project
bash ~/.claude/credit-report.sh --json | jq .total  # machine-readable
```

```
 Claude Code spend report  2026-09-06 · all time · offline estimate
 ──────────────────────────────────────────────────────────────────────────────────────
 TOTAL  $19,753.95     in $17,943.44 · out $1,810.51   15 projects · 45 sessions · 3082 agents
 activity 2026-05-22 → 2026-09-06

 BY MONTH
   2026-06             $4,600.38  ███████░░░░░░░░░░░░░░░░░░░░░░░  23.3%  20 active days
   2026-07             $8,745.90  █████████████░░░░░░░░░░░░░░░░░  44.3%  28 active days
   2026-08             $4,914.71  ███████░░░░░░░░░░░░░░░░░░░░░░░  24.9%  22 active days
   2026-09             $1,313.56  ██░░░░░░░░░░░░░░░░░░░░░░░░░░░░   6.6%  6 active days

 BY MODEL
   opus-4.8            $8,364.48  ████████████████░░░░░░░░░░░░░░  51.9%  in $7,606.38 · out $758.11
   fable-5.0           $3,275.99  ██████░░░░░░░░░░░░░░░░░░░░░░░░  20.3%  in $2,800.09 · out $475.90
   …

 BY PROJECT (sessions folded to top 5 by spend; --all shows every one)

 ~/threema                                 $8,317.13  ██████████░░░░░░░░░░  51.6%    7 sess · 2026-09-05
     380caecb  threema-desktop                     $5,009.45  opus-4.8       2026-07-23 284 agents
               ↳ opus-4.8 $4,410.12 (88%) · opus-5.0 $512.30 (10%) · sonnet-5.0 $87.03 (2%)
     2f5588b3  threema-server                      $3,184.03  opus-5.0       2026-09-05  83 agents
     + 2 more session(s) · $5.19
```

Buckets are months once the span passes a month, single days below that, and they always sum to the total. Figures are API-equivalent (published per-token rates); on a subscription they are the value consumed, not a bill. The first run prices every transcript (a few seconds per GB); results are cached per session under `~/.cache/claude-statusline/report/` keyed on file sizes and mtimes, so later runs are instant until a transcript changes (`--refresh` forces a rebuild).

Why not filter on file modification time: a session can run for months, and Claude Code touches its transcript every time you resume it. One session here holds work from 23 May to 26 August in a file last written on 5 September — filtering on the file date billed all of it to September. `--since`/`--until` therefore slice on each message's own timestamp.

## Deprecated cost tools

`credit-project.sh` and `credit-summary.sh` came first and each carried its own
copy of the accounting. Both were wrong in ways that were hard to notice:

- Neither looked inside `<session>/subagents/**`, so subagent and workflow-agent
  spend — most of the bill on a multi-agent setup — was simply missing.
- `credit-summary.sh` picked sessions by transcript modification time and then
  billed each one's whole lifetime into the window. Claude Code rewrites a
  transcript every time you resume it, so months-old work landed in today.

Those two errors pull in opposite directions, so the totals looked plausible
while being wrong. On one real project asked for September, `credit-summary.sh`
said $849.72, `credit-report.sh` said $723.78, and the project's entire history
was $1,642.20.

Rather than keep three pipelines that have to agree forever, both names are now
wrappers that exec `credit-report.sh`. Every old invocation still works and
prints a note naming the modern equivalent:

```bash
bash ~/.claude/credit-project.sh ~/my-project      # → credit-report.sh --all ~/my-project
bash ~/.claude/credit-summary.sh                   # → credit-report.sh --all
bash ~/.claude/credit-summary.sh 2026-05-01        # → credit-report.sh --all --since 2026-05-01
bash ~/.claude/credit-summary.sh 2026-05-01 ~/proj # → …--since 2026-05-01 ~/proj
```

Flags are forwarded, so `credit-summary.sh 2026-05-01 --json` works. Prefer
`credit-report.sh` directly in anything new.

## Pricing (as of 2026-09-28)

Per 1M tokens. Verified from [platform.claude.com pricing](https://platform.claude.com/docs/en/about-claude/pricing). "Cache write" is the 5-minute tier (1.25× input); the 1-hour tier is 2× input. Cache reads are 0.1× input — except Fable/Mythos **5.1**, where a read is 0.025× ($0.25), and **Opus 5.5**, where it is 0.05× ($0.20).

| Model                 | Input  | Cache read | Cache write | Output |
| --------------------- | ------ | ---------- | ----------- | ------ |
| Fable / Mythos 5.1    | $10.00 | $0.25      | $12.50      | $50.00 |
| Fable / Mythos 5      | $10.00 | $1.00      | $12.50      | $50.00 |
| Opus 5.5              | $4.00  | $0.20      | $5.00       | $20.00 |
| Opus 5.5 fast         | $8.00  | $0.40      | $10.00      | $40.00 |
| Opus 5, 4.5–4.8       | $5.00  | $0.50      | $6.25       | $25.00 |
| Opus 5 / 4.8 fast     | $10.00 | $1.00      | $12.50      | $50.00 |
| Opus 4.0 / 4.1 / 3    | $15.00 | $1.50      | $18.75      | $75.00 |
| Sonnet 5              | $2.00  | $0.20      | $2.50       | $10.00 |
| Sonnet 4.x / 3.x      | $3.00  | $0.30      | $3.75       | $15.00 |
| Haiku 4.5             | $1.00  | $0.10      | $1.25       | $5.00  |
| Haiku 3.x             | $0.80  | $0.08      | $1.00       | $4.00  |

Rates are picked from the model id's family **and version** (`claude-fable-5-1` → fable 5.1, `claude-3-5-sonnet-…` → sonnet 3.5); a response with `usage.speed == "fast"` is billed at fast-mode rates. Unknown families fall back to Opus 5 rates but keep their real name in the breakdown. Sonnet 5's launch price ($2/$10) became the permanent price; the planned 2026-09-01 increase was cancelled. The live headline always uses Claude Code's own `cost.total_cost_usd`; the table is for the offline estimate. Opus 5.5 is the first Opus that is *cheaper* than its predecessor, so it must not fall into the Opus 5 bracket — that would overstate its cost by 25% (60% on cache reads). Edit `set_rates()` in `bin/credit-lib.sh` to update pricing; the account report fingerprints that code in its cache key, so a rate change re-prices every cached session on the next run.

## Architecture

**Bash display layer** handles all output formatting. Reads stdin JSON from Claude Code, computes everything locally, outputs ANSI-colored lines. One `jq` pass, ~45 ms. The only network access is the optional per-model weekly bar, which runs as a detached background fetch and never blocks a render (`STATUSLINE_USAGE_API=0` removes it).

**Node.js backup layer** handles JSONL transcript parsing and backup creation. Called in the background by the bash statusline (via `backup-bridge.sh`) and by the PreCompact/SessionEnd hooks (via `conv-backup.mjs`). The optional **backup compaction** step (`backup-compactor.mjs`) summarizes backups older than 14 days by invoking the `claude` CLI.

## Configuration

Environment variables:

- `CLAUDE_CONFIG_DIR` — overrides `~/.claude` for script, settings and transcript location (honoured by every script)
- `XDG_CACHE_HOME` — overrides `~/.cache` for the statusline cache dir
- `STATUSLINE_PROJECT_DIR` — project root for backup files (auto-set by hooks; the statusline itself uses `workspace.project_dir` from stdin)
- `STATUSLINE_NODE_DIR` — overrides `~/.claude/statusline-node` for node scripts
- `STATUSLINE_LOG_DIR` — overrides default log directory for the backup system
- `STATUSLINE_SUMMARY_MODEL` — model for the backup compactor (default `claude-sonnet-5`)
- `STATUSLINE_USAGE_API` — set to `0` to disable the per-model weekly bar (no credentials read, no network)
- `STATUSLINE_USAGE_TTL` — seconds between usage fetches for that bar (default `300`)
- `CLAUDE_CODE_OAUTH_TOKEN` — if set, used for the usage fetch instead of `.credentials.json` (same variable Claude Code honours)

## Privacy

The **statusline display** and **backup capture** read only local files (the stdin JSON Claude Code provides and your existing transcript JSONL) and send **no telemetry**.

Two optional components do leave the machine. The **per-model weekly bar** sends one GET with your Claude Code OAuth token to `api.anthropic.com/api/oauth/usage` at most every 5 minutes while a session is open, the same request `/usage` makes; the token is never written to disk by this project, and `STATUSLINE_USAGE_API=0` disables it. The **backup compactor** (`backup-compactor.mjs`) sends summaries of your own backups that are older than 14 days to the Anthropic API via the `claude` CLI, so they can be condensed. If you require strict no-egress, disable it by removing `node/backup-compactor.mjs` (or the `maybeSpawnCompactor()` call in `backup-core.mjs`). Backup files are written to your project's `.claude/backups/` with `0600` permissions and contain verbatim conversation content — treat them as sensitive and keep them gitignored.

See [SECURITY.md](SECURITY.md) for the full trust model and how to report issues.

## License

MIT — see [LICENSE](LICENSE).
