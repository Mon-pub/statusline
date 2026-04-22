#!/bin/bash
# shellcheck source=credit-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/credit-lib.sh"
input=$(cat)

# Model name
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')

# Thinking level from settings.json — honors $CLAUDE_CONFIG_DIR override
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

# Context window usage
used=$(echo "$input"     | jq -r '.context_window.used_percentage      // empty')
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens   // 0')
total_out=$(echo "$input"| jq -r '.context_window.total_output_tokens  // 0')

# Rate limits (Claude.ai subscription)
five_pct=$(echo "$input"      | jq -r '.rate_limits.five_hour.used_percentage  // empty')
five_reset=$(echo "$input"    | jq -r '.rate_limits.five_hour.resets_at        // empty')
week_pct=$(echo "$input"      | jq -r '.rate_limits.seven_day.used_percentage  // empty')
week_reset=$(echo "$input"    | jq -r '.rate_limits.seven_day.resets_at        // empty')

# Sonnet-specific rate limit — probe several plausible field paths;
# hide entirely when none are present so non-subscriber environments stay clean.
sonnet_pct=$(echo "$input" | jq -r '
    .rate_limits.sonnet.used_percentage          //
    .rate_limits.models.sonnet.used_percentage   //
    .rate_limits.sonnet_used_percentage          //
    .rate_limits.sonnet                          //
    empty' 2>/dev/null)

# --- Context bar (16 chars wide) ---
if [ -n "$used" ]; then
    used_int=$(printf '%.0f' "$used")
else
    used_int=0
fi
filled=$(( used_int * 16 / 100 ))
empty=$(( 16 - filled ))
bar=""
for i in $(seq 1 $filled); do bar="${bar}█"; done
for i in $(seq 1 $empty);  do bar="${bar}░"; done

# --- Credit consumed: sum usage from the transcript JSONL ---
# The live JSON total_input_tokens / total_output_tokens resets to 0 after
# /resume because Claude Code restarts its in-memory counter.  The transcript
# JSONL at transcript_path always has the full history (including pre-resume
# turns), so we prefer it.  We cache the scan result keyed on (session_id,
# mtime) so the grep+jq only runs when the file actually changed.
#
# Pricing — per-message model detection via credit-lib.sh extract_family():
#   opus    (claude-opus-*):   $15.00/$1.50/$18.75/$75.00 per M in/cr/cc/out
#   sonnet  (claude-sonnet-*): $3.00/$0.30/$3.75/$15.00   per M in/cr/cc/out
#   haiku   (claude-haiku-*):  $1.00/$0.10/$1.25/$5.00    per M in/cr/cc/out
#   <other> (future families): Opus pricing (per user preference)
#   unknown (no model field):  Opus pricing
#
# The family is extracted by walking hyphen-delimited tokens and taking the
# first non-numeric token after stripping the "claude-" prefix.  This handles
# both old-style ids (claude-3-5-sonnet-*) and new-style (claude-opus-4-*).
credit_str=""
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input"      | jq -r '.session_id      // empty')

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -n "$session_id" ]; then
    # XDG-correct persistent cache dir (survives reboots; /tmp does not)
    _cache_base="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"
    mkdir -p -m 0700 "$_cache_base" 2>/dev/null
    cache_file="${_cache_base}/credit-${session_id}.cache"
    # mtime in seconds — stat -c on Linux, stat -f %m on macOS
    cur_mtime=$(stat -c '%Y' "$transcript_path" 2>/dev/null \
             || stat -f '%m' "$transcript_path" 2>/dev/null || echo "0")

    # Cache hit: first field is mtime, rest is the already-computed tab-separated costs
    if [ -f "$cache_file" ]; then
        cached_mtime=$(cut -d' ' -f1 "$cache_file")
        cached_credit=$(cut -d' ' -f2- "$cache_file")
        if [ "$cached_mtime" = "$cur_mtime" ] && [ -n "$cached_credit" ]; then
            _in=$(  printf '%s' "$cached_credit" | cut -f1)
            _out=$( printf '%s' "$cached_credit" | cut -f2)
            _tot=$( printf '%s' "$cached_credit" | cut -f3)
            credit_str="  \$${_tot} (in:\$${_in} out:\$${_out})"
            cur_mtime=""          # signal: skip re-scan below
        fi
    fi

    # Cache miss or stale — scan the JSONL and sum all assistant message usage.
    # Each API call produces multiple JSONL lines with the same message.id
    # (one per streaming content block).  Pricing logic lives in credit-lib.sh,
    # shared with credit-project.sh.
    if [ -n "$cur_mtime" ]; then
        # Returns: input_cost<TAB>output_cost<TAB>total_cost
        credit=$(compute_credit_for_jsonl "$transcript_path")

        if [ -n "$credit" ]; then
            printf '%s %s\n' "$cur_mtime" "$credit" > "$cache_file"
            _in=$(  printf '%s' "$credit" | cut -f1)
            _out=$( printf '%s' "$credit" | cut -f2)
            _tot=$( printf '%s' "$credit" | cut -f3)
            credit_str="  \$${_tot} (in:\$${_in} out:\$${_out})"
        fi
    fi
