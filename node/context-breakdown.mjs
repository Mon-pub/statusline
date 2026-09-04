#!/usr/bin/env node
// context-breakdown.mjs — approximate "what fills the context window" by category.
//
// Streams a Claude Code transcript JSONL (read-only, line by line — a 100 MB
// transcript is never held in memory), counts only the content that is live in
// the current context (everything after the latest compact_boundary), and
// buckets it into:
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

import { createReadStream, writeFileSync, renameSync, statSync, mkdirSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { homedir } from "node:os";

const CHARS_PER_TOKEN = 4;

// Reject anything outside [A-Za-z0-9_-]; the id becomes a cache file name.
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

function emptyBuckets() {
  return { msgs: 0, tools: 0, results: 0, attach: 0 };
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

async function main() {
  const transcriptPath = process.argv[2];
  const sid = safeSessionId(process.argv[3]);
  if (!transcriptPath || !sid) return;

  let mtime = 0;
  try {
    mtime = Math.floor(statSync(transcriptPath).mtimeMs / 1000);
  } catch {
    return;
  }

  // Stream line by line. A compact_boundary resets the buckets, so at EOF the
  // buckets hold exactly the content after the LAST boundary — one pass, O(1)
  // memory in the number of records.
  let b = emptyBuckets();
  try {
    const rl = createInterface({
      input: createReadStream(transcriptPath, { encoding: "utf8" }),
      crlfDelay: Infinity,
    });
    for await (const line of rl) {
      if (!line) continue;
      let rec;
      try {
        rec = JSON.parse(line);
      } catch {
        continue; // partial/truncated trailing line
      }
      if (rec && rec.type === "system" && rec.subtype === "compact_boundary") {
        b = emptyBuckets();
        continue;
      }
      accumulate(rec, b);
    }
  } catch {
    return;
  }

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
    /* best effort */
  }
}

main().catch(() => {});
