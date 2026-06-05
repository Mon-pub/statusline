#!/usr/bin/env node
// context-breakdown.mjs — approximate "what fills the context window" by category.
//
// Reads a Claude Code transcript JSONL (read-only), counts only the content that
// is live in the current context (everything after the latest compact_boundary),
// and buckets it into:
//   msgs    — user + assistant text and thinking blocks
//   tools   — tool_use inputs (the calls the model made)
//   results — tool_result outputs (usually the heaviest bucket)
//   attach  — file/content attachments
//
// Tokens are approximated as characters / 4 (zero dependencies). Absolute counts
// are rough; the proportions between buckets are what the statusline shows.
//
// Output: an atomic JSON cache the bash statusline reads:
//   { "mtime": <transcript mtime, seconds>, "total": N,
//     "buckets": { "msgs": N, "tools": N, "results": N, "attach": N } }
//
// Usage: node context-breakdown.mjs <transcript_path> <session_id>

import { readFileSync, writeFileSync, renameSync, statSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const CHARS_PER_TOKEN = 4;

// Reject anything outside [A-Za-z0-9-]; the id becomes a cache file name.
function safeSessionId(id) {
  return typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : null;
}

function cacheDir() {
  const base = process.env.XDG_CACHE_HOME || join(homedir(), ".cache");
  return join(base, "claude-statusline");
}

// Approximate token count of an arbitrary value by its serialized length / 4.
function approxTokens(value) {
  if (value == null) return 0;
  const s = typeof value === "string" ? value : safeStringify(value);
  return Math.ceil(s.length / CHARS_PER_TOKEN);
}

function safeStringify(value) {
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return String(value);
  }
}

// Sum the approximate tokens of one transcript record into the buckets.
function accumulate(rec, b) {
  // Attachments can ride on any record type.
  if (rec && rec.attachment != null) {
    b.attach += approxTokens(rec.attachment);
  }

  const msg = rec && rec.message;
  const content = msg && msg.content;
  if (content == null) return;

  // Content may be a plain string (older shape) or an array of typed blocks.
  if (typeof content === "string") {
    b.msgs += approxTokens(content);
    return;
  }
  if (!Array.isArray(content)) return;

  for (const block of content) {
    if (!block || typeof block !== "object") {
      b.msgs += approxTokens(block);
      continue;
    }
    switch (block.type) {
      case "text":
        b.msgs += approxTokens(block.text);
        break;
      case "thinking":
        // Plaintext when present; otherwise the opaque signature stands in.
        b.msgs += approxTokens(block.thinking ?? block.signature);
        break;
      case "tool_use":
        b.tools += approxTokens(block.input);
        break;
      case "tool_result":
        b.results += approxTokens(block.content);
        break;
      default:
        b.msgs += approxTokens(block);
    }
  }
}

function main() {
  const transcriptPath = process.argv[2];
  const sid = safeSessionId(process.argv[3]);
  if (!transcriptPath || !sid) process.exit(0);

  let mtime = 0;
  try {
    mtime = Math.floor(statSync(transcriptPath).mtimeMs / 1000);
  } catch {
    process.exit(0);
  }

  let raw;
  try {
    raw = readFileSync(transcriptPath, "utf8");
  } catch {
    process.exit(0);
  }

  const lines = raw.split("\n");
  const records = [];
  for (const line of lines) {
    if (!line) continue;
    try {
      records.push(JSON.parse(line));
    } catch {
      // Skip partial/truncated trailing lines.
    }
  }

  // Only content after the latest compaction is live in the window.
  let start = 0;
  for (let i = records.length - 1; i >= 0; i--) {
    const r = records[i];
    if (r && r.type === "system" && r.subtype === "compact_boundary") {
      start = i + 1;
      break;
    }
  }

  const b = { msgs: 0, tools: 0, results: 0, attach: 0 };
  for (let i = start; i < records.length; i++) accumulate(records[i], b);

  const total = b.msgs + b.tools + b.results + b.attach;
  const out = JSON.stringify({ mtime, total, buckets: b });

  const dir = cacheDir();
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  } catch {
    /* dir may already exist */
  }
  const dst = join(dir, `breakdown-${sid}.json`);
  const tmp = `${dst}.tmp-${process.pid}`;
  try {
    writeFileSync(tmp, out, { mode: 0o600 });
    renameSync(tmp, dst); // atomic replace so the reader never sees a partial file
  } catch {
    process.exit(0);
  }
}

main();
