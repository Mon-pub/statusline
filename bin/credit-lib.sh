#!/bin/bash
# credit-lib.sh — shared pricing logic for claude-statusline and credit-project.
#
# Pricing (per 1M tokens):
#   Opus   (opus-*):    $5.00  in / $0.50 cache-read / $6.25  cache-create / $25.00 out
#     ↑ Claude Opus 4.7 rates (confirmed 2026-04-22 by user from openrouter.ai/anthropic/claude-opus-4.7
#       and https://www.anthropic.com/pricing — Opus 4.7 is $5/M input, $25/M output,
#       NOT the legacy Opus 3/4/4.1 rates of $15/$75 that were here before).
#   Sonnet (sonnet-*):  $3.00  in / $0.30 cache-read / $3.75  cache-create / $15.00 out
#   Haiku  (haiku-*):   $1.00  in / $0.10 cache-read / $1.25  cache-create / $5.00  out
#   Unknown families:   Opus pricing (user preference; labelled as the real family name)
#
# Token bucket semantics (Anthropic API):
#   input_tokens                — fresh, non-cached prompt (charged at base input rate)
#   cache_read_input_tokens     — cache-hit portion (~10% of input rate, disjoint from above)
#   cache_creation_input_tokens — cache-write portion (~125% of input rate, disjoint)
#   output_tokens               — generated tokens
#   These four buckets are DISJOINT; summing all four is correct, not double-counting.
#
# Family extraction rule (handles both old claude-3.x and new claude-family-ver naming):
#   1. Strip leading "claude-" prefix (case-insensitive).
#   2. Split remaining string on "-".
#   3. Walk tokens left-to-right; take the first token that is NOT purely numeric.
#   4. Lowercase the result.
#   Examples:
#     claude-opus-4-7-20261022  → opus
#     claude-sonnet-4-6         → sonnet
#     claude-haiku-4-5-20251001 → haiku
#     claude-3-5-sonnet-20241022 → sonnet   (3 and 5 are numeric; sonnet is first non-numeric)
#     claude-3-opus-20240229    → opus      (3 is numeric; opus is first non-numeric)
#     claude-mythos-5           → mythos    (new unknown family; priced at Opus rates)
#     (empty / no model field)  → unknown
#
# Functions:
#   compute_credit_for_jsonl <path>
#       Prints three tab-separated decimals: input_cost\toutput_cost\ttotal_cost
#       (empty string if no assistant messages found).
#       "input_cost" aggregates all three prompt-side tiers (regular + cache-read + cache-create).
#       Callers that only need the total: compute_credit_for_jsonl … | cut -f3
#
#   emit_credit_rows_for_jsonl <path>
#       Prints one line per deduped assistant message:
#           model_bucket\tinput_cost\toutput_cost
#       model_bucket is the extracted family name (opus / sonnet / haiku / mythos / …)
#       Used by credit-project.sh to build per-model breakdowns.

