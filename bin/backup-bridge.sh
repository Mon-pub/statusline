#!/bin/bash
# backup-bridge.sh — integration layer between bash statusline and node backup system.
#
# Sourced by statusline-command.sh. Provides:
#   get_backup_path <session_id> [project_dir]
#       — reads the per-session state JSON, prints the current backup path
#   maybe_trigger_backup <session_id> <free_pct> <total_tokens> <transcript_path> [project_dir]
#       — spawns the node backup trigger when the token count moved 5k+ since
#         the last spawn; node then applies the real thresholds (50k first,
#         every 10k after, plus the 30/15/5 % free safety net).
#
# project_dir comes from the stdin `workspace.project_dir` (the statusline has
# no CLAUDE_PROJECT_DIR — that env var exists only inside hooks). Fallback
# order: explicit arg → CLAUDE_PROJECT_DIR → $PWD.

_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
_NODE_DIR="${STATUSLINE_NODE_DIR:-${_CLAUDE_DIR}/statusline-node}"
_DELTA_CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-statusline"

_bridge_project_dir() {
    local p="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    [ -d "$p" ] || p="$PWD"
    printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# get_backup_path <session_id> [project_dir]
# The state file is written by backup-core.mjs in <project>/.claude/backups/.
# ---------------------------------------------------------------------------
get_backup_path() {
    local session_id="$1" project_dir
    [ -z "$session_id" ] && return
    project_dir=$(_bridge_project_dir "$2")

    local safe_id
    safe_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')
    local state_file="${project_dir}/.claude/backups/.state-${safe_id}.json"

    if [ -f "$state_file" ]; then
        # The path is printed; re-guard its shape (relative, no control bytes).
        jq -r '.backupPath // empty | if type=="string" then . else empty end' "$state_file" 2>/dev/null \
            | tr -d '\000-\037\177' | grep -E '^\.claude/backups/[A-Za-z0-9._-]+\.md$' || true
    fi
}

# ---------------------------------------------------------------------------
# maybe_trigger_backup <session_id> <free_pct> <total_tokens> <transcript_path> [project_dir]
# Designed to run as: maybe_trigger_backup ... & disown
# ---------------------------------------------------------------------------
maybe_trigger_backup() {
    local session_id="$1" free_pct="$2" total_tokens="$3" transcript_path="$4" project_dir
    [ -z "$session_id" ] || [ "$session_id" = "unknown" ] && return
    [ ! -f "${_NODE_DIR}/trigger-backup.mjs" ] && return
    command -v node >/dev/null 2>&1 || return
    project_dir=$(_bridge_project_dir "$5")

    # SECURITY: sanitize session_id (path component) and coerce numeric inputs to
    # integers before any arithmetic — the delta file is in a shared cache dir and
    # its contents must never be evaluated by `$(( ))`.
    session_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9-' '_')
    [[ "$total_tokens" =~ ^[0-9]+$ ]] || total_tokens=0
    [[ "$free_pct"     =~ ^[0-9]+$ ]] || free_pct=""
    [ -f "$transcript_path" ] || transcript_path=""

    mkdir -p "$_DELTA_CACHE_DIR" 2>/dev/null && chmod 0700 "$_DELTA_CACHE_DIR" 2>/dev/null
    local delta_file="${_DELTA_CACHE_DIR}/delta-${session_id}.txt"

    local last_tokens=0
    [ -f "$delta_file" ] && last_tokens=$(cat "$delta_file" 2>/dev/null)
    [[ "$last_tokens" =~ ^[0-9]+$ ]] || last_tokens=0

    local delta=$(( total_tokens - last_tokens ))
    [ "$delta" -lt 0 ] && delta=$(( -delta ))   # negative = compaction / reset

    [ "$delta" -ge 5000 ] || return
    printf '%s' "$total_tokens" > "$delta_file"

    STATUSLINE_PROJECT_DIR="$project_dir" \
        node "${_NODE_DIR}/trigger-backup.mjs" \
            "$session_id" \
            "tokens_${total_tokens}" \
            "$free_pct" \
            "$transcript_path" \
            "$total_tokens" \
        >/dev/null 2>&1
}
