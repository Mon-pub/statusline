#!/bin/bash
# credit-lib.sh — shared pricing logic for the statusline and the credit report.
#
# Pricing (per 1M tokens; verified 2026-10-04 from
# https://platform.claude.com/docs/en/about-claude/pricing).
# Cache multipliers vs base input: 5-minute write 1.25x, 1-hour write 2x,
# read 0.1x — except Fable/Mythos 5.1 where a read is 0.025x ($0.25) and
# Opus 5.5 where it is 0.05x ($0.20).
#
#   Fable / Mythos 5.1:  $10 in / $0.25 read / $12.50 5m / $20 1h / $50 out
#   Fable / Mythos 5:    $10 in / $1.00 read / $12.50 5m / $20 1h / $50 out
#   Opus 5.5:            $4  in / $0.20 read / $5     5m / $8  1h / $20 out
#     fast mode: $8 in / $40 out; cache multipliers stack on the fast input
#     price ($0.40 read / $10 5m / $16 1h). Rates verified 2026-09-28.
#   Opus 5, 4.5–4.8:     $5  in / $0.50 read / $6.25  5m / $10 1h / $25 out
#     fast mode (usage.speed=="fast", Opus 5 / 4.8): $10 in / $50 out, cache
#     multipliers stack on the fast input price ($1 read / $12.50 5m / $20 1h).
#   Opus 4.0 / 4.1 / 3:  $15 in / $1.50 read / $18.75 5m / $30 1h / $75 out (retired)
#   Sonnet 5.5 / 5:      $2  in / $0.20 read / $2.50  5m / $4  1h / $10 out
#     (Sonnet 5.5, 2026-10: same price, standard multipliers, no fast mode)
#     (the launch "introductory" $2/$10 became the permanent price; the
#     scheduled 2026-09-01 rise to $3/$15 was cancelled)
#   Sonnet 4.x / 3.x:    $3  in / $0.30 read / $3.75  5m / $6  1h / $15 out
#   Haiku 4.5:           $1  in / $0.10 read / $1.25  5m / $2  1h / $5  out
#   Haiku 3.x:           $0.80 in / $0.08 read / $1 5m / $1.60 1h / $4 out (retired)
#   Unknown families:    Opus 5 rates (labelled with the real family name)
#
# Token bucket semantics (Anthropic API):
#   input_tokens                — fresh, non-cached prompt (charged at base input rate)
#   cache_read_input_tokens     — cache-hit portion (disjoint from above)
#   cache_creation_input_tokens — cache-write portion (disjoint), split further in
#                                 usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens
#   output_tokens               — generated tokens
#   These buckets are DISJOINT; summing all of them is correct, not double-counting.
#
# Model-id parsing (handles both old claude-3.x and new claude-family-ver naming):
#   1. Strip leading "claude-" prefix (case-insensitive), lowercase.
#   2. Split on "-". The family is the first token containing a non-digit.
#   3. The version is the first two purely-numeric tokens of at most 2 digits
#      (8-digit date stamps are skipped), joined as major.minor.
#   Examples:
#     claude-opus-4-7-20261022   → opus   4.7
#     claude-sonnet-4-6          → sonnet 4.6
#     claude-haiku-4-5-20251001  → haiku  4.5
#     claude-3-5-sonnet-20241022 → sonnet 3.5
#     claude-3-opus-20240229     → opus   3.0
#     claude-fable-5-1           → fable  5.1
#     claude-opus-5-5            → opus   5.5  ($4/$20, 0.05x read — cheaper than 5.0)
#     claude-opus-5              → opus   5.0
#     claude-zephyr-6            → zephyr 6.0  (unknown family → Opus 5 rates)
#     (empty / no model field)   → unknown
#
# Functions:
#   compute_credit_for_jsonl <path>...
#       Prints three tab-separated decimals: input_cost\toutput_cost\ttotal_cost
#       (empty string if no assistant messages found).
#       "input_cost" aggregates all prompt-side tiers (regular + cache-read + cache-write).
#       Callers that only need the total: compute_credit_for_jsonl … | cut -f3
#
#   Both functions accept several paths (main transcript + subagent transcripts)
#   and price them as one set; the first path must exist.
#
#   emit_credit_rows_dated_for_jsonl <path>...
#       Prints one line per deduped assistant message:
#           day\tbucket\tinput_cost\toutput_cost
#       Use this for any report over a time window — see the note on the
#       function itself for why a file mtime is not a usable substitute.
#
#   emit_credit_rows_for_jsonl <path>...
#       Prints one line per deduped assistant message:
#           bucket\tinput_cost\toutput_cost
#       bucket is "<family>-<major>.<minor>" (e.g. fable-5.1, opus-4.8), with a
#       "+fast" suffix for fast-mode responses. Used for per-model breakdowns.

