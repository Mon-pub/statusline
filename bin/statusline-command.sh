#!/bin/bash
# statusline-command.sh — Claude Code statusline with ANSI colors, multi-line
# layout, rate limit bars, burn-rate projection, prompt-cache state, session
# cost, and backup integration.
#
# Output (up to 5 lines; fill and backup lines are each conditional):
#   Line 1: Model (effort) [fast] [no-think] | 219k/1m (22% used) | 748k 74% free | git: main #12
#   Line 2: ctx: ●●●○… cache 78% · warm 42m | 5h: ●●●●○○○○ 43% ->cap 1h12m (Tue 14:30) | 7d: ●●○○○○○○ 22%
#   Line 3: fill: tool out 33% · attached 29% · chat In+Out 21% · tool cmd 16% | 7d Fable: ●●○○○○○○○○ 22%
#   Line 4: resets 5:00pm (3h16m) | resets Tue, 5:35pm (3d2h) | $19.34 | $7.03/h | 2h45m | +1739/-223
#
# The "7d Fable" bar is the per-model weekly cap that /usage lists as "Current
# week (Fable)". It is not on the statusline stdin, so usage-lib.sh fetches it
# in the background from the OAuth usage endpoint (cached; STATUSLINE_USAGE_API=0
# turns it off). It sits on the fill line because line 2 is already the widest.
#   Line 5: (conditional) -> .claude/backups/3-backup-2026-06-02.md
#
# All stdin fields are extracted in ONE jq pass (see EXTRACT FIELDS). Every
# value that later reaches bash arithmetic is coerced to an integer/number
# inside jq; every value that is printed has C0/C1 control bytes stripped
# inside jq. Nothing from stdin is ever eval'd or expanded unquoted.
#
# Configuration in settings.json (install.sh writes this):
#   { "statusLine": { "type": "command",
#                     "command": "bash ~/.claude/statusline-command.sh",
#                     "refreshInterval": 60 } }
# refreshInterval keeps the countdowns (resets, cache TTL, ->cap) ticking while
# the session is idle; without it the line only re-renders on events.

# shellcheck source=credit-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/credit-lib.sh"
# shellcheck source=display-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/display-lib.sh"
# shellcheck source=context-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/context-lib.sh"
# shellcheck source=usage-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/usage-lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CACHE_BASE="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"

input=$(cat)
now=$(date +%s)

