#!/bin/bash
# credit-summary.sh — total estimated API cost across all Claude Code sessions,
# with optional date filter and per-model breakdown.
#
# Usage:
#   credit-summary.sh                          # all sessions, all time
#   credit-summary.sh 2026-05-01               # sessions since May 1, 2026
#   credit-summary.sh 2026-05-01 ~/my-project  # since date, specific project dir
#   credit-summary.sh "" ~/my-project          # all time, specific project dir
#
# Date filtering uses file modification time (fast, no JSONL parsing needed).
#
# Output:
#   Per-session lines (session-id, cost breakdown)
#   TOTAL line
#   MODELS section (per-family breakdown sorted by spend)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=credit-lib.sh
source "${SCRIPT_DIR}/credit-lib.sh"

since_date=""
project_dir=""

# Parse args: first non-empty arg that looks like a date is since_date,
# first that looks like a path is project_dir
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            if [ -z "$since_date" ] && [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                since_date="$arg"
            elif [ -z "$project_dir" ] && [ -d "$arg" ]; then
                project_dir="$arg"
            elif [ -z "$arg" ]; then
                : # empty string = skip (allows "" placeholder)
            else
                echo "Unknown arg or not a directory: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

# Convert since_date to epoch for mtime comparison
since_epoch=0
if [ -n "$since_date" ]; then
    since_epoch=$(date -d "$since_date" +%s 2>/dev/null \
               || date -j -f "%Y-%m-%d" "$since_date" +%s 2>/dev/null)
    if [ -z "$since_epoch" ]; then
        echo "Error: cannot parse date '$since_date' (use YYYY-MM-DD)" >&2
        exit 1
    fi
fi

# Collect all .jsonl paths
jsonl_files=()

if [ -n "$project_dir" ]; then
    while IFS= read -r -d '' f; do
        jsonl_files+=("$f")
    done < <(find "$project_dir" -maxdepth 1 -name '*.jsonl' -print0 2>/dev/null | sort -z)
else
    claude_projects="${HOME}/.claude/projects"
    if [ ! -d "$claude_projects" ]; then
        echo "No projects found at: $claude_projects" >&2
        exit 1
    fi
    while IFS= read -r -d '' f; do
        jsonl_files+=("$f")
    done < <(find "$claude_projects" -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null | sort -z)
fi

if [ "${#jsonl_files[@]}" -eq 0 ]; then
    echo "No transcript files found." >&2
    exit 1
fi

# Filter by mtime if since_date given
filtered_files=()
for f in "${jsonl_files[@]}"; do
    if [ "$since_epoch" -gt 0 ]; then
        file_mtime=$(stat -c '%Y' "$f" 2>/dev/null \
                  || stat -f '%m' "$f" 2>/dev/null || echo "0")
        [ "$file_mtime" -lt "$since_epoch" ] && continue
    fi
    filtered_files+=("$f")
done

if [ "${#filtered_files[@]}" -eq 0 ]; then
    if [ -n "$since_date" ]; then
        echo "No sessions found since $since_date" >&2
    else
        echo "No transcript files found." >&2
    fi
    exit 1
fi

# Accumulate totals
grand_in=0
grand_out=0
grand_total=0
found=0
tmp_rows=$(mktemp)
trap 'rm -f "$tmp_rows"' EXIT

for jsonl in "${filtered_files[@]}"; do
    session_id="$(basename "$jsonl" .jsonl)"

    costs="$(compute_credit_for_jsonl "$jsonl")"
    if [ -n "$costs" ]; then
        s_in=$(  printf '%s' "$costs" | cut -f1)
        s_out=$( printf '%s' "$costs" | cut -f2)
        s_tot=$( printf '%s' "$costs" | cut -f3)

        # Show truncated session id for readability
        short_id="${session_id:0:12}"
        [ "${#session_id}" -gt 12 ] && short_id="${short_id}…"

        printf '%-14s $%s  (in:$%s  out:$%s)\n' \
            "$short_id" "$s_tot" "$s_in" "$s_out"

        grand_in=$(   awk -v a="$grand_in"    -v b="$s_in"  'BEGIN { printf "%.4f", a+b }')
        grand_out=$(  awk -v a="$grand_out"   -v b="$s_out" 'BEGIN { printf "%.4f", a+b }')
        grand_total=$(awk -v a="$grand_total" -v b="$s_tot" 'BEGIN { printf "%.4f", a+b }')
        found=$(( found + 1 ))

        emit_credit_rows_for_jsonl "$jsonl" >> "$tmp_rows"
    fi
done

if [ "$found" -eq 0 ]; then
    echo "No usage data found in ${#filtered_files[@]} transcript(s)." >&2
    exit 1
fi

echo ""
header="TOTAL ($found sessions"
[ -n "$since_date" ] && header="${header}, since $since_date"
header="${header})"
printf '%s\t$%s  (in:$%s  out:$%s)\n' \
    "$header" "$grand_total" "$grand_in" "$grand_out"

# Per-model breakdown
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
            n = 0
            for (b in sum_tot) order[++n] = b
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
