#!/usr/bin/env node
// trigger-backup.mjs — CLI entry point for backup triggering
//
// Called by backup-bridge.sh in the background:
//   node trigger-backup.mjs <sessionId> <trigger> [freePct]
//
// MIT License — see LICENSE in repo root.

import { runBackup } from "./backup-core.mjs";

const [sessionId, trigger, freePctStr] = process.argv.slice(2);
const freePct = freePctStr ? parseFloat(freePctStr) : undefined;

const path = runBackup(sessionId, trigger, null, freePct);
if (path) process.stdout.write(path);
