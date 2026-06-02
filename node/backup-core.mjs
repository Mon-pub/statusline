#!/usr/bin/env node
// backup-core.mjs — context backup engine for claude-statusline
//
// Clean-room implementation. Parses Claude Code transcript JSONL files,
// extracts session activity, generates markdown summaries, and saves
// numbered backup files. Manages per-session state for threshold-based
// backup triggering.
//
// MIT License — see LICENSE in repo root.

import {
  readFileSync, writeFileSync, mkdirSync, existsSync,
  readdirSync, statSync, renameSync, unlinkSync,
} from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { spawn } from "child_process";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PROJECT_ROOT = process.env.STATUSLINE_PROJECT_DIR || process.cwd();
const BACKUP_DIR = join(PROJECT_ROOT, ".claude", "backups");
const LOG_PATH = join(
  process.env.STATUSLINE_LOG_DIR || join(homedir(), ".cache", "claude-statusline"),
  "backup.log"
);

const LOCK_TTL_MS = 30_000;
const STALE_STATE_AGE_MS = 7 * 24 * 3600 * 1000;

// Backup triggers: token-count based
const FIRST_BACKUP_TOKENS = 50_000;
const BACKUP_INTERVAL_TOKENS = 10_000;

// Backup triggers: free-percentage based (safety net)
const PCT_THRESHOLDS = [30, 15, 5];
const CONTINUOUS_PCT = 5;

// ---------------------------------------------------------------------------
// Logging (append-only, capped at 100 lines)
// ---------------------------------------------------------------------------

export function appendLog(msg) {
  try {
    const dir = dirname(LOG_PATH);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
    const ts = new Date().toISOString();
    const entry = `[${ts}] ${msg}`;
    let lines = [];
    if (existsSync(LOG_PATH)) {
      lines = readFileSync(LOG_PATH, "utf-8").split("\n").filter(Boolean).slice(-99);
    }
    lines.push(entry);
    writeFileSync(LOG_PATH, lines.join("\n") + "\n", { mode: 0o600 });
  } catch { /* silent */ }
}

// ---------------------------------------------------------------------------
// Atomic file write (tmp + rename)
// ---------------------------------------------------------------------------

function safeWrite(path, data) {
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmp, data, { mode: 0o600 });
  try {
    renameSync(tmp, path);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* ignore */ }
    throw e;
  }
}

// ---------------------------------------------------------------------------
// State management — per-session JSON in BACKUP_DIR
// ---------------------------------------------------------------------------

function stateFile(sessionId) {
  const safe = (sessionId || "unknown").replace(/[^a-zA-Z0-9_-]/g, "_");
  return join(BACKUP_DIR, `.state-${safe}.json`);
}

function lockFile(sessionId) {
  const safe = (sessionId || "unknown").replace(/[^a-zA-Z0-9_-]/g, "_");
  return join(BACKUP_DIR, `.lock-${safe}`);
}

export function loadState(sessionId) {
  try {
    const p = stateFile(sessionId);
    if (existsSync(p)) return JSON.parse(readFileSync(p, "utf-8"));
  } catch { /* ignore */ }
  return { prevFreePct: 100, prevTokens: 0, backupPath: null };
}

export function saveState(sessionId, state) {
  try {
    mkdirSync(BACKUP_DIR, { recursive: true, mode: 0o700 });
    safeWrite(stateFile(sessionId), JSON.stringify(state, null, 2));
  } catch { /* silent */ }
}

