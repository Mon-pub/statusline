#!/bin/bash
# statusline-command.sh — Claude Code statusline with ANSI colors, multi-line
# layout, rate limit bars, session cost, peak/off-peak, and backup integration.
#
# Output (3-4 lines):
#   Line 1: Model (think) | 50k/200k (25% used) | 117k 42% free
#   Line 2: 5h: ●●●●○○○○ 43% | 7d: ●●○○○○○○ 22% | sonnet:15% | Off-peak (4h12m)
#   Line 3: resets 5:00pm (3h16m) | resets Thu, 7:00pm | $1.2473 (in:$0.31 out:$0.94)
#   Line 4: (conditional) -> .claude/backups/3-backup-18th-May-2026.md
#
# Configuration in settings.json:
#   { "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" } }

# shellcheck source=credit-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/credit-lib.sh"
# shellcheck source=display-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/display-lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# ============================================================================
# EXTRACT FIELDS
# ============================================================================

model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')

# Thinking level from settings.json
_claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
effort=$(jq -r '.effortLevel // empty' "${_claude_dir}/settings.json" 2>/dev/null)
case "$effort" in
    low)    think_label="low"   ;;
    medium) think_label="med"   ;;
    high)   think_label="high"  ;;
    xhigh)  think_label="xhigh" ;;
    max)    think_label="max"   ;;
    *)      think_label=""      ;;
esac

# Context window — prefer current_usage for precision, fall back to top-level
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
output_tokens=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')
used_pct_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

current_input=$(( input_tokens + cache_read + cache_create ))
current_total=$(( current_input + output_tokens ))

# Percentage used (prefer manual calculation when token counts available)
if [ "$current_total" -gt 0 ] 2>/dev/null; then
    pct_used=$(awk -v t="$current_input" -v w="$window_size" 'BEGIN { printf "%d", (t/w)*100 }')
elif [ -n "$used_pct_raw" ]; then
    pct_used=$(printf '%.0f' "$used_pct_raw")
else
    pct_used=0
fi

# Free tokens until autocompact (33k buffer)
AUTOCOMPACT_BUFFER=33000
free_tokens=$(( window_size - current_total - AUTOCOMPACT_BUFFER ))
[ "$free_tokens" -lt 0 ] && free_tokens=0
free_pct=$(awk -v f="$free_tokens" -v w="$window_size" 'BEGIN {
    p = (f/w)*100; if (p<0) p=0; printf "%d", p
}')

# Rate limits
five_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at       // empty')
week_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at       // empty')

