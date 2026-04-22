#!/bin/bash
# credit-project.sh — sum estimated API cost across all transcript .jsonl files
# in a Claude Code project directory.
#
# Usage:
#   bash ~/.claude/credit-project.sh <project-dir>
#
# Output:
#   <session-id>   $<total>  (in:$<input>  out:$<output>)
#   ...
#   TOTAL          $<grand-total>  (in:$<grand-input>  out:$<grand-output>)
#
#   MODELS:
#     opus-*     $<cost>  (NN.N%)
#     sonnet-*   $<cost>  (NN.N%)
#     haiku-*    $<cost>  (NN.N%)
#     mythos-*   $<cost>  (NN.N%)   ← future families appear automatically
#
# Known families (opus/sonnet/haiku) use their published rate cards.
# Unknown/future families fall back to Opus pricing but are labelled with their
# real family name extracted from the model id (e.g. mythos-*, polaris-*).
#
# Pricing logic is shared with the statusline via credit-lib.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credit-lib.sh
source "${SCRIPT_DIR}/credit-lib.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-dir>" >&2
    exit 1
fi

project_dir="$1"

if [ ! -d "$project_dir" ]; then
    echo "Error: directory not found: $project_dir" >&2
    exit 1
fi

grand_in=0
grand_out=0
grand_total=0
found=0

# Accumulate per-model totals in temp files (awk associative arrays don't
# survive across subshell boundaries in a while-read loop).
tmp_rows=$(mktemp)
trap 'rm -f "$tmp_rows"' EXIT

# Iterate over all .jsonl files in the project directory (non-recursive —
# Claude Code stores one .jsonl per session directly in the project dir).
while IFS= read -r -d '' jsonl; do
    session_id="$(basename "$jsonl" .jsonl)"

    # Three-field output: input_cost<TAB>output_cost<TAB>total_cost
    costs="$(compute_credit_for_jsonl "$jsonl")"
    if [ -n "$costs" ]; then
        s_in=$(  printf '%s' "$costs" | cut -f1)
        s_out=$( printf '%s' "$costs" | cut -f2)
        s_tot=$( printf '%s' "$costs" | cut -f3)

        printf '%s\t$%s  (in:$%s  out:$%s)\n' \
            "$session_id" "$s_tot" "$s_in" "$s_out"

        grand_in=$(   awk -v a="$grand_in"    -v b="$s_in"  'BEGIN { printf "%.4f", a+b }')
        grand_out=$(  awk -v a="$grand_out"   -v b="$s_out" 'BEGIN { printf "%.4f", a+b }')
        grand_total=$(awk -v a="$grand_total" -v b="$s_tot" 'BEGIN { printf "%.4f", a+b }')
        found=$(( found + 1 ))

        # Collect per-model rows for the MODELS section
        emit_credit_rows_for_jsonl "$jsonl" >> "$tmp_rows"
    fi
done < <(find "$project_dir" -maxdepth 1 -name '*.jsonl' -print0 | sort -z)

if [ "$found" -eq 0 ]; then
    echo "No transcript files found in: $project_dir" >&2
    exit 1
fi

printf 'TOTAL\t$%s  (in:$%s  out:$%s)\n' \
    "$grand_total" "$grand_in" "$grand_out"

# --- Per-model breakdown ---
# Aggregate tmp_rows (bucket\tinput_cost\toutput_cost) by bucket.
# Buckets are family names extracted by credit-lib.sh (opus / sonnet / haiku /
# mythos / polaris / … — whatever the model id contains).  We iterate all
# observed buckets sorted by total spend descending so dominant models appear
# first regardless of whether they are known or unknown families.
if [ -s "$tmp_rows" ]; then
    echo ""
    echo "MODELS:"
    awk -v grand="$grand_total" '
        {
            bucket = $1
            in_c   = $2 + 0
            out_c  = $3 + 0
            sum_in[bucket]  += in_c
            sum_out[bucket] += out_c
            sum_tot[bucket] += in_c + out_c
        }
        END {
            # Collect all observed buckets into an array, then sort by total
            # spend descending using a simple insertion sort (N is tiny).
            n = 0
            for (b in sum_tot) {
                order[++n] = b
            }
            # Insertion sort: descending by sum_tot
            for (i = 2; i <= n; i++) {
                key = order[i]
                j = i - 1
                while (j >= 1 && sum_tot[order[j]] < sum_tot[key]) {
                    order[j+1] = order[j]
                    j--
                }
                order[j+1] = key
            }
            for (i = 1; i <= n; i++) {
                b   = order[i]
                tot = sum_tot[b]
                if (tot <= 0) continue
                pct   = (grand > 0) ? (tot / grand * 100) : 0
                label = b "-*"
                printf "  %-14s $%8.4f  (in:$%.4f  out:$%.4f  %.1f%%)\n", \
                    label, tot, sum_in[b], sum_out[b], pct
            }
        }
    ' "$tmp_rows"
fi
