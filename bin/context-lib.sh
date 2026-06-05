#!/bin/bash
# context-lib.sh — context-breakdown integration for the statusline.
#
# Sourced by statusline-command.sh (after display-lib.sh, for the C_* colors).
# Provides:
#   get_context_breakdown <session_id> <transcript_path>
#       — prints a colored "results 48% · tools 22% · msgs 20%" segment, or
#         nothing if no breakdown is available yet.
#
# Design mirrors backup-bridge: the bash side only ever reads a small JSON cache
# (instant). The expensive JSONL parse runs in node, in the background, and only
# when the transcript's mtime has changed since the last spawn — so a long
# session's ~300ms re-renders never re-parse the file.

_CTX_NODE_DIR="${STATUSLINE_NODE_DIR:-${HOME}/.claude/statusline-node}"
_CTX_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"

# Short display labels for the four buckets the node side emits.
_ctx_label() {
    case "$1" in
        msgs)    printf 'msgs'    ;;
        tools)   printf 'tools'   ;;
        results) printf 'results' ;;
        attach)  printf 'attach'  ;;
        *)       printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# get_context_breakdown <session_id> <transcript_path>
# ---------------------------------------------------------------------------
get_context_breakdown() {
    local session_id="$1" transcript_path="$2"
    [ -z "$session_id" ] && return
    [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] && return

    # session_id is already sanitized by the caller, but re-guard: it names a file.
    local safe_id
    safe_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9_-' '_')

    local cache_file="${_CTX_CACHE_DIR}/breakdown-${safe_id}.json"
    local spawn_marker="${_CTX_CACHE_DIR}/breakdown-${safe_id}.spawn"

    local cur_mtime
    cur_mtime=$(stat -c '%Y' "$transcript_path" 2>/dev/null \
             || stat -f '%m' "$transcript_path" 2>/dev/null || echo "0")
    [[ "$cur_mtime" =~ ^[0-9]+$ ]] || cur_mtime=0

    # Cache freshness check.
    local cached_mtime=""
    if [ -f "$cache_file" ]; then
        cached_mtime=$(jq -r '.mtime // empty' "$cache_file" 2>/dev/null)
        [[ "$cached_mtime" =~ ^[0-9]+$ ]] || cached_mtime=""
    fi

    # Stale (or missing) cache → spawn the node parser in the background, but only
    # once per transcript mtime (the spawn marker dedups the ~300ms re-renders).
    if [ "$cached_mtime" != "$cur_mtime" ] && [ -f "${_CTX_NODE_DIR}/context-breakdown.mjs" ]; then
        local last_spawn=""
        [ -f "$spawn_marker" ] && last_spawn=$(cat "$spawn_marker" 2>/dev/null)
        if [ "$last_spawn" != "$cur_mtime" ]; then
            mkdir -p -m 0700 "$_CTX_CACHE_DIR" 2>/dev/null
            printf '%s' "$cur_mtime" > "$spawn_marker" 2>/dev/null
            ( node "${_CTX_NODE_DIR}/context-breakdown.mjs" \
                   "$transcript_path" "$safe_id" >/dev/null 2>&1 & ) 2>/dev/null
        fi
    fi

    # Render whatever the cache currently holds (possibly one turn stale — fine).
    [ -f "$cache_file" ] || return

    # jq emits "<name> <pct>" lines for buckets >0%, sorted by share descending.
    local pairs
    pairs=$(jq -r '
        .buckets as $b | .total as $t
        | if ($t // 0) > 0 then
            [ {n:"msgs",v:($b.msgs//0)}, {n:"tools",v:($b.tools//0)},
              {n:"results",v:($b.results//0)}, {n:"attach",v:($b.attach//0)} ]
            | map(. + {p: ((.v * 100 / $t) | round)})
            | sort_by(-.p) | map(select(.p > 0))
            | .[] | "\(.n) \(.p)"
          else empty end' "$cache_file" 2>/dev/null)
    [ -z "$pairs" ] && return

    local out="" name pct first=1
    while read -r name pct; do
        [ -z "$name" ] && continue
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        local lbl
        lbl=$(_ctx_label "$name")
        if [ "$first" -eq 1 ]; then
            first=0
        else
            out="${out} ${C_DIM}·${C_RESET} "
        fi
        out="${out}${C_DIM}${lbl}${C_RESET} ${C_WHITE}${pct}%${C_RESET}"
    done <<< "$pairs"

    [ -n "$out" ] && printf '%s' "$out"
}