else
    # Fallback: use live cumulative counts from the JSON payload (fresh sessions
    # where transcript_path is absent or the file hasn't appeared yet).
    # No per-message model info available here, so default to Opus pricing.
    total_tokens=$(( total_in + total_out ))
    if [ "$total_tokens" -gt 0 ]; then
        read -r _in _out _tot < <(awk -v ti="$total_in" -v to="$total_out" \
            'BEGIN {
                in_c  = ti * 15.00 / 1000000
                out_c = to * 75.00 / 1000000
                printf "%.4f\t%.4f\t%.4f", in_c, out_c, in_c+out_c
            }')
        credit_str="  \$${_tot} (in:\$${_in} out:\$${_out})"
    fi
fi

# --- Helper: format a unix epoch as "HH:MM" (same day) or "MM-DD HH:MM" (future date) ---
# Uses explicit 24-hour format strings; never locale-dependent.
fmt_reset() {
    local epoch="$1"
    [ -z "$epoch" ] && return
    # Today's date in YYYY-MM-DD (local time), platform-agnostic
    local today
    today=$(date "+%Y-%m-%d")
    # Reset date in the same format
    local reset_day
    reset_day=$(date -d "@${epoch}" "+%Y-%m-%d" 2>/dev/null \
             || date -r  "$epoch"  "+%Y-%m-%d" 2>/dev/null)
    if [ "$reset_day" = "$today" ]; then
        # Same day: time only, unambiguously 24-hour
        date -d "@${epoch}" "+%H:%M" 2>/dev/null \
        || date -r  "$epoch"  "+%H:%M" 2>/dev/null
    else
        # Different day: prepend month-day so the reader can tell it's not today
        date -d "@${epoch}" "+%m-%d %H:%M" 2>/dev/null \
        || date -r  "$epoch"  "+%m-%d %H:%M" 2>/dev/null
    fi
}

# --- Rate limit section ---
rate_str=""
if [ -n "$five_pct" ] || [ -n "$week_pct" ] || [ -n "$sonnet_pct" ]; then
    rate_str="  |"
    if [ -n "$five_pct" ]; then
        five_int=$(printf '%.0f' "$five_pct")
        five_reset_fmt=$(fmt_reset "$five_reset")
        if [ -n "$five_reset_fmt" ]; then
            rate_str="${rate_str}  5h:${five_int}% rst@${five_reset_fmt}"
        else
            rate_str="${rate_str}  5h:${five_int}%"
        fi
    fi
    if [ -n "$week_pct" ]; then
        week_int=$(printf '%.0f' "$week_pct")
        week_reset_fmt=$(fmt_reset "$week_reset")
        if [ -n "$week_reset_fmt" ]; then
            rate_str="${rate_str}  7d:${week_int}% rst@${week_reset_fmt}"
        else
            rate_str="${rate_str}  7d:${week_int}%"
        fi
    fi
    if [ -n "$sonnet_pct" ]; then
        sonnet_int=$(printf '%.0f' "$sonnet_pct")
        rate_str="${rate_str}  sonnet:${sonnet_int}%"
    fi
fi

# --- Final output ---
if [ -n "$think_label" ]; then
    model_str="${model} (${think_label})"
else
    model_str="${model}"
fi

printf "%s  ctx:%d%%  [%s]%s%s" \
    "$model_str" "$used_int" "$bar" "$rate_str" "$credit_str"
