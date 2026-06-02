#!/bin/bash
# backup-bridge.sh — integration layer between bash statusline and node backup system.
#
# Sourced by statusline-command.sh. Provides:
#   get_backup_path <session_id>   — reads state JSON, returns backup path
#   maybe_trigger_backup <session_id> <free_pct> <total_tokens> <transcript_path>
#       — spawns node backup trigger when token delta exceeds threshold

# Where the node backup scripts live after install
_NODE_DIR="${STATUSLINE_NODE_DIR:-${HOME}/.claude/statusline-node}"

# Delta guard: only spawn node when tokens changed by 5k+ since last check.
# Prevents spawning node on every statusline tick (~every few seconds).
_DELTA_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"

# ---------------------------------------------------------------------------
# get_backup_path <session_id>
# Reads per-session state file. Outputs backup path or empty string.
# The state file is written by backup-core.mjs in the project's .claude/backups/
# ---------------------------------------------------------------------------
get_backup_path() {
    local session_id="$1"
    [ -z "$session_id" ] && return

    local safe_id
    safe_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')

    # Search for state file in likely project dirs
    # CLAUDE_PROJECT_DIR is set by Claude Code in hook contexts
    local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    local state_file="${project_dir}/.claude/backups/.state-${safe_id}.json"

    if [ -f "$state_file" ]; then
        jq -r '.backupPath // empty' "$state_file" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# maybe_trigger_backup <session_id> <free_pct> <total_tokens> <transcript_path>
# Spawns node trigger-backup.mjs in background if token delta >= 5000.
# Designed to run as: maybe_trigger_backup ... & disown
# ---------------------------------------------------------------------------
maybe_trigger_backup() {
    local session_id="$1" free_pct="$2" total_tokens="$3" transcript_path="$4"
    [ -z "$session_id" ] || [ "$session_id" = "unknown" ] && return
    [ ! -f "${_NODE_DIR}/trigger-backup.mjs" ] && return

    # SECURITY: sanitize session_id (path component) and coerce numeric inputs to
    # integers before any arithmetic — the delta file is in a shared cache dir and
    # its contents must never be evaluated by `$(( ))`.
    session_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')
    [[ "$total_tokens" =~ ^[0-9]+$ ]] || total_tokens=0

    mkdir -p "$_DELTA_CACHE_DIR" 2>/dev/null
    local delta_file="${_DELTA_CACHE_DIR}/delta-${session_id}.txt"

    # Read last known token count
    local last_tokens=0
    [ -f "$delta_file" ] && last_tokens=$(cat "$delta_file" 2>/dev/null)
    [[ "$last_tokens" =~ ^[0-9]+$ ]] || last_tokens=0

    local delta=$(( total_tokens - last_tokens ))
    # Negative delta means session reset / new session
    [ "$delta" -lt 0 ] && delta=$(( -delta ))

    # Only trigger if delta >= 5000 tokens
    if [ "$delta" -ge 5000 ]; then
        printf '%s' "$total_tokens" > "$delta_file"

        local project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
        STATUSLINE_PROJECT_DIR="$project_dir" \
            node "${_NODE_DIR}/trigger-backup.mjs" \
                "$session_id" \
                "tokens_${total_tokens}_delta" \
                "$free_pct" \
            >/dev/null 2>&1
    fi
}
