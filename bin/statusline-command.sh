#!/bin/bash
# statusline-command.sh — Claude Code statusline with ANSI colors, multi-line
# layout, rate limit bars, burn-rate projection, session cost, and backup integration.
#
# Output (3-5 lines):
#   Line 1: Model (effort) [no-think] | 219k/1m (22% used) | 748k 74% free
#   Line 2: ctx: ●●●○… cache 78% | fill: tool out 33% · attached 29% · ...
#   Line 3: 5h: ●●●●○○○○ 43% ->cap 1h12m | 7d: ●●○○○○○○ 22%
#   Line 4: resets 5:00pm (3h16m) | resets Tue, 5:35pm (3d2h) | $19.34 | 2h45m | +1739/-223
#   Line 5: (conditional) -> .claude/backups/3-backup-2026-06-02.md
#
# The 'fill:' segment on line 2 appears only once its node-written cache exists;
# 'cache NN%' shows the prompt-cache hit-rate. The '->cap Xh Ym' marker on a rate
# bar appears only when the current burn rate is on track to hit that window's
# limit before it resets. The weekly reset carries a countdown so its true
# distance is visible (the window resets at an account-assigned fixed time).
#
# Effort is read from the live stdin (.effort.level, authoritative for mid-session
# /effort changes) and falls back to settings.json on older Claude Code. The
# 'no-think' badge appears only in its non-default state. The cost headline uses
# the native .cost.total_cost_usd when present (no transcript scan); only older
# Claude Code without that field falls back to the JSONL estimate (with a dim
# in/out split). +added/-removed comes from .cost.total_lines_*; the session
# duration from .cost.total_duration_ms. The 'ctx fill' line is fed by a
# node-written cache (see context-lib.sh).
#
# Configuration in settings.json:
#   { "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" } }

# shellcheck source=credit-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/credit-lib.sh"
# shellcheck source=display-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/display-lib.sh"
# shellcheck source=context-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/context-lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=$(cat)

# ============================================================================
# EXTRACT FIELDS
# ============================================================================

model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
# SECURITY: model name is printed to the terminal; strip C0/C1 control bytes
# (incl. ESC 0x1b) so a crafted display_name can't perform terminal injection
# (cursor moves, OSC clipboard writes, hyperlink spoofing).
model=$(printf '%s' "$model" | tr -d '\000-\037\177')

# Effort level — prefer live stdin (.effort.level, authoritative for mid-session
# /effort changes), fall back to settings.json for older Claude Code versions.
effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
if [ -z "$effort" ]; then
    _claude_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
    effort=$(jq -r '.effortLevel // empty' "${_claude_dir}/settings.json" 2>/dev/null)
fi
# SECURITY: effort is printed (the label is shown raw for unknown levels); strip
# C0/C1 control bytes so a crafted effort.level can't inject terminal escapes.
effort=$(printf '%s' "$effort" | tr -d '\000-\037\177')
case "$effort" in
    "")     think_label=""        ;;  # absent: hide field
    medium) think_label="med"     ;;  # abbreviate
    *)      think_label="$effort" ;;  # low/high/xhigh/max + any new level shown raw
esac

# Fast mode / thinking state — booleans need an explicit null test (a plain
# `// empty` would swallow a real `false`). Yields: true / false / unset.
fast_mode=$(echo "$input" | jq -r 'if .fast_mode==null then "unset" else (.fast_mode|tostring) end' 2>/dev/null)
thinking_enabled=$(echo "$input" | jq -r 'if .thinking.enabled==null then "unset" else (.thinking.enabled|tostring) end' 2>/dev/null)

# Context window — prefer current_usage for precision, fall back to top-level.
# SECURITY: every value that feeds bash arithmetic `$(( ))` below is forced to a
# real integer at the jq boundary. Without this, a stdin field carrying a JSON
# string like "a[$(cmd)]" would be evaluated by bash arithmetic as a command
# substitution (RCE). `if type=="number" then floor else 0 end` guarantees only
# digits reach `$(( ))`.
_int() { echo "$input" | jq -r "(${1}) // 0 | if type==\"number\" then floor else 0 end" 2>/dev/null; }
window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000 | if type=="number" and . > 0 then floor else 200000 end' 2>/dev/null)
input_tokens=$(_int '.context_window.current_usage.input_tokens')
cache_read=$(_int '.context_window.current_usage.cache_read_input_tokens')
cache_create=$(_int '.context_window.current_usage.cache_creation_input_tokens')
output_tokens=$(_int '.context_window.current_usage.output_tokens')
used_pct_raw=$(echo "$input" | jq -r '.context_window.used_percentage // empty | if type=="number" then . else empty end' 2>/dev/null)
[ -z "$window_size" ] && window_size=200000

