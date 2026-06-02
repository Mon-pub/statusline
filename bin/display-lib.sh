#!/bin/bash
# display-lib.sh — ANSI colors, progress bars, formatting helpers for statusline.
#
# Sourced by statusline-command.sh. No standalone use.
#
# Functions:
#   build_bar <pct> <width>         — colored ●○ progress bar
#   format_tokens <num>             — compact "50k" / "1.2m" display
#   fmt_reset_friendly <epoch> <style>  — time/datetime/date reset formatting
#   get_peak_status                 — outputs "PEAK|OFF_PEAK <countdown>"

# ---------------------------------------------------------------------------
# ANSI RGB color constants
# ---------------------------------------------------------------------------
C_BLUE=$'\x1b[38;2;0;153;255m'
C_ORANGE=$'\x1b[38;2;255;176;85m'
C_GREEN=$'\x1b[38;2;0;160;0m'
C_CYAN=$'\x1b[38;2;46;149;153m'
C_RED=$'\x1b[38;2;255;85;85m'
C_YELLOW=$'\x1b[38;2;230;200;0m'
C_WHITE=$'\x1b[38;2;220;220;220m'
C_DIM=$'\x1b[2m'
C_RESET=$'\x1b[0m'
C_SEP=" ${C_DIM}|${C_RESET} "

# ---------------------------------------------------------------------------
# build_bar <pct> <width>
# Outputs a colored ●○ bar. Color thresholds:
#   green < 50, orange 50-69, yellow 70-89, red 90+
# ---------------------------------------------------------------------------
build_bar() {
    local pct="$1" width="${2:-16}"
    # Self-guard: both args feed raw bash arithmetic below; coerce to integers so
    # build_bar can never evaluate an attacker string regardless of the caller.
    [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
    [[ "$width" =~ ^[0-9]+$ ]] || width=16
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    local bar_color
    if [ "$pct" -ge 90 ]; then
        bar_color="$C_RED"
    elif [ "$pct" -ge 70 ]; then
        bar_color="$C_YELLOW"
    elif [ "$pct" -ge 50 ]; then
        bar_color="$C_ORANGE"
    else
        bar_color="$C_GREEN"
    fi

    local filled_str="" empty_str=""
    local i
    for (( i=0; i<filled; i++ )); do filled_str="${filled_str}●"; done
    for (( i=0; i<empty; i++ ));  do empty_str="${empty_str}○"; done

    printf '%s%s%s%s%s' "$bar_color" "$filled_str" "$C_DIM" "$empty_str" "$C_RESET"
}

# ---------------------------------------------------------------------------
# format_tokens <num>
# Compact display: 50000 → "50k", 1200000 → "1.2m"
# ---------------------------------------------------------------------------
format_tokens() {
    local num="$1"
    awk -v n="$num" 'BEGIN {
        if (n >= 1000000) {
            v = n / 1000000
            if (v == int(v)) printf "%dm", v
            else printf "%.1fm", v
        } else if (n >= 1000) {
            v = n / 1000
            if (v == int(v)) printf "%dk", v
            else printf "%.1fk", v
        } else {
            printf "%d", n
        }
    }'
}

# ---------------------------------------------------------------------------
# fmt_reset_friendly <epoch> <style>
#   style "time":     "5:00pm (3h16m)"
#   style "datetime": "Thu, 7:00pm"
#   style "date":     "feb 1"
#
# Uses date -d @epoch (Linux) with date -r epoch (macOS) fallback.
# ---------------------------------------------------------------------------
fmt_reset_friendly() {
    local epoch="$1" style="$2"
    [ -z "$epoch" ] && return
    # Defense in depth: epoch reaches `$(( epoch - now ))` below; reject anything
    # that is not a plain non-negative integer so it can never be evaluated.
    case "$epoch" in (*[!0-9]*|'') return ;; esac

    case "$style" in
        time)
            local time_str
            time_str=$(date -d "@${epoch}" "+%-I:%M%P" 2>/dev/null \
                    || date -r  "$epoch"  "+%-I:%M%P" 2>/dev/null)
            [ -z "$time_str" ] && return

            local now remaining_s
            now=$(date +%s)
            remaining_s=$(( epoch - now ))
            if [ "$remaining_s" -gt 0 ]; then
                local total_min=$(( remaining_s / 60 ))
                local h=$(( total_min / 60 ))
                local m=$(( total_min % 60 ))
                time_str="${time_str} (${h}h${m}m)"
            fi
            printf '%s' "$time_str"
            ;;
        datetime)
            date -d "@${epoch}" "+%a, %-I:%M%P" 2>/dev/null \
            || date -r  "$epoch"  "+%a, %-I:%M%P" 2>/dev/null
            ;;
        date|*)
            local month_str
            month_str=$(date -d "@${epoch}" "+%b %-d" 2>/dev/null \
                     || date -r  "$epoch"  "+%b %-d" 2>/dev/null)
            # Lowercase month for compact look
            printf '%s' "${month_str,,}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# get_peak_status