// Sweep state/lock files older than 7 days (skip current session).
let swept = false;
function sweepOldFiles(currentSessionId) {
  if (swept) return;
  swept = true;
  try {
    if (!existsSync(BACKUP_DIR)) return;
    const safeCur = (currentSessionId || "").replace(/[^a-zA-Z0-9_-]/g, "_");
    const now = Date.now();
    for (const name of readdirSync(BACKUP_DIR)) {
      if (!(name.startsWith(".state-") || name.startsWith(".lock-"))) continue;
      if (safeCur && name.includes(safeCur)) continue;
      const full = join(BACKUP_DIR, name);
      try {
        if (now - statSync(full).mtimeMs > STALE_STATE_AGE_MS) unlinkSync(full);
      } catch { /* per-file */ }
    }
  } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// Lock — prevents duplicate backups from concurrent statusline processes
// ---------------------------------------------------------------------------

function acquireLock(sessionId) {
  const lf = lockFile(sessionId);
  try {
    mkdirSync(BACKUP_DIR, { recursive: true, mode: 0o700 });
    if (existsSync(lf)) {
      const age = Date.now() - statSync(lf).mtimeMs;
      if (age < LOCK_TTL_MS) return false;
    }
    writeFileSync(lf, String(Date.now()));
    return true;
  } catch { return true; } // proceed on lock errors
}

// ---------------------------------------------------------------------------
// Threshold logic — should we create/update a backup?
// ---------------------------------------------------------------------------

export function shouldBackup(totalTokens, freePct, state) {
  const { prevTokens = 0, prevFreePct = 100 } = state;

  // Token-based: first at 50k, then every 10k
  if (totalTokens >= FIRST_BACKUP_TOKENS) {
    if (prevTokens < FIRST_BACKUP_TOKENS) {
      return `tokens-${Math.round(totalTokens / 1000)}k-first`;
    }
    if (totalTokens - prevTokens >= BACKUP_INTERVAL_TOKENS) {
      return `tokens-${Math.round(totalTokens / 1000)}k-update`;
    }
  }

  // Percentage-based: crossing thresholds downward
  for (const t of PCT_THRESHOLDS) {
    if (prevFreePct > t && freePct <= t) return `crossed-${t}pct`;
  }

  // Below continuous threshold: any decrease triggers
  if (freePct < CONTINUOUS_PCT && freePct < prevFreePct) {
    return `below-${CONTINUOUS_PCT}pct`;
  }

  return null;
}

// ---------------------------------------------------------------------------
// Transcript JSONL parsing
// ---------------------------------------------------------------------------

function parseTranscript(jsonlPath) {
  if (!existsSync(jsonlPath)) return null;

  const result = {
    userMessages: [],
    filesChanged: new Set(),
    toolsUsed: {},
    tasksCreated: 0,
    tasksCompleted: 0,
    agentCalls: [],
    startTime: null,
    endTime: null,
  };

  try {
    const raw = readFileSync(jsonlPath, "utf-8");
    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }

      if (entry.timestamp) {
        if (!result.startTime) result.startTime = entry.timestamp;
        result.endTime = entry.timestamp;
      }

      // User messages (skip tool results, system, short fragments)
      if (entry.type === "user" && typeof entry.message?.content === "string") {
        const text = entry.message.content.trim();
        if (text.length >= 10
          && !text.startsWith("[{")
          && !text.startsWith('{"tool_use_id"')
          && !text.startsWith("<command-")
          && !text.startsWith("<local-command-")
          && !text.includes("<local-command-stdout>")
          && !text.startsWith("This session is being continued")) {
          result.userMessages.push(text);
        }
      }

      // Assistant tool use blocks
      if (entry.type === "assistant" && Array.isArray(entry.message?.content)) {
        for (const block of entry.message.content) {
          if (block.type !== "tool_use") continue;
          const name = block.name;
          const input = block.input || {};

          // Track tool call counts
          result.toolsUsed[name] = (result.toolsUsed[name] || 0) + 1;

          // File modifications
          if ((name === "Write" || name === "Edit") && input.file_path) {
            result.filesChanged.add(input.file_path);
          }

          // Task tracking
          if (name === "TaskCreate") result.tasksCreated++;
          if (name === "TaskUpdate" && input.status === "completed") result.tasksCompleted++;

          // Agent dispatches
          if (name === "Agent" || name === "Task") {
            result.agentCalls.push({
              type: input.subagent_type || "general",
              desc: input.description || "",
            });
          }
        }
      }
    }
  } catch (e) {
    appendLog(`Parse error: ${e.message}`);
    return null;
  }

  result.filesChanged = [...result.filesChanged];
  return result;
}