current_input=$(( input_tokens + cache_read + cache_create ))
current_total=$(( current_input + output_tokens ))

# Percentage used — prefer stdin's own used_percentage (matches Claude Code's UI
# exactly), fall back to manual calc from token counts for older CC.
if [ -n "$used_pct_raw" ]; then
    pct_used=$(printf '%.0f' "$used_pct_raw")
elif [ "$current_total" -gt 0 ] 2>/dev/null; then
    pct_used=$(awk -v t="$current_input" -v w="$window_size" 'BEGIN { printf "%d", (t/w)*100 }')
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
# Numeric-or-empty for all of these; resets_at also flows into `$(( epoch - now ))`.
five_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty | if type=="number" and . >= 0 and . <= 100 then . else empty end' 2>/dev/null)
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty | if type=="number" then floor else empty end' 2>/dev/null)
week_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty | if type=="number" and . >= 0 and . <= 100 then . else empty end' 2>/dev/null)
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty | if type=="number" then floor else empty end' 2>/dev/null)

# NOTE: there is no per-model (sonnet/opus) quota on the statusline stdin. The
# documented rate_limits object has exactly two children — five_hour and
# seven_day. A per-model weekly bucket exists only on the undocumented authed
# OAuth usage endpoint, out of scope for a pure-stdin, never-break statusline.

# DEBUG (opt-in, off by default): when the marker file exists, append a snapshot
# of the live rate_limits to a log — but only when a reset target (resets_at)
# changes, so the log stays tiny and shows exactly when/where each window resets.
# This is the ground truth for diagnosing the real weekly-reset cadence. Touch
# the marker to enable, rm it to stop. Wrapped so it can never break the render.
_rl_cfg="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
if [ -f "${_rl_cfg}/.statusline-debug-ratelimits" ]; then
    {
        _rl_sig="${five_reset:-NA}:${week_reset:-NA}"
        _rl_sig_file="${_rl_cfg}/.statusline-ratelimits.sig"
        _rl_last=$(cat "$_rl_sig_file" 2>/dev/null || true)
        if [ "$_rl_sig" != "$_rl_last" ]; then
            _rl_raw=$(echo "$input" | jq -c '.rate_limits // {}' 2>/dev/null)
            _rl_5dec=$([ -n "$five_reset" ] && fmt_reset_friendly "$five_reset" "datetime")
            _rl_7dec=$([ -n "$week_reset" ] && fmt_reset_friendly "$week_reset" "datetime")
            printf '%s\t5h=%s%% resets@%s (%s)\t7d=%s%% resets@%s (%s)\traw=%s\n' \
                "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
                "${five_pct:-NA}" "${five_reset:-NA}" "${_rl_5dec:-NA}" \
                "${week_pct:-NA}" "${week_reset:-NA}" "${_rl_7dec:-NA}" \
                "${_rl_raw:-NA}" >> "${_rl_cfg}/statusline-ratelimits.log"
            printf '%s' "$_rl_sig" > "$_rl_sig_file"
        fi
    } 2>/dev/null
fi

# Session info
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input"      | jq -r '.session_id      // empty')
# SECURITY: session_id is used to build cache/state/lock file paths; strip every
# character outside [A-Za-z0-9-] so it can never traverse directories or inject.
session_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')
[ "$session_id" = "_" ] && session_id=""

# ============================================================================
# LINE 1: Model | tokens (% used) | free tokens, % free
# ============================================================================

model_display="${C_BLUE}${model}${C_RESET}"
[ -n "$think_label" ] && model_display="${model_display} ${C_DIM}(${think_label})${C_RESET}"
# fast mode: surface only the non-default (true) state
[ "$fast_mode" = "true" ] && model_display="${model_display} ${C_YELLOW}fast${C_RESET}"
# thinking: surface only the off state (the effort badge already implies thinking on)
[ "$thinking_enabled" = "false" ] && model_display="${model_display} ${C_DIM}no-think${C_RESET}"
# output style: surface only when non-default (control bytes stripped, it is printed)
out_style=$(echo "$input" | jq -r '.output_style.name // empty' 2>/dev/null | tr -d '\000-\037\177')
[ -n "$out_style" ] && [ "$out_style" != "default" ] && model_display="${model_display} ${C_DIM}${out_style}${C_RESET}"

