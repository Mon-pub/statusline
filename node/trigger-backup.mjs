#!/usr/bin/env node
// trigger-backup.mjs — CLI entry point for backup triggering
//
// Called by backup-bridge.sh in the background whenever the live token count
// moved 5k+ since the last spawn:
//   node trigger-backup.mjs <sessionId> <trigger> [freePct] [transcriptPath] [totalTokens]
//
// The bash side is only a coarse rate limiter. The real policy lives here:
// shouldBackup() decides from the per-session state whether this token count
// crosses a backup threshold (first at 50k, then every 10k, plus the 30/15/5 %
// free safety net). When <totalTokens> is omitted (older bridge) the backup
// runs unconditionally, as before.
//
// MIT License — see LICENSE in repo root.

import { runBackup, loadState, shouldBackup, appendLog } from "./backup-core.mjs";

const [sessionId, trigger, freePctStr, transcriptPathArg, totalTokensStr] = process.argv.slice(2);

if (!sessionId) process.exit(0);

const freePctNum = parseFloat(freePctStr);
const freePct = Number.isFinite(freePctNum) ? freePctNum : undefined;
const transcriptPath = transcriptPathArg || null;
const totalTokens = /^\d{1,12}$/.test(totalTokensStr || "") ? parseInt(totalTokensStr, 10) : undefined;

let reason = trigger || "manual";
if (totalTokens !== undefined) {
  const state = loadState(sessionId);
  const decision = shouldBackup(totalTokens, freePct ?? state.prevFreePct ?? 100, state);
  if (!decision) process.exit(0);           // below threshold: nothing to do, state untouched
  reason = decision;
  appendLog(`Threshold hit: ${decision} (prev ${state.prevTokens ?? 0} tokens, ${state.prevFreePct ?? 100}% free)`);
}

const path = runBackup(sessionId, reason, transcriptPath, freePct, { totalTokens });
if (path) process.stdout.write(path);