// ---------------------------------------------------------------------------
// Markdown generation
// ---------------------------------------------------------------------------

function relativePath(fullPath) {
  if (fullPath.startsWith(PROJECT_ROOT)) {
    return fullPath.slice(PROJECT_ROOT.length).replace(/^[/\\]/, "");
  }
  return fullPath;
}

function generateMarkdown(parsed, sessionId, trigger, freePct) {
  const lines = [];
  const now = new Date().toISOString();

  lines.push("# Context Backup");
  lines.push("");
  lines.push(`- **Session:** ${sessionId}`);
  lines.push(`- **Trigger:** ${trigger}`);
  if (freePct !== undefined) lines.push(`- **Free context:** ${freePct.toFixed(1)}%`);
  lines.push(`- **Saved:** ${now}`);
  if (parsed.startTime) lines.push(`- **Session start:** ${parsed.startTime}`);
  if (parsed.endTime) lines.push(`- **Session end:** ${parsed.endTime}`);
  lines.push("");

  if (parsed.userMessages.length > 0) {
    lines.push("## User requests");
    for (const msg of parsed.userMessages) lines.push(`- ${msg}`);
    lines.push("");
  }

  if (parsed.filesChanged.length > 0) {
    lines.push("## Files changed");
    for (const f of parsed.filesChanged) lines.push(`- ${relativePath(f)}`);
    lines.push("");
  }

  const toolNames = Object.keys(parsed.toolsUsed);
  if (toolNames.length > 0) {
    lines.push("## Tools used");
    for (const t of toolNames.sort()) {
      lines.push(`- ${t} (${parsed.toolsUsed[t]}x)`);
    }
    lines.push("");
  }

  if (parsed.agentCalls.length > 0) {
    lines.push("## Agents dispatched");
    for (const a of parsed.agentCalls) {
      lines.push(`- **${a.type}**: ${a.desc}`);
    }
    lines.push("");
  }

  if (parsed.tasksCreated > 0 || parsed.tasksCompleted > 0) {
    lines.push("## Task activity");
    lines.push(`- Created: ${parsed.tasksCreated}, Completed: ${parsed.tasksCompleted}`);
    lines.push("");
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Backup file naming — {N}-backup-{YYYY-MM-DD-HHmm}.md
// ---------------------------------------------------------------------------

function nextBackupNumber() {
  try {
    if (!existsSync(BACKUP_DIR)) return 1;
    const nums = readdirSync(BACKUP_DIR)
      .filter(f => /^\d+-backup-/.test(f) && f.endsWith(".md"))
      .map(f => parseInt(f.match(/^(\d+)-/)?.[1] || "0", 10));
    return nums.length > 0 ? Math.max(...nums) + 1 : 1;
  } catch { return 1; }
}

function formatDateTag(d) {
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
}

function writeBackup(markdown, existingPath) {
  // Backups hold verbatim conversation content (user prompts, file paths) and
  // may contain secrets pasted into chat — keep dir 0700 and files 0600.
  mkdirSync(BACKUP_DIR, { recursive: true, mode: 0o700 });

  const tag = formatDateTag(new Date());

  // Update existing backup for this session: rewrite content and rename the
  // file to a fresh date tag (keeping its number) so the displayed filename
  // reflects the latest update, not the session-start date.
  if (existingPath) {
    const oldFull = join(PROJECT_ROOT, existingPath);
    if (existsSync(oldFull)) {
      const num = parseInt(existingPath.match(/(\d+)-backup-/)?.[1] || "0", 10) || nextBackupNumber();
      const newName = `${num}-backup-${tag}.md`;
      const newFull = join(BACKUP_DIR, newName);
      const newRel = `.claude/backups/${newName}`;

      writeFileSync(newFull, markdown, { mode: 0o600 });
      if (newFull !== oldFull) {
        try { unlinkSync(oldFull); } catch { /* ignore */ }
      }
      appendLog(`Backup updated: ${newRel}`);
      return newRel;
    }
  }

  const num = nextBackupNumber();
  const name = `${num}-backup-${tag}.md`;
  const fullPath = join(BACKUP_DIR, name);
  const rel = `.claude/backups/${name}`;

  writeFileSync(fullPath, markdown, { mode: 0o600 });
  appendLog(`Backup created: ${rel}`);
  return rel;
}

// ---------------------------------------------------------------------------
// Transcript discovery — find JSONL for a session ID
// ---------------------------------------------------------------------------

export function findTranscript(sessionId) {
  try {
    const base = join(homedir(), ".claude", "projects");
    if (!existsSync(base)) return null;
    for (const dir of readdirSync(base)) {
      const candidate = join(base, dir, `${sessionId}.jsonl`);
      if (existsSync(candidate)) return candidate;
    }
  } catch { /* ignore */ }
  return null;
}

// ---------------------------------------------------------------------------
// Compactor spawning
// ---------------------------------------------------------------------------

function maybeSpawnCompactor() {
  try {
    if (!existsSync(BACKUP_DIR)) return;

    const cutoff = Date.now() - 14 * 24 * 3600 * 1000;
    const mdFiles = readdirSync(BACKUP_DIR).filter(
      f => /^\d+-backup-/.test(f) && f.endsWith(".md")
    );

    let oldCount = 0;
    for (const f of mdFiles) {
      try {
        if (statSync(join(BACKUP_DIR, f)).mtimeMs < cutoff) oldCount++;
      } catch { /* skip */ }
      if (oldCount >= 7) break;
    }
    if (oldCount < 7) return;

    // Global compactor lock
    const gLock = join(homedir(), ".cache", "claude-statusline", "compactor.lock");
    if (existsSync(gLock) && Date.now() - statSync(gLock).mtimeMs < 600_000) {
      appendLog("Compactor already running, skip");
      return;
    }

    const compactorScript = join(dirname(new URL(import.meta.url).pathname), "backup-compactor.mjs");
    if (!existsSync(compactorScript)) return;

    appendLog("Spawning compactor");
    const child = spawn("node", [compactorScript], {
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        STATUSLINE_PROJECT_DIR: PROJECT_ROOT,
        STATUSLINE_SPAWNED_BY: "backup-core",
      },
      cwd: PROJECT_ROOT,
      windowsHide: true,
    });
    child.unref();
  } catch (e) {
    appendLog(`Compactor spawn error: ${e.message}`);
  }
}

// ---------------------------------------------------------------------------
// Main entry point — run a backup
// ---------------------------------------------------------------------------

export function runBackup(sessionId, trigger, transcriptPath, freePct) {
  if (process.env.STATUSLINE_SPAWNED_BY === "backup-core") return null;

  appendLog(`Backup requested: session=${sessionId?.slice(0, 8)}… trigger=${trigger}`);
  sweepOldFiles(sessionId);

  if (!acquireLock(sessionId)) {
    appendLog("Lock held, skipping");
    const st = loadState(sessionId);
    return st.backupPath || null;
  }

  // Release the lock as soon as this run finishes so the next backup isn't
  // blocked for the full TTL; the TTL stays only as a crash safety net.
  try {
    const jsonlPath = transcriptPath || findTranscript(sessionId);
    if (!jsonlPath) {
      appendLog("No transcript found");
      return null;
    }

    const parsed = parseTranscript(jsonlPath);
    if (!parsed) {
      appendLog("Transcript parse failed");
      return null;
    }

    const md = generateMarkdown(parsed, sessionId, trigger, freePct);
    const state = loadState(sessionId);
    const rel = writeBackup(md, state.backupPath);

    state.backupPath = rel;
    state.prevTokens = state._pendingTokens ?? state.prevTokens;
    state.prevFreePct = state._pendingFreePct ?? state.prevFreePct;
    saveState(sessionId, state);

    maybeSpawnCompactor();
    return rel;
  } finally {
    try { unlinkSync(lockFile(sessionId)); } catch { /* TTL is the fallback */ }
  }
}
