#!/usr/bin/env node
// backup-compactor.mjs — summarizes old backup files into archived digests
//
// Runs as a detached background process spawned by backup-core.mjs.
// Finds backup .md files older than 14 days, groups them into batches,
// sends each batch to `claude -p` for summarization, saves the result
// under backups/archived/, then removes the originals.
//
// Session IDs are preserved in summaries for `claude --resume` access.
//
// MIT License — see LICENSE in repo root.

import {
  readFileSync, writeFileSync, mkdirSync, existsSync,
  readdirSync, unlinkSync, statSync,
} from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import { spawnSync } from "child_process";

// Prevent backup hooks from firing inside compactor's claude -p calls
process.env.STATUSLINE_SPAWNED_BY = "backup-core";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PROJECT_ROOT = process.env.STATUSLINE_PROJECT_DIR || process.cwd();
const BACKUP_DIR = join(PROJECT_ROOT, ".claude", "backups");
const ARCHIVE_DIR = join(BACKUP_DIR, "archived");

const STALE_DAYS = 14;
const BATCH_SIZE = 7;
const MAX_BATCHES = 5;
const INTER_BATCH_DELAY_MS = 5000;
const CONTENT_CAP = 4000; // chars per backup sent to summarizer
const LOCK_PATH = join(homedir(), ".cache", "claude-statusline", "compactor.lock");

// ---------------------------------------------------------------------------
// Logging (reuse format from backup-core)
// ---------------------------------------------------------------------------

const LOG_PATH = join(
  process.env.STATUSLINE_LOG_DIR || join(homedir(), ".cache", "claude-statusline"),
  "backup.log"
);

function log(msg) {
  try {
    const dir = dirname(LOG_PATH);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const ts = new Date().toISOString();
    let lines = [];
    if (existsSync(LOG_PATH)) {
      lines = readFileSync(LOG_PATH, "utf-8").split("\n").filter(Boolean).slice(-99);
    }
    lines.push(`[${ts}] compactor: ${msg}`);
    writeFileSync(LOG_PATH, lines.join("\n") + "\n");
  } catch { /* silent */ }
}

// ---------------------------------------------------------------------------
// Lock management
// ---------------------------------------------------------------------------

function takeLock() {
  try {
    const dir = dirname(LOCK_PATH);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    if (existsSync(LOCK_PATH)) {
      const age = Date.now() - statSync(LOCK_PATH).mtimeMs;
      if (age < 600_000) {
        log(`Lock held (${Math.round(age / 1000)}s old), exiting`);
        return false;
      }
    }
    writeFileSync(LOCK_PATH, new Date().toISOString());
    return true;
  } catch (e) {
    log(`Lock error: ${e.message}`);
    return false;
  }
}

function releaseLock() {
  try { if (existsSync(LOCK_PATH)) unlinkSync(LOCK_PATH); } catch { /* ok */ }
}

// ---------------------------------------------------------------------------
// Filename parsing — extract date and number from backup filenames
// Format: {N}-backup-{YYYY}-{MM}-{DD}-{HHmm}.md
// ---------------------------------------------------------------------------

function backupNum(filename) {
  const m = filename.match(/^(\d+)-/);
  return m ? parseInt(m[1], 10) : 0;
}

function backupDate(filename) {
  const m = filename.match(/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})\.md$/);
  if (!m) return null;
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
}

// ---------------------------------------------------------------------------
// Content helpers
// ---------------------------------------------------------------------------

function extractField(content, label) {
  const re = new RegExp(`\\*\\*${label}:\\*\\*\\s*(.+)`);
  const m = content.match(re);
  return m ? m[1].trim() : "unknown";
}

// Session ids are UUIDs. Reject anything that isn't [A-Za-z0-9-] before it is
// interpolated into a copy-pasteable `claude --resume <sid>` command or a prompt,
// so a tampered backup file can't inject shell/markdown via the id.
function safeSessionId(sid) {
  return /^[A-Za-z0-9-]{1,64}$/.test(sid) ? sid : "(invalid)";
}

function trimContent(content) {
  // Keep structure but cap long sections
  const lines = content.split("\n");
  const out = [];
  let inLongSection = false;
  let sectionLines = 0;

  for (const line of lines) {
    if (line.startsWith("## ")) {
      inLongSection = false;
      sectionLines = 0;
    }
    if (inLongSection) continue;

    out.push(line);
    sectionLines++;

    // Cap any section at 20 lines
    if (sectionLines > 20 && !line.startsWith("#")) {
      inLongSection = true;
      out.push("  (...truncated)");
    }
  }

  const joined = out.join("\n");
  return joined.length > CONTENT_CAP ? joined.slice(0, CONTENT_CAP) + "\n...(truncated)" : joined;
}

// ---------------------------------------------------------------------------
// Summarization via claude -p
// ---------------------------------------------------------------------------