used_str=$(format_tokens "$current_input")
total_str=$(format_tokens "$window_size")
free_str=$(format_tokens "$free_tokens")

tokens_display="${C_ORANGE}${used_str}/${total_str}${C_RESET} ${C_GREEN}(${pct_used}% used)${C_RESET}"
free_display="${C_ORANGE}${free_str}${C_RESET} ${C_BLUE}${free_pct}% free${C_RESET}"

line1="${model_display}${C_SEP}${tokens_display}${C_SEP}${free_display}"

# ============================================================================
# LINE 2: Rate limit bars + burn-rate projection
#
# Each bar may carry a "->cap Xh Ym" marker: the projected time until the window
# hits 100% at the current burn rate, shown ONLY when that is sooner than the
# window resets (i.e. you are on track to be capped before relief). When you are
# not on track to hit the cap, no marker shows — the bar stays clean.
# ============================================================================

line2=""
line2_parts=()

# 5-hour bar (rolling 5h window = 18000s)
if [ -n "$five_pct" ]; then
    five_int=$(printf '%.0f' "$five_pct")
    five_bar=$(build_bar "$five_int" 10)
    five_seg="${C_WHITE}5h:${C_RESET} ${five_bar} ${C_GREEN}${five_int}%${C_RESET}"
    if [ -n "$five_reset" ]; then
        five_cap=$(project_cap "$five_pct" "$five_reset" 18000)
        [ -n "$five_cap" ] && five_seg="${five_seg} ${C_RED}->cap ${five_cap}${C_RESET}"
    fi
    line2_parts+=("$five_seg")
fi

# 7-day bar (weekly window = 604800s)
if [ -n "$week_pct" ]; then
    week_int=$(printf '%.0f' "$week_pct")
    week_bar=$(build_bar "$week_int" 10)
    week_seg="${C_WHITE}7d:${C_RESET} ${week_bar} ${C_GREEN}${week_int}%${C_RESET}"
    if [ -n "$week_reset" ]; then
        week_cap=$(project_cap "$week_pct" "$week_reset" 604800)
        [ -n "$week_cap" ] && week_seg="${week_seg} ${C_RED}->cap ${week_cap}${C_RESET}"
    fi
    line2_parts+=("$week_seg")
fi