# ---------------------------------------------------------------------------
# _jsonl_to_tsv — internal: grep+jq the JSONL, output one TSV row per
# deduped assistant message:  input_tokens\tcache_read\tcache_create\toutput_tokens\tmodel
# ---------------------------------------------------------------------------
_jsonl_to_tsv() {
    local jsonl_path="$1"
    { grep -F '"type":"assistant"' "$jsonl_path" 2>/dev/null || true; } \
        | jq -rs '
            reduce .[] as $line (
              {};
              if ($line.message.id != null and $line.message.usage != null
                  and (.[$line.message.id] == null))
              then .[$line.message.id] = {
                     usage: $line.message.usage,
                     model: ($line.message.model // "")
                   }
              else .
              end
            )
            | to_entries[]
            | [
                (.value.usage.input_tokens                // 0 | tostring),
                (.value.usage.cache_read_input_tokens     // 0 | tostring),
                (.value.usage.cache_creation_input_tokens // 0 | tostring),
                (.value.usage.output_tokens               // 0 | tostring),
                (.value.model // "")
              ]
            | @tsv' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _AWK_RATE_FN — awk function definitions injected into both awk programs.
#
# extract_family(model_str):
#   Strips "claude-" prefix, then walks hyphen-delimited tokens and returns
#   the first token that is not purely numeric (e.g. "sonnet", "mythos").
#   Falls back to "unknown" for empty/missing model strings.
#   Handles both old-style (claude-3-5-sonnet-*) and new-style (claude-opus-4-*)
#   model IDs correctly.
#
# set_rates(family):
#   Populates ri/rr/rc/ro with per-1M-token rates for the family.
#   Known families: opus, sonnet, haiku.
#   Unknown families: Opus rates (user preference for unknown/pre-release work).
# ---------------------------------------------------------------------------
_AWK_RATE_FN='
    function extract_family(m,    s, n, parts, i, tok) {
        s = tolower(m)
        # Strip leading "claude-" prefix
        if (substr(s, 1, 7) == "claude-") s = substr(s, 8)
        if (s == "") return "unknown"
        n = split(s, parts, "-")
        for (i = 1; i <= n; i++) {
            tok = parts[i]
            # Accept the token if it contains at least one non-digit character
            if (tok ~ /[^0-9]/) return tok
        }
        # All tokens were numeric (unlikely); return the whole stripped string
        return s
    }

    function set_rates(family) {
        if (family == "haiku") {
            ri=1.00;  rr=0.10;  rc=1.25;  ro=5.00
        } else if (family == "sonnet") {
            ri=3.00;  rr=0.30;  rc=3.75;  ro=15.00
        } else if (family == "opus") {
            # Claude Opus 4.7: $5/M in, $25/M out (confirmed 2026-04-22).
            # Cache: read=0.10×in=$0.50, create=1.25×in=$6.25 (Anthropic standard multipliers).
            ri=5.00;  rr=0.50;  rc=6.25;  ro=25.00
        } else {
            # Unknown/future family: default to Opus rates (user preference).
            # The bucket label will be the real family name, not "opus".
            ri=5.00;  rr=0.50;  rc=6.25;  ro=25.00
        }
    }
'

# ---------------------------------------------------------------------------
# compute_credit_for_jsonl <path>
# Prints: input_cost<TAB>output_cost<TAB>total_cost   (all formatted %.4f)
# Prints nothing if no assistant messages / no usage data.
# ---------------------------------------------------------------------------
compute_credit_for_jsonl() {
    local jsonl_path="$1"
    [ -f "$jsonl_path" ] || return

    _jsonl_to_tsv "$jsonl_path" \
        | awk "$_AWK_RATE_FN"'
            BEGIN { in_cost = 0; out_cost = 0 }
            {
              ti = $1+0; cr = $2+0; cc = $3+0; to = $4+0
              family = extract_family($5)
              set_rates(family)
              in_cost  += (ti*ri + cr*rr + cc*rc) / 1000000
              out_cost += (to*ro)                 / 1000000
            }
            END {
              total = in_cost + out_cost
              if (total > 0)
                printf "%.4f\t%.4f\t%.4f", in_cost, out_cost, total
            }'
}

# ---------------------------------------------------------------------------
# emit_credit_rows_for_jsonl <path>
# Prints one line per deduped assistant message:
#   model_bucket<TAB>input_cost<TAB>output_cost
# model_bucket is the extracted family name (opus / sonnet / haiku / mythos / …)
# ---------------------------------------------------------------------------
emit_credit_rows_for_jsonl() {
    local jsonl_path="$1"
    [ -f "$jsonl_path" ] || return

    _jsonl_to_tsv "$jsonl_path" \
        | awk "$_AWK_RATE_FN"'
            {
              ti = $1+0; cr = $2+0; cc = $3+0; to = $4+0
              family = extract_family($5)
              set_rates(family)
              in_c  = (ti*ri + cr*rr + cc*rc) / 1000000
              out_c = (to*ro)                 / 1000000
              if (in_c + out_c == 0) next
              printf "%s\t%.4f\t%.4f\n", family, in_c, out_c
            }'
}