# Peak = weekdays 8AM-2PM ET (UTC 12:00-18:00). Everything else = off-peak.
# Outputs: "PEAK <countdown>" or "OFF_PEAK <countdown>"
# ---------------------------------------------------------------------------
get_peak_status() {
    local utc_day utc_hour utc_min
    utc_day=$(date -u +%w)    # 0=Sun, 6=Sat
    utc_hour=$(date -u +%-H)
    utc_min=$(date -u +%-M)

    local is_weekend=0
    [ "$utc_day" -eq 0 ] || [ "$utc_day" -eq 6 ] && is_weekend=1

    local is_peak=0
    if [ "$is_weekend" -eq 0 ] && [ "$utc_hour" -ge 12 ] && [ "$utc_hour" -lt 18 ]; then
        is_peak=1
    fi

    local minutes_until_flip
    if [ "$is_peak" -eq 1 ]; then
        # Minutes until peak ends (UTC 18:00)
        minutes_until_flip=$(( (17 - utc_hour) * 60 + (60 - utc_min) ))
    elif [ "$is_weekend" -eq 0 ] && [ "$utc_hour" -lt 12 ]; then
        # Before peak today
        minutes_until_flip=$(( (11 - utc_hour) * 60 + (60 - utc_min) ))
    else
        # After peak on weekday, or weekend
        local days_until_peak
        if [ "$is_weekend" -eq 1 ]; then
            [ "$utc_day" -eq 6 ] && days_until_peak=2 || days_until_peak=1
        else
            # Weekday after peak: Fri→Mon=3, else tomorrow
            [ "$utc_day" -eq 5 ] && days_until_peak=3 || days_until_peak=1
        fi
        # Calculate seconds to next peak start, convert to minutes
        local now_epoch next_peak_epoch
        now_epoch=$(date -u +%s)
        next_peak_epoch=$(date -u -d "+${days_until_peak} days 12:00:00 UTC" +%s 2>/dev/null)
        if [ -z "$next_peak_epoch" ]; then
            # macOS fallback: compute manually
            local today_midnight
            today_midnight=$(date -u -d "today 00:00:00 UTC" +%s 2>/dev/null \
                          || date -u -j -f "%Y%m%d%H%M%S" "$(date -u +%Y%m%d)000000" +%s 2>/dev/null)
            next_peak_epoch=$(( today_midnight + days_until_peak * 86400 + 12 * 3600 ))
        fi
        minutes_until_flip=$(( (next_peak_epoch - now_epoch) / 60 ))
        [ "$minutes_until_flip" -lt 0 ] && minutes_until_flip=0
    fi

    local countdown=""
    local d=$(( minutes_until_flip / 1440 ))
    local h=$(( (minutes_until_flip % 1440) / 60 ))
    local m=$(( minutes_until_flip % 60 ))
    [ "$d" -gt 0 ] && countdown="${d}d"
    [ "$h" -gt 0 ] && countdown="${countdown}${h}h"
    countdown="${countdown}${m}m"

    if [ "$is_peak" -eq 1 ]; then
        printf 'PEAK %s' "$countdown"
    else
        printf 'OFF_PEAK %s' "$countdown"
    fi
}
