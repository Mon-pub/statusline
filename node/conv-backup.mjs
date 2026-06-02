#!/usr/bin/env node
// conv-backup.mjs — PreCompact hook for claude-statusline
//
// Reads Claude Code's PreCompact event from stdin and triggers a
// context backup before compaction discards older context.
//
// Hook config in settings.json:
//   "PreCompact": [{ "hooks": [{ "type": "command",
//     "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs",
//     "async": true }] }]
//
// MIT License — see LICENSE in repo root.

import { readFileSync } from "fs";
import { appendLog, runBackup } from "./backup-core.mjs";

try {
  const raw = readFileSync(0, "utf-8");
  const data = JSON.parse(raw);

  const sessionId = data.session_id || "unknown";
  const transcript = data.transcript_path || "";
  const reason = data.trigger || "unknown";

  appendLog(`PreCompact: trigger=${reason} session=${sessionId.slice(0, 8)}…`);

  const path = runBackup(sessionId, `precompact-${reason}`, transcript, undefined);
  // Write to stderr, never stdout: on exit 0 a PreCompact hook's stdout is parsed
  // as an optional {decision:"block"} JSON — keep stdout empty so we can never
  // accidentally block compaction. (We also appendLog above for the record.)
  console.error(path ? `Backup: ${path}` : "Backup skipped");
} catch (e) {
  appendLog(`PreCompact error: ${e.message}`);
}

process.exit(0);