# Join line2 parts with separator
for (( i=0; i<${#line2_parts[@]}; i++ )); do
    [ "$i" -gt 0 ] && line2="${line2}${C_SEP}"
    line2="${line2}${line2_parts[$i]}"
done

# ============================================================================
# CONTEXT LINE (emitted as line 2): the 16-char context bar plus the per-category
# "fill" breakdown of what is eating the window. The bar always shows; the
# breakdown ("fill:") is appended only when its node-written cache exists.
# ============================================================================
ctx_bar=$(build_bar "$pct_used" 16)
ctx_line="${C_WHITE}ctx:${C_RESET} ${ctx_bar}"

# Cache hit-rate: share of the current input that was served from the prompt
# cache (cache_read / all input tokens). High cache reuse = lower cost; this is a
# cheap, high-signal number from tokens we already extracted. Hidden when there
# is no input yet (e.g. right after /compact, current_usage is null -> all zero).
cache_total=$(( input_tokens + cache_read + cache_create ))
if [ "$cache_total" -gt 0 ]; then
    cache_pct=$(awk -v r="$cache_read" -v t="$cache_total" 'BEGIN { printf "%d", (r/t)*100 }')
    [[ "$cache_pct" =~ ^[0-9]+$ ]] && ctx_line="${ctx_line} ${C_DIM}cache${C_RESET} ${C_CYAN}${cache_pct}%${C_RESET}"
fi

if [ -n "$session_id" ] && [ -n "$transcript_path" ]; then
    ctx_break=$(get_context_breakdown "$session_id" "$transcript_path")
    [ -n "$ctx_break" ] && ctx_line="${ctx_line}${C_SEP}${C_WHITE}fill:${C_RESET} ${ctx_break}"
fi

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

# Session cost. The headline is Claude Code's authoritative cost.total_cost_usd.
# When it is present (modern CC) we do NOT scan the transcript at all — scanning a
# multi-hundred-MB JSONL on every ~300ms statusline render would be a DoS on long
# sessions, and the mtime cache misses every turn while the session is active.
# The per-side in/out split and per-model breakdown remain available offline via
# credit-summary.sh / credit-project.sh. Only older Claude Code that lacks the
# cost field falls back to the (cached) JSONL estimate here.
native_cost=$(echo "$input" | jq -r 'if (.cost.total_cost_usd|type)=="number" then .cost.total_cost_usd else empty end' 2>/dev/null)
credit_str=""
if [ -n "$native_cost" ]; then
    native_fmt=$(printf '%.2f' "$native_cost" 2>/dev/null) || native_fmt=""
    [ -n "$native_fmt" ] && credit_str="${C_CYAN}\$${native_fmt}${C_RESET}"
elif [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -n "$session_id" ]; then
    # Older CC (no cost field): estimate from the transcript JSONL, cached on mtime.
    _cache_base="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"
    mkdir -p -m 0700 "$_cache_base" 2>/dev/null
    cache_file="${_cache_base}/credit-${session_id}.cache"
    cur_mtime=$(stat -c '%Y' "$transcript_path" 2>/dev/null \
             || stat -f '%m' "$transcript_path" 2>/dev/null || echo "0")
    _in=""; _out=""; _tot=""

    if [ -f "$cache_file" ]; then
        cached_mtime=$(cut -d' ' -f1 "$cache_file")
        cached_credit=$(cut -d' ' -f2- "$cache_file")
        if [ "$cached_mtime" = "$cur_mtime" ] && [ -n "$cached_credit" ]; then
            _in=$(  printf '%s' "$cached_credit" | cut -f1)
            _out=$( printf '%s' "$cached_credit" | cut -f2)
            _tot=$( printf '%s' "$cached_credit" | cut -f3)
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
        fi
    fi

    [ -n "$_tot" ] && credit_str="${C_CYAN}\$${_tot}${C_RESET} ${C_DIM}(in:\$${_in} out:\$${_out})${C_RESET}"
fi

[ -n "$credit_str" ] && line3_parts+=("$credit_str")

# Cost burn rate + session duration, both from the .cost object.
dur_ms=$(echo "$input" | jq -r 'if (.cost.total_duration_ms|type)=="number" then (.cost.total_duration_ms|floor) else empty end' 2>/dev/null)
# Numeric session cost: the native total when present, else the JSONL-estimate total.
cost_num="${native_cost:-${_tot:-}}"

# Burn rate ($/hr): total cost over wall-clock session time. Hidden unless both
# the cost and a positive duration are known. awk does the float division.
if [ -n "$cost_num" ] && [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
    rate_str=$(awk -v c="$cost_num" -v ms="$dur_ms" 'BEGIN {
        if (ms <= 0) exit
        r = c * 3600000.0 / ms
        if (r < 0) exit
        printf "%.2f", r
    }')
    [ -n "$rate_str" ] && line3_parts+=("${C_DIM}\$${rate_str}/h${C_RESET}")
fi

# Session wall-clock duration (cost.total_duration_ms; current schema). Cheap,
# always-present alongside the cost object. Absent -> hidden.
if [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
    dur_str=$(fmt_duration_ms "$dur_ms")
    [ -n "$dur_str" ] && line3_parts+=("${C_DIM}${dur_str}${C_RESET}")
fi

# Lines added/removed this session (new schema; cheap top-level fields)
lines_added=$(echo "$input"   | jq -r 'if (.cost.total_lines_added|type)=="number"   then (.cost.total_lines_added|floor)   else empty end' 2>/dev/null)
lines_removed=$(echo "$input" | jq -r 'if (.cost.total_lines_removed|type)=="number" then (.cost.total_lines_removed|floor) else empty end' 2>/dev/null)
if [ -n "$lines_added" ] && [ -n "$lines_removed" ] \
   && { [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; } 2>/dev/null; then
    line3_parts+=("${C_GREEN}+${lines_added}${C_RESET}${C_DIM}/${C_RESET}${C_RED}-${lines_removed}${C_RESET}")
fi

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
[ -n "$ctx_line" ] && printf '\n%s' "$ctx_line"
[ -n "$line2" ]    && printf '\n%s' "$line2"
[ -n "$line3" ]    && printf '\n%s' "$line3"
[ -n "$line4" ]    && printf '\n%s' "$line4"

exit 0