function buildPrompt(batch, contents) {
  let prompt = `Summarize these Claude Code session backups for archival. For each session, write one substantive paragraph (4-6 sentences) covering: what the user worked on, key actions/files/decisions, outcome, and notable tools or patterns.\n\n`;
  prompt += `Format each as: ## Backup #N -- Session: <session-id>\n\nFollowed by the paragraph. Be specific, not vague. No bullet points.\n\n`;

  for (let i = 0; i < batch.length; i++) {
    const num = backupNum(batch[i]);
    const sid = safeSessionId(extractField(contents[i], "Session"));
    const trimmed = trimContent(contents[i]);
    prompt += `=== Backup #${num} | Session: ${sid} ===\n${trimmed}\n\n`;
  }

  return prompt;
}

function summarizeWithClaude(prompt) {
  log(`Calling claude -p (${prompt.length} chars)`);

  const res = spawnSync("claude", ["-p", "--model", "claude-sonnet-4-6"], {
    input: prompt,
    encoding: "utf-8",
    timeout: 180_000,
    env: { ...process.env, STATUSLINE_SPAWNED_BY: "backup-core" },
    cwd: PROJECT_ROOT,
    windowsHide: true,
  });

  if (res.error) { log(`CLI error: ${res.error.message}`); return null; }
  if (res.status !== 0) { log(`CLI exit ${res.status}: ${(res.stderr || "").slice(0, 200)}`); return null; }
  return (res.stdout || "").trim() || null;
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

function buildSummaryFile(batch, contents, summaryText) {
  const firstNum = backupNum(batch[0]);
  const lastNum = backupNum(batch[batch.length - 1]);
  const firstDate = backupDate(batch[0]);
  const lastDate = backupDate(batch[batch.length - 1]);

  const fmtDate = d => d ? d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "?";
  const range = `${fmtDate(firstDate)} - ${fmtDate(lastDate)}`;

  let out = `# Session Summary (Backups #${firstNum}-${lastNum})\n\n`;
  out += `- **Date range:** ${range}\n`;
  out += `- **Sessions:** ${batch.length}\n`;
  out += `- **Generated:** ${new Date().toISOString()}\n\n`;

  out += "## Session index\n\n";
  out += "| # | Session ID | Date | Resume |\n";
  out += "|---|-----------|------|--------|\n";
  for (let i = 0; i < batch.length; i++) {
    const num = backupNum(batch[i]);
    const sid = safeSessionId(extractField(contents[i], "Session"));
    const d = backupDate(batch[i]);
    out += `| ${num} | ${sid} | ${fmtDate(d)} | \`claude --resume ${sid}\` |\n`;
  }
  out += "\n---\n\n";
  out += summaryText + "\n";

  return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log("Compactor started");

  if (!takeLock()) return;

  try {
    if (!existsSync(BACKUP_DIR)) { log("No backup dir"); return; }

    const cutoff = new Date(Date.now() - STALE_DAYS * 24 * 3600 * 1000);
    const allMd = readdirSync(BACKUP_DIR)
      .filter(f => /^\d+-backup-/.test(f) && f.endsWith(".md"))
      .sort((a, b) => backupNum(a) - backupNum(b));

    const stale = allMd.filter(f => {
      const d = backupDate(f);
      return d && d < cutoff;
    });

    if (stale.length < BATCH_SIZE) {
      log(`Only ${stale.length} stale (need ${BATCH_SIZE}), done`);
      return;
    }

    // Full batches only
    const batches = [];
    for (let i = 0; i + BATCH_SIZE <= stale.length; i += BATCH_SIZE) {
      batches.push(stale.slice(i, i + BATCH_SIZE));
    }

    const toProcess = batches.slice(0, MAX_BATCHES);
    log(`${toProcess.length} of ${batches.length} batches`);

    mkdirSync(ARCHIVE_DIR, { recursive: true });
    let processed = 0;

    for (let b = 0; b < toProcess.length; b++) {
      const batch = toProcess[b];
      const contents = batch.map(f => {
        try { return readFileSync(join(BACKUP_DIR, f), "utf-8"); }
        catch { return ""; }
      });

      const prompt = buildPrompt(batch, contents);
      const summary = summarizeWithClaude(prompt);

      if (!summary) {
        log(`Batch ${b + 1} failed, skip`);
        continue;
      }

      const firstN = backupNum(batch[0]);
      const lastN = backupNum(batch[batch.length - 1]);
      const outFile = `summary-${firstN}-to-${lastN}.md`;
      const outContent = buildSummaryFile(batch, contents, summary);

      writeFileSync(join(ARCHIVE_DIR, outFile), outContent);
      log(`Wrote archived/${outFile}`);

      // Remove originals
      for (const f of batch) {
        try { unlinkSync(join(BACKUP_DIR, f)); } catch { /* skip */ }
      }

      processed += batch.length;

      if (b < toProcess.length - 1) {
        await new Promise(r => setTimeout(r, INTER_BATCH_DELAY_MS));
      }
    }

    log(`Done: ${processed} backups -> ${toProcess.length} summaries`);
  } finally {
    releaseLock();
  }
}

main().catch(e => {
  log(`Fatal: ${e.message}`);
  releaseLock();
  process.exit(0);
});