# ============================================================================
# EXTRACT FIELDS — one jq invocation, one value per output line.
#
# SECURITY: this is the trust boundary. `clean` strips C0/C1 controls (incl.
# ESC) from anything printed so a crafted display_name / effort / branch can't
# inject terminal escapes (cursor moves, OSC clipboard writes, hyperlink
# spoofing). `int0`/`intb`/`numb`/`pctb` guarantee only digits reach `$(( ))`
# — a JSON string like "a[$(cmd)]" in a numeric slot becomes 0 or "".
# Absent values are emitted as "" (never `empty`, which would shift indices).
# ============================================================================
mapfile -t F < <(printf '%s' "$input" | jq -r '
    def clean: if type=="string"
               then (explode | map(select(. > 31 and . != 127 and (. < 128 or . > 159))) | implode)
               else "" end;
    def int0:  if type=="number" then floor else 0 end;
    def intb:  if type=="number" then floor else "" end;
    def numb:  if type=="number" then . else "" end;
    def pctb:  if type=="number" and . >= 0 and . <= 100 then . else "" end;
    def bool3: if type=="boolean" then tostring else "unset" end;
    def ident: if type=="string" then gsub("[^A-Za-z0-9-]"; "_") else "" end;
    [
      (.model.display_name // "Unknown" | clean),                       # 0
      (.model.id // "" | clean),                                         # 1
      (.effort.level // "" | clean),                                     # 2
      (.fast_mode | bool3),                                              # 3
      (.thinking.enabled | bool3),                                       # 4
      (.output_style.name // "" | clean),                                # 5
      (.context_window.context_window_size
         | if type=="number" and . > 0 then floor else 200000 end),      # 6
      (.context_window.current_usage.input_tokens | int0),               # 7
      (.context_window.current_usage.cache_read_input_tokens | int0),    # 8
      (.context_window.current_usage.cache_creation_input_tokens | int0),# 9
      (.context_window.current_usage.output_tokens | int0),              # 10
      (.context_window.used_percentage | numb),                          # 11
      (.rate_limits.five_hour.used_percentage | pctb),                   # 12
      (.rate_limits.five_hour.resets_at | intb),                         # 13
      (.rate_limits.seven_day.used_percentage | pctb),                   # 14
      (.rate_limits.seven_day.resets_at | intb),                         # 15
      (.rate_limits.spend_limit.used_percentage
         | if type=="number" and . >= 0 then . else "" end),             # 16 (may exceed 100)
      (.rate_limits.spend_limit.resets_at | intb),                       # 17
      (.transcript_path // "" | clean),                                  # 18
      (.session_id | ident),                                             # 19
      (.cost.total_cost_usd | numb),                                     # 20
      (.cost.total_duration_ms | intb),                                  # 21
      (.cost.total_lines_added | intb),                                  # 22
      (.cost.total_lines_removed | intb),                                # 23
      (.prompt_cache.warm | bool3),                                      # 24
      (.prompt_cache.caching_observed | bool3),                          # 25
      (.prompt_cache.ttl // "" | clean),                                 # 26
      (.prompt_cache.expires_at | intb),                                 # 27
      (.workspace.project_dir // .cwd // "" | clean),                    # 28
      (.workspace.current_dir // .cwd // "" | clean),                    # 29
      (.pr.number | intb),                                               # 30
      ((.worktree.name // .workspace.git_worktree // "") | clean),       # 31
      (.agent.name // "" | clean),                                       # 32
      (.version // "" | clean),                                          # 33
      (if .effort == null then "0" else "1" end),                        # 34
      (.rate_limits.spend_limit.used_usd
         | if type=="number" and . >= 0 then . else "" end),             # 35 (CC 2.1.284+)
      (.rate_limits.spend_limit.limit_usd
         | if type=="number" and . > 0 then . else "" end),              # 36
      (.rate_limits.spend_limit.period // "" | ident)                    # 37
    ] | .[]' 2>/dev/null)

model="${F[0]:-Unknown}";     model_id="${F[1]}";        effort="${F[2]}"
fast_mode="${F[3]}";          thinking_enabled="${F[4]}"; out_style="${F[5]}"
window_size="${F[6]:-200000}"
input_tokens="${F[7]:-0}";    cache_read="${F[8]:-0}"
cache_create="${F[9]:-0}";    output_tokens="${F[10]:-0}"
used_pct_raw="${F[11]}"
five_pct="${F[12]}";          five_reset="${F[13]}"
week_pct="${F[14]}";          week_reset="${F[15]}"
spend_pct="${F[16]}";         spend_reset="${F[17]}"
transcript_path="${F[18]}";   session_id="${F[19]}"
native_cost="${F[20]}";       dur_ms="${F[21]}"
lines_added="${F[22]}";       lines_removed="${F[23]}"
pc_warm="${F[24]}";           pc_observed="${F[25]}"
pc_ttl="${F[26]}";            pc_expires="${F[27]}"
project_dir="${F[28]}";       current_dir="${F[29]}"
pr_number="${F[30]}";         worktree_name="${F[31]}"
agent_name="${F[32]}";        cc_version="${F[33]}";      has_effort_key="${F[34]:-0}"
spend_used_usd="${F[35]}";    spend_limit_usd="${F[36]}"; spend_period="${F[37]}"

# Defense in depth: even though jq coerced these, re-assert the integer shape
# before any `$(( ))` so a jq failure (empty F array) can't leak a raw string.
for _v in window_size input_tokens cache_read cache_create output_tokens; do
    [[ "${!_v}" =~ ^[0-9]+$ ]] || printf -v "$_v" '%s' 0
done
[ "$window_size" -gt 0 ] || window_size=200000

# Effort: stdin is authoritative. Since CC 2.1.160 the key is present whenever the
# model supports effort, and ABSENT when the model does not — so falling back to
# settings.json would paint a badge the model can't honour. Only fall back on
# older Claude Code that never emitted the key at all.
if [ -z "$effort" ] && [ "$has_effort_key" = "0" ] && ! version_at_least "$cc_version" 2.1.160; then
    effort=$(jq -r --arg m "$model_id" \
        '(.modelSettings[$m].effortLevel // .effortLevel // "") | if type=="string" then . else "" end' \
        "${CLAUDE_DIR}/settings.json" 2>/dev/null | tr -d '\000-\037\177')
fi
case "$effort" in
    "")     think_label=""        ;;  # absent: hide field
    medium) think_label="med"     ;;  # abbreviate
    *)      think_label="$effort" ;;  # low/high/xhigh/max + any new level shown raw
esac

current_input=$(( input_tokens + cache_read + cache_create ))
current_total=$(( current_input + output_tokens ))

# Percentage used — prefer stdin's own used_percentage (matches Claude Code's UI
# exactly; it is input-only by definition), fall back to the same input-only
# formula from token counts for older CC.
if [ -n "$used_pct_raw" ]; then
    pct_used=$(printf '%.0f' "$used_pct_raw")
elif [ "$current_input" -gt 0 ]; then
    pct_used=$(awk -v t="$current_input" -v w="$window_size" 'BEGIN { printf "%d", (t/w)*100 }')
else
    pct_used=0
fi

# Free tokens until autocompact. Claude Code compacts ~33k tokens before the
# window edge (1M windows compact at about 967k — CHANGELOG 2.1.243), so the
# usable space is window − live tokens − that buffer.
AUTOCOMPACT_BUFFER=33000
free_tokens=$(( window_size - current_total - AUTOCOMPACT_BUFFER ))
[ "$free_tokens" -lt 0 ] && free_tokens=0
free_pct=$(awk -v f="$free_tokens" -v w="$window_size" 'BEGIN {
    p = (f/w)*100; if (p<0) p=0; printf "%d", p
}')

# NOTE: there is no per-model (sonnet/opus) quota on the statusline stdin. The
# documented rate_limits object has five_hour, seven_day and (behind a Claude
# apps gateway) spend_limit. A per-model weekly bucket exists only on the
# undocumented authed OAuth usage endpoint, out of scope for a pure-stdin,
# never-break statusline.

# ============================================================================
# LINE 1: Model | tokens (% used) | free tokens, % free | git tail
# ============================================================================

model_display="${C_BLUE}${model}${C_RESET}"
[ -n "$agent_name" ] && model_display="${C_DIM}agent:${C_RESET}${C_WHITE}${agent_name}${C_RESET} ${model_display}"
[ -n "$think_label" ] && model_display="${model_display} ${C_DIM}(${think_label})${C_RESET}"
# fast mode: surface only the non-default (true) state
[ "$fast_mode" = "true" ] && model_display="${model_display} ${C_YELLOW}fast${C_RESET}"
# thinking: surface only the off state (the effort badge already implies thinking on)
[ "$thinking_enabled" = "false" ] && model_display="${model_display} ${C_DIM}no-think${C_RESET}"
# output style: surface only when non-default
[ -n "$out_style" ] && [ "$out_style" != "default" ] && model_display="${model_display} ${C_DIM}${out_style}${C_RESET}"

used_str=$(format_tokens "$current_input")
total_str=$(format_tokens "$window_size")
free_str=$(format_tokens "$free_tokens")

tokens_display="${C_ORANGE}${used_str}/${total_str}${C_RESET} ${C_GREEN}(${pct_used}% used)${C_RESET}"
free_display="${C_ORANGE}${free_str}${C_RESET} ${C_BLUE}${free_pct}% free${C_RESET}"

line1="${model_display}${C_SEP}${tokens_display}${C_SEP}${free_display}"

# Git tail: branch (or short SHA when detached), open PR number, worktree name.
# `git` is optional; one cheap plumbing call, never a working-tree scan.
git_tail=""
if [ -n "$current_dir" ] && [ -d "$current_dir" ] && command -v git >/dev/null 2>&1; then
    branch=$(git -C "$current_dir" symbolic-ref -q --short HEAD 2>/dev/null \
          || git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
    branch=$(printf '%s' "$branch" | tr -d '\000-\037\177')
    [ -n "$branch" ] && git_tail="${C_WHITE}${branch}${C_RESET}"
fi
[ -n "$pr_number" ]     && git_tail="${git_tail}${git_tail:+ }${C_CYAN}#${pr_number}${C_RESET}"
[ -n "$worktree_name" ] && git_tail="${git_tail}${git_tail:+ }${C_DIM}wt:${C_RESET}${C_WHITE}${worktree_name}${C_RESET}"
[ -n "$git_tail" ] && line1="${line1}${C_SEP}${C_DIM}git:${C_RESET} ${git_tail}"

# ============================================================================
# POLLED USAGE (usage-lib.sh): the 5h/7d figures on stdin only move when the
# model answers in this session; the poll also sees quota burnt in other
# sessions and windows that reset while idle. Merge per window:
#   different reset times → the newer window wins (later reset)
#   same window           → the higher percentage wins (usage only rises)
# A stale poll therefore can never lower a number. Model-scoped buckets are
# kept for the fill line below.
# ============================================================================
scoped_rows=()
merge_window() { # <stdin_pct_var> <stdin_reset_var> <poll_pct> <poll_reset>
    local pv="$1" rv="$2" ppct="$3" preset="$4"
    local spct="${!pv}" sreset="${!rv}"
    [[ "$ppct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    if [ -z "$spct" ]; then
        printf -v "$pv" '%s' "$ppct"; [[ "$preset" =~ ^[0-9]+$ ]] && printf -v "$rv" '%s' "$preset"
        return 0
    fi
    if [[ "$preset" =~ ^[0-9]+$ ]] && [[ "$sreset" =~ ^[0-9]+$ ]]; then
        if   [ "$preset" -gt $(( sreset + 60 )) ]; then printf -v "$pv" '%s' "$ppct"; printf -v "$rv" '%s' "$preset"; return 0
        elif [ "$sreset" -gt $(( preset + 60 )) ]; then return 0; fi
    fi
    awk -v a="$ppct" -v b="$spct" 'BEGIN { exit !(a > b) }' && printf -v "$pv" '%s' "$ppct"
    return 0
}
while IFS=$'\t' read -r u_kind u_name u_pct u_reset u_age; do
    case "$u_kind" in
        W) # cap at 100 like the stdin pctb filter; skip anything older than a day
           [[ "$u_age" =~ ^[0-9]+$ ]] && [ "$u_age" -lt 86400 ] || continue
           awk -v p="$u_pct" 'BEGIN { exit !(p <= 100) }' || continue
           case "$u_name" in
               five_hour) merge_window five_pct five_reset "$u_pct" "$u_reset" ;;
               seven_day) merge_window week_pct week_reset "$u_pct" "$u_reset" ;;
           esac ;;
        S) scoped_rows+=("${u_name}"$'\t'"${u_pct}"$'\t'"${u_reset}"$'\t'"${u_age}") ;;
    esac
done < <(usage_rows "$CACHE_BASE" "$CLAUDE_DIR")

# ============================================================================
# RATE BARS (share the ctx line): 5h / 7d / spend, each with an optional
# "->cap Xh Ym (Day HH:MM)" burn-rate marker — shown ONLY when the current pace
# hits 100% before the window resets. Otherwise the bar stays clean.
# ============================================================================

rate_parts=()

# 5-hour bar (rolling 5h window = 18000s)
if [ -n "$five_pct" ]; then
    five_int=$(printf '%.0f' "$five_pct")
    five_seg="${C_WHITE}5h:${C_RESET} $(build_bar "$five_int" 10) ${C_GREEN}${five_int}%${C_RESET}"
    if [ -n "$five_reset" ]; then
        five_cap=$(project_cap "$five_pct" "$five_reset" 18000)
        [ -n "$five_cap" ] && five_seg="${five_seg} ${C_RED}->cap ${five_cap}${C_RESET}"
    fi
    rate_parts+=("$five_seg")
fi

# 7-day bar (weekly window = 604800s)
if [ -n "$week_pct" ]; then
    week_int=$(printf '%.0f' "$week_pct")
    week_seg="${C_WHITE}7d:${C_RESET} $(build_bar "$week_int" 10) ${C_GREEN}${week_int}%${C_RESET}"
    if [ -n "$week_reset" ]; then
        week_cap=$(project_cap "$week_pct" "$week_reset" 604800)
        [ -n "$week_cap" ] && week_seg="${week_seg} ${C_RED}->cap ${week_cap}${C_RESET}"
    fi
    rate_parts+=("$week_seg")
fi

# Spend-limit bar (Claude apps gateway; CC 2.1.251+). May exceed 100% once the
# limit is breached — the bar clamps, the number tells the truth (red past 100).
if [ -n "$spend_pct" ]; then
    spend_int=$(printf '%.0f' "$spend_pct")
    spend_color="$C_GREEN"; [ "$spend_int" -gt 100 ] 2>/dev/null && spend_color="$C_RED"
    spend_seg="${C_WHITE}spend:${C_RESET} $(build_bar "$spend_int" 10) ${spend_color}${spend_int}%${C_RESET}"
    # Dollar amounts (CC 2.1.284+, USD gateways only): "$271.40 of $500/mo".
    # The limit drops its cents when they are zero; unknown periods get no suffix.
    if [[ "$spend_used_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$spend_limit_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        _lim=$(awk -v v="$spend_limit_usd" 'BEGIN { if (v == int(v)) printf "%d", v; else printf "%.2f", v }')
        case "$spend_period" in
            daily) _per="/day" ;; weekly) _per="/wk" ;; monthly) _per="/mo" ;; annual) _per="/yr" ;; *) _per="" ;;
        esac
        spend_seg="${spend_seg} ${C_DIM}\$$(printf '%.2f' "$spend_used_usd") of \$${_lim}${_per}${C_RESET}"
    fi
    rate_parts+=("$spend_seg")
fi

rate_line=""
for (( i=0; i<${#rate_parts[@]}; i++ )); do
    [ "$i" -gt 0 ] && rate_line="${rate_line}${C_SEP}"
    rate_line="${rate_line}${rate_parts[$i]}"
done

# ============================================================================
# CONTEXT LINE: 16-char context bar + prompt-cache state, then the rate bars.
# ============================================================================
ctx_line="${C_WHITE}ctx:${C_RESET} $(build_bar "$pct_used" 16)"

# Cache share of the CURRENT request: cache_read / all input tokens. High reuse
# = cheap turns. Hidden when there is no input yet (e.g. right after /compact).
cache_total=$(( input_tokens + cache_read + cache_create ))
cache_shown=0
if [ "$cache_total" -gt 0 ]; then
    cache_pct=$(awk -v r="$cache_read" -v t="$cache_total" 'BEGIN { printf "%d", (r/t)*100 }')
    if [[ "$cache_pct" =~ ^[0-9]+$ ]]; then
        ctx_line="${ctx_line} ${C_DIM}cache${C_RESET} ${C_CYAN}${cache_pct}%${C_RESET}"
        cache_shown=1
    fi
fi

# Prompt-cache TTL state (CC 2.1.251+): "warm 42m" counts down to the moment the
# cached prefix goes cold and the next turn re-pays the full write price. Green
# with >10m left, yellow ≤10m, red ≤3m; "cold" in red once it has lapsed.
cache_state=""
if [ "$pc_warm" = "true" ] && [[ "$pc_expires" =~ ^[0-9]+$ ]]; then
    left=$(( pc_expires - now ))
    if [ "$left" -gt 0 ]; then
        left_color="$C_GREEN"
        [ "$left" -le 600 ] && left_color="$C_YELLOW"
        [ "$left" -le 180 ] && left_color="$C_RED"
        cache_state="${C_DIM}warm${C_RESET} ${left_color}$(fmt_countdown "$left")${C_RESET}"
        [ -n "$pc_ttl" ] && cache_state="${C_DIM}${pc_ttl}${C_RESET} ${cache_state}"
    else
        cache_state="${C_RED}cold${C_RESET}"
    fi
elif [ "$pc_warm" = "false" ] && [ "$pc_observed" = "true" ]; then
    cache_state="${C_RED}cold${C_RESET}"
fi
if [ -n "$cache_state" ]; then
    [ "$cache_shown" -eq 1 ] && ctx_line="${ctx_line} ${C_DIM}·${C_RESET}"
    ctx_line="${ctx_line} ${cache_state}"
fi

[ -n "$rate_line" ] && ctx_line="${ctx_line}${C_SEP}${rate_line}"

# FILL LINE: per-category breakdown of what is eating the live window, on its
# own line. Present only when the node-written cache exists.
fill_line=""
if [ -n "$session_id" ] && [ -n "$transcript_path" ]; then
    ctx_break=$(get_context_breakdown "$session_id" "$transcript_path")
    [ -n "$ctx_break" ] && fill_line="${C_WHITE}fill:${C_RESET} ${ctx_break}"
fi

# PER-MODEL WEEKLY BARS ("7d Fable: …"): same shape as the 5h/7d bars, same
# ->cap projection over the weekly window. Rendered from the rows read above; a
# stale cache is tagged rather than hidden, so a dead token shows as "old 3h",
# never as a confident wrong number. Their resets join line 4 only when they
# differ from the all-models 7d reset (usually they coincide).
scoped_resets=()
while IFS=$'\t' read -r sc_name sc_pct sc_reset sc_age; do
    [ -n "$sc_name" ] || continue
    [[ "$sc_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
    sc_int=$(printf '%.0f' "$sc_pct")
    sc_color="$C_GREEN"; [ "$sc_int" -gt 100 ] 2>/dev/null && sc_color="$C_RED"
    sc_seg="${C_WHITE}7d ${sc_name}:${C_RESET} $(build_bar "$sc_int" 10) ${sc_color}${sc_int}%${C_RESET}"
    if [[ "$sc_reset" =~ ^[0-9]+$ ]]; then
        sc_cap=$(project_cap "$sc_pct" "$sc_reset" 604800)
        [ -n "$sc_cap" ] && sc_seg="${sc_seg} ${C_RED}->cap ${sc_cap}${C_RESET}"
        if [[ "$week_reset" =~ ^[0-9]+$ ]]; then
            _d=$(( sc_reset - week_reset )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
            [ "$_d" -gt 60 ] && scoped_resets+=("${sc_name}"$'\t'"${sc_reset}")
        else
            scoped_resets+=("${sc_name}"$'\t'"${sc_reset}")
        fi
    fi
    if [[ "$sc_age" =~ ^[0-9]+$ ]] && [ "$sc_age" -gt "$USAGE_STALE" ]; then
        sc_seg="${sc_seg} ${C_DIM}old $(fmt_countdown "$sc_age")${C_RESET}"
    fi
    if [ -n "$fill_line" ]; then fill_line="${fill_line}${C_SEP}${sc_seg}"; else fill_line="$sc_seg"; fi
done < <(printf '%s\n' ${scoped_rows[@]+"${scoped_rows[@]}"})

# ============================================================================
# LINE 3: Reset times + session cost + burn rate + duration + lines changed
# ============================================================================

line3_parts=()

if [ -n "$five_reset" ] && [ -n "$five_pct" ]; then
    s=$(fmt_reset_friendly "$five_reset" "time")
    [ -n "$s" ] && line3_parts+=("${C_WHITE}resets ${s}${C_RESET}")
fi
if [ -n "$week_reset" ] && [ -n "$week_pct" ]; then
    s=$(fmt_reset_friendly "$week_reset" "datetime")
    [ -n "$s" ] && line3_parts+=("${C_WHITE}resets ${s}${C_RESET}")
fi
for _sr in ${scoped_resets[@]+"${scoped_resets[@]}"}; do
    s=$(fmt_reset_friendly "${_sr#*$'\t'}" "datetime")
    [ -n "$s" ] && line3_parts+=("${C_WHITE}${_sr%%$'\t'*} resets ${s}${C_RESET}")
done
if [ -n "$spend_reset" ] && [ -n "$spend_pct" ]; then
    s=$(fmt_reset_friendly "$spend_reset" "datetime")
    [ -n "$s" ] && line3_parts+=("${C_WHITE}spend resets ${s}${C_RESET}")
fi

# Session cost. The headline is Claude Code's authoritative cost.total_cost_usd.
# When present (modern CC) we do NOT scan the transcript — scanning a
# multi-hundred-MB JSONL on every render would be a DoS on long sessions. Only
# older Claude Code without the cost field falls back to the (mtime-cached)
# JSONL estimate, which also yields a dim in/out split.
credit_str=""
_tot=""
if [ -n "$native_cost" ]; then
    native_fmt=$(printf '%.2f' "$native_cost" 2>/dev/null) || native_fmt=""
    [ -n "$native_fmt" ] && credit_str="${C_CYAN}\$${native_fmt}${C_RESET}"
elif [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -n "$session_id" ]; then
    mkdir -p "$CACHE_BASE" 2>/dev/null && chmod 0700 "$CACHE_BASE" 2>/dev/null
    cache_file="${CACHE_BASE}/credit-${session_id}.cache"
    cur_mtime=$(stat -c '%Y' "$transcript_path" 2>/dev/null \
             || stat -f '%m' "$transcript_path" 2>/dev/null || echo "0")
    _in=""; _out=""

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
    # The cached values are re-validated as decimals before they are printed.
    for _v in _in _out _tot; do
        [[ "${!_v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || printf -v "$_v" '%s' ""
    done
    [ -n "$_tot" ] && credit_str="${C_CYAN}\$${_tot}${C_RESET} ${C_DIM}(in:\$${_in} out:\$${_out})${C_RESET}"
fi
[ -n "$credit_str" ] && line3_parts+=("$credit_str")

# Burn rate ($/hr): total cost over wall-clock session time. Hidden unless both
# the cost and a positive duration are known.
cost_num="${native_cost:-${_tot}}"
if [ -n "$cost_num" ] && [[ "$dur_ms" =~ ^[0-9]+$ ]] && [ "$dur_ms" -gt 0 ]; then
    rate_str=$(awk -v c="$cost_num" -v ms="$dur_ms" 'BEGIN {
        r = c * 3600000.0 / ms
        if (r < 0) exit
        printf "%.2f", r
    }')
    [ -n "$rate_str" ] && line3_parts+=("${C_DIM}\$${rate_str}/h${C_RESET}")
fi

# Session wall-clock duration (cost.total_duration_ms). Absent -> hidden.
if [[ "$dur_ms" =~ ^[0-9]+$ ]] && [ "$dur_ms" -gt 0 ]; then
    dur_str=$(fmt_duration_ms "$dur_ms")
    [ -n "$dur_str" ] && line3_parts+=("${C_DIM}${dur_str}${C_RESET}")
fi

# Lines added/removed this session (cost.total_lines_*)
if [[ "$lines_added" =~ ^[0-9]+$ ]] && [[ "$lines_removed" =~ ^[0-9]+$ ]] \
   && { [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; }; then
    line3_parts+=("${C_GREEN}+${lines_added}${C_RESET}${C_DIM}/${C_RESET}${C_RED}-${lines_removed}${C_RESET}")
fi

line3=""
for (( i=0; i<${#line3_parts[@]}; i++ )); do
    [ "$i" -gt 0 ] && line3="${line3}${C_SEP}"
    line3="${line3}${line3_parts[$i]}"
done

# ============================================================================
# LINE 4: Backup path (conditional) + background backup trigger
# ============================================================================

line4=""
_bridge="${SCRIPT_DIR}/backup-bridge.sh"
if [ -n "$session_id" ] && [ -f "$_bridge" ]; then
    # shellcheck source=backup-bridge.sh
    source "$_bridge"
    backup_path=$(get_backup_path "$session_id" "$project_dir")
    [ -n "$backup_path" ] && line4="${C_YELLOW}->${C_RESET} ${C_RED}${backup_path}${C_RESET}"

    # Trigger backup check in background (node); the 5k-token delta guard in
    # the bridge keeps this from spawning node on every render.
    maybe_trigger_backup "$session_id" "$free_pct" "$current_total" "$transcript_path" "$project_dir" &
    disown 2>/dev/null || true
fi

# ============================================================================
# HOUSEKEEPING: once a day, drop per-session cache files older than 30 days
# (breakdown-*, delta-*, credit-*). Detached so it never delays the render.
# ============================================================================
sweep_cache_dir "$CACHE_BASE"

# ============================================================================
# OUTPUT
# ============================================================================

printf '%s' "$line1"
[ -n "$ctx_line" ]  && printf '\n%s' "$ctx_line"    # ctx bar + cache + 5h/7d/spend
[ -n "$fill_line" ] && printf '\n%s' "$fill_line"   # context-fill breakdown
[ -n "$line3" ]     && printf '\n%s' "$line3"       # resets / cost / $hr / dur / lines
[ -n "$line4" ]     && printf '\n%s' "$line4"       # backup path

exit 0