# ---------------------------------------------------------------------------
# _CREDIT_DAY_EXPR — jq expression mapping a record to the LOCAL calendar day
# ("YYYY-MM-DD") its message was produced on, or "" when there is no usable
# timestamp. Local, not UTC, because callers filter with local dates. Detected
# once: strflocaltime is jq 1.6+, and an undefined function is a COMPILE error,
# so `try` cannot guard it — probe instead and fall back to the raw UTC prefix.
# ---------------------------------------------------------------------------
if jq -n 'now|strflocaltime("%Y")' >/dev/null 2>&1; then
    _CREDIT_DAY_EXPR='(.timestamp // "" | if type=="string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
                       then (sub("\\.[0-9]+"; "") | sub("[+-][0-9]{2}:?[0-9]{2}$"; "Z")
                             | (try (fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch .[0:10]))
                       else "" end)'
else
    _CREDIT_DAY_EXPR='(.timestamp // "" | if type=="string" then .[0:10] else "" end)'
fi

# ---------------------------------------------------------------------------
# _jsonl_to_tsv <path>... — internal: grep+jq one or more JSONL files (a main
# transcript plus its subagent transcripts, typically), output one TSV row per
# deduped assistant message:
#   input\tcache_read\tcache_create\toutput\tcc_1h\tcc_5m\tmodel\tspeed\tday
# Message ids are unique across files, so the dedup is safe over the whole set.
# ---------------------------------------------------------------------------
_jsonl_to_tsv() {
    [ "$#" -gt 0 ] || return 0
    { grep -h -F '"type":"assistant"' -- "$@" 2>/dev/null || true; } \
        | jq -rs "
            def day: ${_CREDIT_DAY_EXPR};"'
            reduce .[] as $line (
              {};
              if ($line.message.id != null and $line.message.usage != null
                  and ($line.message.model // "") != "<synthetic>"
                  and (.[$line.message.id] == null))
              then .[$line.message.id] = {
                     usage: $line.message.usage,
                     model: ($line.message.model // ""),
                     day:   ($line | day)
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
                (.value.usage.cache_creation.ephemeral_1h_input_tokens // 0 | tostring),
                (.value.usage.cache_creation.ephemeral_5m_input_tokens // 0 | tostring),
                (.value.model // ""),
                (.value.usage.speed // ""),
                (.value.day // "")
              ]
            | @tsv' 2>/dev/null
}

# ---------------------------------------------------------------------------
# _AWK_RATE_FN — awk function definitions injected into both awk programs.
#
# parse_model(model_str): sets globals FAMILY, MAJOR, MINOR (see header rules).
# set_rates(family, major, minor, speed): populates ri/rr/rc/rc1h/ro (per 1M).
# cache_create_cost(cc, cc1h, cc5m): prices the cache write using the split
#   tiers when present, else the merged count at the 5-minute rate.
# bucket_label(): "<family>-<major>.<minor>[+fast]" for breakdown tables.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # awk program, not shell expansion
_AWK_RATE_FN='
    function parse_model(m,    s, n, parts, i, tok, nums) {
        FAMILY = "unknown"; MAJOR = 0; MINOR = 0; nums = 0
        s = tolower(m)
        if (substr(s, 1, 7) == "claude-") s = substr(s, 8)
        if (s == "") return
        n = split(s, parts, "-")
        for (i = 1; i <= n; i++) {
            tok = parts[i]
            if (tok ~ /[^0-9]/) {
                if (FAMILY == "unknown") FAMILY = tok
            } else if (length(tok) <= 2) {
                nums++
                if (nums == 1) MAJOR = tok + 0
                else if (nums == 2) MINOR = tok + 0
            }
        }
        if (FAMILY == "unknown" && s != "") FAMILY = s
    }

    # Apply the standard cache multipliers to a base input price.
    function std_cache(base) { rr = base * 0.10; rc = base * 1.25; rc1h = base * 2.0 }

    function set_rates(family, major, minor, speed,    ver) {
        ver = major + minor / 10.0
        if (family == "haiku") {
            if (major >= 4) { ri = 1.00; ro = 5.00 } else { ri = 0.80; ro = 4.00 }
            std_cache(ri)
        } else if (family == "sonnet") {
            if (major >= 5) { ri = 2.00; ro = 10.00 } else { ri = 3.00; ro = 15.00 }
            std_cache(ri)
        } else if (family == "opus") {
            if (ver >= 5.5) {
                # Opus 5.5 is CHEAPER than Opus 5, with a deeper cache-read
                # discount (0.05x). Fast mode is 2x and the cache multipliers
                # stack on the fast input price, as on Opus 5.
                if (speed == "fast") { ri = 8.00; ro = 40.00 } else { ri = 4.00; ro = 20.00 }
                std_cache(ri)
                rr = ri * 0.05                   # $0.20 read ($0.40 fast)
            } else {
                if (speed == "fast")  { ri = 10.00; ro = 50.00 }
                else if (ver >= 4.5) { ri = 5.00;  ro = 25.00 }
                else                 { ri = 15.00; ro = 75.00 }
                std_cache(ri)
            }
        } else if (family == "fable" || family == "mythos") {
            ri = 10.00; ro = 50.00
            std_cache(ri)
            if (ver >= 5.1) rr = ri * 0.025      # $0.25 cache read on 5.1
        } else {
            # Unknown/future family: Opus 5 rates. The bucket keeps the real name.
            ri = 5.00; ro = 25.00
            std_cache(ri)
        }
    }

    function cache_create_cost(cc, cc1h, cc5m) {
        if (cc1h + cc5m > 0) return cc1h*rc1h + cc5m*rc
        return cc*rc
    }

    function bucket_label(speed,    lbl) {
        lbl = FAMILY
        if (MAJOR > 0) lbl = lbl "-" MAJOR "." MINOR
        if (speed == "fast") lbl = lbl "+fast"
        return lbl
    }
'

# ---------------------------------------------------------------------------
# compute_credit_for_jsonl <path>
# Prints: input_cost<TAB>output_cost<TAB>total_cost   (all formatted %.4f)
# Prints nothing if no assistant messages / no usage data.
# ---------------------------------------------------------------------------
compute_credit_for_jsonl() {
    [ -f "${1:-}" ] || return

    _jsonl_to_tsv "$@" \
        | awk -F'\t' "$_AWK_RATE_FN"'
            BEGIN { in_cost = 0; out_cost = 0 }
            {
              ti = $1+0; cr = $2+0; cc = $3+0; to = $4+0
              cc1h = $5+0; cc5m = $6+0
              parse_model($7)
              set_rates(FAMILY, MAJOR, MINOR, $8)
              in_cost  += (ti*ri + cr*rr + cache_create_cost(cc,cc1h,cc5m)) / 1000000
              out_cost += (to*ro)                                           / 1000000
            }
            END {
              total = in_cost + out_cost
              if (total > 0)
                printf "%.4f\t%.4f\t%.4f", in_cost, out_cost, total
            }'
}

# ---------------------------------------------------------------------------
# emit_credit_rows_dated_for_jsonl <path>...
# Prints one line per deduped assistant message:
#   day<TAB>bucket<TAB>input_cost<TAB>output_cost
# day is the LOCAL calendar day the message was produced ("unknown" when the
# record carries no usable timestamp). Any report over a time window must use
# this rather than a file mtime: one session can span months, so billing its
# whole cost to the day its file was last touched is simply wrong.
# ---------------------------------------------------------------------------
emit_credit_rows_dated_for_jsonl() {
    [ -f "${1:-}" ] || return

    _jsonl_to_tsv "$@" \
        | awk -F'\t' "$_AWK_RATE_FN"'
            {
              ti = $1+0; cr = $2+0; cc = $3+0; to = $4+0
              cc1h = $5+0; cc5m = $6+0
              parse_model($7)
              set_rates(FAMILY, MAJOR, MINOR, $8)
              in_c  = (ti*ri + cr*rr + cache_create_cost(cc,cc1h,cc5m)) / 1000000
              out_c = (to*ro)                                           / 1000000
              if (in_c + out_c == 0) next
              printf "%s\t%s\t%.6f\t%.6f\n", ($9=="" ? "unknown" : $9), bucket_label($8), in_c, out_c
            }'
}

# ---------------------------------------------------------------------------
# emit_credit_rows_for_jsonl <path>
# Prints one line per deduped assistant message:
#   bucket<TAB>input_cost<TAB>output_cost
# ---------------------------------------------------------------------------
emit_credit_rows_for_jsonl() {
    [ -f "${1:-}" ] || return

    _jsonl_to_tsv "$@" \
        | awk -F'\t' "$_AWK_RATE_FN"'
            {
              ti = $1+0; cr = $2+0; cc = $3+0; to = $4+0
              cc1h = $5+0; cc5m = $6+0
              parse_model($7)
              set_rates(FAMILY, MAJOR, MINOR, $8)
              in_c  = (ti*ri + cr*rr + cache_create_cost(cc,cc1h,cc5m)) / 1000000
              out_c = (to*ro)                                           / 1000000
              if (in_c + out_c == 0) next
              printf "%s\t%.4f\t%.4f\n", bucket_label($8), in_c, out_c
            }'
}
