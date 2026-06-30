#!/bin/bash
# display-lib.sh — ANSI colors, progress bars, formatting helpers for statusline.
#
# Sourced by statusline-command.sh. No standalone use.
#
# Functions:
#   build_bar <pct> <width>         — colored ●○ progress bar
#   format_tokens <num>             — compact "50k" / "1.2m" display
#   fmt_reset_friendly <epoch> <style>  — time/datetime/date reset formatting
#   project_cap <pct> <epoch> <win> — time-to-cap if on track to hit it first
#   fmt_duration_ms <ms>            — compact "2h45m" wall-clock duration

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
#   style "datetime": "Mon, 8:00am (3d2h)"   (date instead of weekday when >7d out)
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
            local now remaining_s base_fmt dt_str
            now=$(date +%s)
            remaining_s=$(( epoch - now ))
            # Weekly resets land at an account-assigned fixed time, so the reset
            # can be anywhere from hours to ~7 days out. A weekday alone ("Mon")
            # is ambiguous; the appended countdown disambiguates. For resets more
            # than 7 days away (shouldn't happen for a 7-day window, but guard it)
            # show an explicit calendar date instead of a weekday.
            if [ "$remaining_s" -gt 604800 ]; then
                base_fmt="+%b %-d, %-I:%M%P"
            else
                base_fmt="+%a, %-I:%M%P"
            fi
            dt_str=$(date -d "@${epoch}" "$base_fmt" 2>/dev/null \
                  || date -r  "$epoch"  "$base_fmt" 2>/dev/null)
            [ -z "$dt_str" ] && return
            if [ "$remaining_s" -gt 0 ]; then
                local total_min=$(( remaining_s / 60 ))
                local d=$(( total_min / 1440 ))
                local h=$(( (total_min % 1440) / 60 ))
                local m=$(( total_min % 60 ))
                local cd
                if [ "$d" -gt 0 ]; then
                    cd="${d}d${h}h"
                elif [ "$h" -gt 0 ]; then
                    cd="${h}h${m}m"
                else
                    cd="${m}m"
                fi
                dt_str="${dt_str} (${cd})"
            fi
            printf '%s' "$dt_str"
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
# project_cap <used_pct> <resets_at_epoch> <window_len_s>
# Linear burn-rate projection for a rate-limit window. Echoes the time until the
# limit is projected to hit 100% AND the wall-clock moment it lands, e.g.
# "1h12m (Tue 14:30)" — ONLY when that is sooner than the window resets, i.e.
# when you are on track to be capped before relief. Echoes nothing when you will
# not hit the cap first, or when inputs are unusable. The window is treated as
# the <window_len_s> seconds ending at <resets_at>, so elapsed = window -
# (resets_at - now); this holds for the rolling 5h window and is a good
# approximation for the trailing-7d weekly window.
# ---------------------------------------------------------------------------
project_cap() {
    local used="$1" resets_at="$2" window="$3"
    [[ "$used"      =~ ^[0-9]+(\.[0-9]+)?$ ]] || return
    [[ "$resets_at" =~ ^[0-9]+$ ]] || return
    [[ "$window"    =~ ^[0-9]+$ ]] || return
    local now remaining elapsed
    now=$(date +%s)
    remaining=$(( resets_at - now ))
    [ "$remaining" -le 0 ] && return            # already reset / clock skew
    [ "$remaining" -ge "$window" ] && return    # window not started yet / skew
    elapsed=$(( window - remaining ))
    [ "$elapsed" -le 0 ] && return

    # Seconds until the window reaches 100% at the current linear burn rate, but
    # only if that is sooner than the window resets (else nothing to warn about).
    local secs
    secs=$(awk -v u="$used" -v el="$elapsed" -v rem="$remaining" 'BEGIN {
        if (u <= 0 || u >= 100) exit            # nothing to project
        rate = u / el                            # percent consumed per second
        if (rate <= 0) exit
        s = (100 - u) / rate                     # seconds to reach 100%
        if (s >= rem) exit                       # wont hit cap before reset
        printf "%d", int(s)
    }')
    [[ "$secs" =~ ^[0-9]+$ ]] || return

    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 )) dur
    if [ "$h" -gt 0 ]; then
        dur="${h}h${m}m"
    else
        dur="$(( m < 1 ? 1 : m ))m"
    fi

    # Wall-clock moment the cap is projected to hit (weekday + 24h time).
    local cap_epoch when
    cap_epoch=$(( now + secs ))
    when=$(date -d "@${cap_epoch}" "+%a %H:%M" 2>/dev/null \
        || date -r  "$cap_epoch"  "+%a %H:%M" 2>/dev/null)
    if [ -n "$when" ]; then
        printf '%s (%s)' "$dur" "$when"
    else
        printf '%s' "$dur"
    fi
}

# ---------------------------------------------------------------------------
# fmt_duration_ms <milliseconds>
# Compact wall-clock duration: "2h45m" / "45m" / "30s". Empty on bad input.
# ---------------------------------------------------------------------------
fmt_duration_ms() {
    local ms="$1"
    [[ "$ms" =~ ^[0-9]+$ ]] || return
    local s=$(( ms / 1000 ))
    local h=$(( s / 3600 ))
    local m=$(( (s % 3600) / 60 ))
    local sec=$(( s % 60 ))
    if [ "$h" -gt 0 ]; then
        printf '%dh%dm' "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf '%dm' "$m"
    else
        printf '%ds' "$sec"
    fi
}