sonnet_pct=$(echo "$input" | jq -r '
    .rate_limits.sonnet.used_percentage          //
    .rate_limits.models.sonnet.used_percentage   //
    .rate_limits.sonnet_used_percentage          //
    .rate_limits.sonnet                          //
    empty' 2>/dev/null)

# Session info
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input"      | jq -r '.session_id      // empty')

# ============================================================================
# LINE 1: Model | tokens (% used) | free tokens, % free
# ============================================================================

if [ -n "$think_label" ]; then
    model_display="${C_BLUE}${model}${C_RESET} ${C_DIM}(${think_label})${C_RESET}"
else
    model_display="${C_BLUE}${model}${C_RESET}"
fi

used_str=$(format_tokens "$current_input")
total_str=$(format_tokens "$window_size")
free_str=$(format_tokens "$free_tokens")

tokens_display="${C_ORANGE}${used_str}/${total_str}${C_RESET} ${C_GREEN}(${pct_used}% used)${C_RESET}"
free_display="${C_ORANGE}${free_str}${C_RESET} ${C_BLUE}${free_pct}% free${C_RESET}"

line1="${model_display}${C_SEP}${tokens_display}${C_SEP}${free_display}"

# ============================================================================
# LINE 2: Rate limit bars + peak indicator
# ============================================================================

line2=""
line2_parts=()

# 5-hour bar
if [ -n "$five_pct" ]; then
    five_int=$(printf '%.0f' "$five_pct")
    five_bar=$(build_bar "$five_int" 10)
    line2_parts+=("${C_WHITE}5h:${C_RESET} ${five_bar} ${C_GREEN}${five_int}%${C_RESET}")
fi

# 7-day bar
if [ -n "$week_pct" ]; then
    week_int=$(printf '%.0f' "$week_pct")
    week_bar=$(build_bar "$week_int" 10)
    line2_parts+=("${C_WHITE}7d:${C_RESET} ${week_bar} ${C_GREEN}${week_int}%${C_RESET}")
fi

# Sonnet rate limit (no bar, just percentage)
if [ -n "$sonnet_pct" ]; then
    sonnet_int=$(printf '%.0f' "$sonnet_pct")
    line2_parts+=("${C_WHITE}sonnet:${C_RESET}${C_CYAN}${sonnet_int}%${C_RESET}")
fi

# Context bar (16-char, colored)
ctx_bar=$(build_bar "$pct_used" 16)
line2_parts+=("${C_WHITE}ctx:${C_RESET} ${ctx_bar}")

# Peak/Off-peak
peak_output=$(get_peak_status)
peak_label="${peak_output%% *}"
peak_countdown="${peak_output#* }"
if [ "$peak_label" = "PEAK" ]; then
    peak_display="${C_RED}Peak${C_RESET} ${C_WHITE}(${peak_countdown})${C_RESET}"
else
    peak_display="${C_GREEN}Off-peak${C_RESET} ${C_WHITE}(${peak_countdown})${C_RESET}"
fi
line2_parts+=("$peak_display")

# Join line2 parts with separator
for (( i=0; i<${#line2_parts[@]}; i++ )); do
    [ "$i" -gt 0 ] && line2="${line2}${C_SEP}"
    line2="${line2}${line2_parts[$i]}"
done

# ============================================================================
# LINE 3: Reset times + session cost
# ============================================================================

line3=""
line3_parts=()

# 5-hour reset
if [ -n "$five_reset" ] && [ -n "$five_pct" ]; then
    five_reset_str=$(fmt_reset_friendly "$five_reset" "time")
    [ -n "$five_reset_str" ] && line3_parts+=("${C_WHITE}resets ${five_reset_str}${C_RESET}")
fi

# 7-day reset
if [ -n "$week_reset" ] && [ -n "$week_pct" ]; then
    week_reset_str=$(fmt_reset_friendly "$week_reset" "datetime")
    [ -n "$week_reset_str" ] && line3_parts+=("${C_WHITE}resets ${week_reset_str}${C_RESET}")
fi

# Session cost (from transcript JSONL)
credit_str=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -n "$session_id" ]; then
    _cache_base="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"
    mkdir -p -m 0700 "$_cache_base" 2>/dev/null
    cache_file="${_cache_base}/credit-${session_id}.cache"
    cur_mtime=$(stat -c '%Y' "$transcript_path" 2>/dev/null \
             || stat -f '%m' "$transcript_path" 2>/dev/null || echo "0")

    if [ -f "$cache_file" ]; then
        cached_mtime=$(cut -d' ' -f1 "$cache_file")
        cached_credit=$(cut -d' ' -f2- "$cache_file")
        if [ "$cached_mtime" = "$cur_mtime" ] && [ -n "$cached_credit" ]; then
            _in=$(  printf '%s' "$cached_credit" | cut -f1)
            _out=$( printf '%s' "$cached_credit" | cut -f2)
            _tot=$( printf '%s' "$cached_credit" | cut -f3)
            credit_str="${C_CYAN}\$${_tot}${C_RESET} ${C_DIM}(in:\$${_in} out:\$${_out})${C_RESET}"
            cur_mtime=""
        fi
    fi

    if [ -n "$cur_mtime" ]; then
        credit=$(compute_credit_for_jsonl "$transcript_path")
        if [ -n "$credit" ]; then
            printf '%s %s\n' "$cur_mtime" "$credit" > "$cache_file"
            _in=$(  printf '%s' "$credit" | cut -f1)
            _out=$( printf '%s' "$credit" | cut -f2)
            _tot=$( printf '%s' "$credit" | cut -f3)
            credit_str="${C_CYAN}\$${_tot}${C_RESET} ${C_DIM}(in:\$${_in} out:\$${_out})${C_RESET}"
        fi
    fi
else
    # Fallback: live cumulative counts (fresh sessions)
    total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens  // 0')
    total_out=$(echo "$input"| jq -r '.context_window.total_output_tokens // 0')
    total_tokens=$(( total_in + total_out ))
    if [ "$total_tokens" -gt 0 ]; then
        read -r _in _out _tot < <(awk -v ti="$total_in" -v to="$total_out" \
            'BEGIN {
                in_c  = ti * 15.00 / 1000000
                out_c = to * 75.00 / 1000000
                printf "%.4f\t%.4f\t%.4f", in_c, out_c, in_c+out_c
            }')
        credit_str="${C_CYAN}\$${_tot}${C_RESET} ${C_DIM}(in:\$${_in} out:\$${_out})${C_RESET}"
    fi
fi

[ -n "$credit_str" ] && line3_parts+=("$credit_str")

# Join line3 parts with separator
for (( i=0; i<${#line3_parts[@]}; i++ )); do
    [ "$i" -gt 0 ] && line3="${line3}${C_SEP}"
    line3="${line3}${line3_parts[$i]}"
done

# ============================================================================
# LINE 4: Backup path (conditional)
# ============================================================================

line4=""
if [ -n "$session_id" ] && [ -n "$SCRIPT_DIR" ]; then
    # Source backup-bridge if it exists
    _bridge="${SCRIPT_DIR}/backup-bridge.sh"
    if [ -f "$_bridge" ]; then
        # shellcheck source=backup-bridge.sh
        source "$_bridge"
        backup_path=$(get_backup_path "$session_id")
        if [ -n "$backup_path" ]; then
            line4="${C_YELLOW}->${C_RESET} ${C_RED}${backup_path}${C_RESET}"
        fi

        # Trigger backup check in background (node)
        maybe_trigger_backup "$session_id" "$free_pct" "$current_total" "$transcript_path" &
        disown 2>/dev/null || true
    fi
fi

# ============================================================================
# OUTPUT
# ============================================================================

printf '%s' "$line1"
[ -n "$line2" ] && printf '\n%s' "$line2"
[ -n "$line3" ] && printf '\n%s' "$line3"
[ -n "$line4" ] && printf '\n%s' "$line4"

exit 0
