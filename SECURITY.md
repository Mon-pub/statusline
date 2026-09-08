# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub's "Report a vulnerability"
(Security advisories) on this repository, or by opening an issue that asks for a
private contact channel — do not include exploit details in a public issue.
We aim to acknowledge reports within a few days.

## Trust model

This project runs as a Claude Code **statusline command** and **PreCompact hook**.
Both execute on every session with your user privileges. Treat all inputs as
untrusted and review the scripts before installing — they are short and do one
thing each.

### Inputs and how they are treated

| Input | Source | Treatment |
|-------|--------|-----------|
| Statusline stdin JSON | Claude Code | All fields are extracted in a single `jq` pass that is the trust boundary: numeric fields are coerced to integers/numbers before any `bash` arithmetic (a string in a numeric slot becomes `0` or is dropped); 5h/7d percentages are range-checked to `0–100`; every printed string (`model.display_name`, `effort.level`, `output_style.name`, `prompt_cache.ttl`, `agent.name`, worktree names, paths) has C0/C1 control bytes stripped inside `jq`; `session_id` is reduced to `[A-Za-z0-9-]` before being used in any file path. The git branch (from `git symbolic-ref`) is control-stripped too. Absent fields are emitted as empty strings so array positions can never shift. |
| Transcript JSONL | On disk (`~/.claude/projects/...`) | Parsed read-only for token/cost accounting, backup summaries, and the context-fill breakdown. Content is never `eval`'d. |
| OAuth credentials | `$CLAUDE_CONFIG_DIR/.credentials.json` (or `CLAUDE_CODE_OAUTH_TOKEN`) | Read only by the detached usage fetcher in `usage-lib.sh`, only when `STATUSLINE_USAGE_API` is not `0`. The access token is checked against `[A-Za-z0-9._~+/=-]` before it is placed in a header, sent solely to `https://api.anthropic.com/api/oauth/usage`, and never written to the cache, a log, or the line. An expired token is skipped, never refreshed (refresh tokens rotate; racing Claude Code's own refresh could log you out). |
| Usage cache | `$XDG_CACHE_HOME/claude-statusline/usage.json` | Written `0600` via temp file + rename by the fetcher; holds only timestamps and `{name, percent, reset}` per bucket. Server-supplied names are control-stripped and capped at 24 chars on write and again on read; percentages are re-validated as non-negative numbers before any arithmetic. Data older than a day is not rendered. |
| Delta / cache files | `$XDG_CACHE_HOME/claude-statusline` | Values are validated as integers/decimals before arithmetic or printing. The breakdown cache (`breakdown-<id>.json`) is written `0600` via a temp-file + atomic rename and read back through `jq`; its numeric fields are re-guarded before use. Files older than 30 days are purged daily (only the statusline's own `breakdown-*`/`delta-*`/`credit-*` patterns, never the directory). |
| Backup markdown | `.claude/backups/` | Session ids read back from backups are re-validated against `^[A-Za-z0-9-]{1,64}$` before being placed in any `claude --resume` command string. The backup path read from the per-session state file is re-matched against `^\.claude/backups/[A-Za-z0-9._-]+\.md$` before it is printed. |

### Network egress

- The **backup capture** makes **no network calls**.
- The **statusline** makes one optional call: `usage-lib.sh` fetches
  `GET https://api.anthropic.com/api/oauth/usage` (the request `/usage` makes)
  in a detached `curl` with an 8 s cap, at most once per `STATUSLINE_USAGE_TTL`
  seconds (default 300), to draw the per-model weekly bar. The render itself
  never waits on it. Disable with `STATUSLINE_USAGE_API=0`; the feature is also
  inert without `curl` or without a credentials file.
- The **backup compactor** (`node/backup-compactor.mjs`) invokes the `claude` CLI
  (`claude -p --bare --no-session-persistence`) to summarize backups older than
  14 days. This sends summaries of your own backup files to the Anthropic API.
  Together with the usage fetch above, these are the only egress surfaces. `--bare` skips hooks and plugins inside the
  summariser so no third-party hook sees the backup text; the
  `STATUSLINE_SPAWNED_BY` guard additionally stops our own hooks from recursing.
  Disable it by deleting `node/backup-compactor.mjs` or removing the
  `maybeSpawnCompactor()` call in `node/backup-core.mjs`.

### Data at rest

- Backup files (`.claude/backups/*.md`) and state/lock files are written with
  mode `0600`; their directory is created `0700`. They contain **verbatim
  conversation content** (your prompts, file paths) and may capture secrets you
  pasted into a chat. Keep `.claude/backups/` gitignored (the repo's own
  `.gitignore` already does this for this project tree).
- No credentials are read or written by any script.

### Hooks

The installer writes a `PreCompact` hook (async) and a `SessionEnd` hook
(synchronous, 20 s timeout) into `settings.json`; both run the same script. The
hook always exits `0` and writes only to **stderr**, so it can never emit a
`{"decision":"block"}` object that would prevent compaction. The installer is
idempotent: re-running it never duplicates a hook or the `statusLine` entry
(hooks are matched on the `conv-backup.mjs` command, so a changed install path
replaces rather than duplicates), leaves hooks it did not write untouched,
edits `settings.json` atomically (temp file + validate + rename), keeps a
pristine `.bak`, and enforces `0600` on the result.

## Hardening notes for users

- Prefer installing into a **project** `.claude/settings.json` (reviewable in
  source control) over the global `~/.claude/settings.json`.
- Review `bin/*.sh` and `node/*.mjs` before running `install.sh`.
- If you do not want any backups on disk, install with `--no-hooks` and the
  statusline still works; the display layer never writes conversation content.

## Verification

`bash tests/run.sh` exercises the usage fetcher against a `file://` fixture
(never the network) with a hostile bucket name, a non-numeric percentage and a
fake token, and asserts the token never reaches the cache. It also exercises the
trust boundary with hostile stdin (terminal
escapes in `display_name`, command substitutions in numeric slots, path
traversal in `session_id`, non-JSON input) and asserts nothing is evaluated or
echoed raw. Run it after any change to `bin/` or `node/`.

## Supported versions

The project tracks the latest Claude Code release (currently 2.1.261). Fixes
land on `main`; there are no long-term support branches.
