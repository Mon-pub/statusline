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
| Statusline stdin JSON | Claude Code | Numeric fields are coerced to integers at the `jq` boundary before any `bash` arithmetic; printed strings (`model.display_name`, `output_style.name`) are stripped of control bytes; `session_id` is reduced to `[A-Za-z0-9-]` before being used in any file path. |
| Transcript JSONL | On disk (`~/.claude/projects/...`) | Parsed read-only for token/cost accounting and backup summaries. Content is never `eval`'d. |
| Delta / cache files | `$XDG_CACHE_HOME/claude-statusline` | Values are validated as integers before arithmetic. |
| Backup markdown | `.claude/backups/` | Session ids read back from backups are re-validated against `^[A-Za-z0-9-]{1,64}$` before being placed in any `claude --resume` command string. |

### Network egress

- The **statusline** and **backup capture** make **no network calls**.
- The **backup compactor** (`node/backup-compactor.mjs`) invokes the `claude` CLI
  (`claude -p`) to summarize backups older than 14 days. This sends summaries of
  your own backup files to the Anthropic API. It is the only egress surface.
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

The installer writes a `PreCompact` hook into `settings.json`. The hook always
exits `0` and writes only to **stderr**, so it can never emit a
`{"decision":"block"}` object that would prevent compaction. The installer is
idempotent: re-running it never duplicates the hook or the `statusLine` entry,
edits `settings.json` atomically (temp file + validate + rename), keeps a
pristine `.bak`, and enforces `0600` on the result.

## Hardening notes for users

- Prefer installing into a **project** `.claude/settings.json` (reviewable in
  source control) over the global `~/.claude/settings.json`.
- Review `bin/*.sh` and `node/*.mjs` before running `install.sh`.
- If you do not want any backups on disk, install with `--no-hooks` and the
  statusline still works; the display layer never writes conversation content.

## Supported versions

The project tracks the latest Claude Code release. Fixes land on `main`; there
are no long-term support branches.
