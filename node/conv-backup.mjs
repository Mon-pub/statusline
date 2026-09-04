#!/usr/bin/env node
// conv-backup.mjs — PreCompact / SessionEnd hook for claude-statusline
//
// Reads the hook event JSON from stdin and triggers a context backup:
//   PreCompact  — always: compaction is about to discard older context.
//                 Afterwards the token thresholds are re-armed (prevTokens=0)
//                 so the post-compaction climb produces fresh backups.
//   SessionEnd  — only for sessions that already have a backup: refresh it one
//                 last time so the file reflects the whole session. Sessions
//                 that never reached a threshold do not get a file created.
//
// Hook config in settings.json (install.sh writes both):
//   "PreCompact": [{ "hooks": [{ "type": "command", "async": true,
//     "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs" }] }],
//   "SessionEnd": [{ "hooks": [{ "type": "command", "timeout": 20,
//     "command": "STATUSLINE_PROJECT_DIR=\"$CLAUDE_PROJECT_DIR\" node ~/.claude/statusline-node/conv-backup.mjs" }] }]
// (SessionEnd is synchronous on purpose: an async hook may be torn down with
//  the exiting session before it finishes writing.)
//
// MIT License — see LICENSE in repo root.

import { readFileSync } from "fs";
import { appendLog, runBackup, loadState } from "./backup-core.mjs";

try {
  const raw = readFileSync(0, "utf-8");
  const data = JSON.parse(raw);

  const sessionId = typeof data.session_id === "string" ? data.session_id : "unknown";
  const transcript = typeof data.transcript_path === "string" ? data.transcript_path : "";
  const event = data.hook_event_name || "PreCompact";
  const short = sessionId.slice(0, 8);

  let path = null;
  if (event === "SessionEnd") {
    const reason = data.reason || "unknown";
    const state = loadState(sessionId);
    if (state.backupPath) {
      appendLog(`SessionEnd: reason=${reason} session=${short}…`);
      path = runBackup(sessionId, `session-end-${reason}`, transcript, undefined);
    } else {
      appendLog(`SessionEnd: reason=${reason} session=${short}… (no prior backup, skip)`);
    }
  } else {
    const reason = data.trigger || "unknown";
    appendLog(`PreCompact: trigger=${reason} session=${short}…`);
    path = runBackup(sessionId, `precompact-${reason}`, transcript, undefined, { rearm: true });
  }

  // Write to stderr, never stdout: on exit 0 a hook's stdout may be parsed as a
  // decision object — keep stdout empty so we can never block compaction.
  console.error(path ? `Backup: ${path}` : "Backup skipped");
} catch (e) {
  appendLog(`Hook error: ${e.message}`);
}

process.exit(0);
