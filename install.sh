#!/usr/bin/env bash
# install.sh — install statusline + credit + backup scripts into $CLAUDE_CONFIG_DIR
# and wire the statusLine key + PreCompact hook into settings.json.
#
# Usage:  ./install.sh                # interactive — installs everything
#         ./install.sh --no-write     # skip settings.json edit, print snippets
#         ./install.sh --force        # overwrite existing statusLine without prompting
#         ./install.sh --no-hooks     # skip PreCompact hook installation
#
# Override target dir:  CLAUDE_CONFIG_DIR=/path/to/claude ./install.sh

set -euo pipefail

WRITE_SETTINGS=1
FORCE=0
INSTALL_HOOKS=1
for arg in "$@"; do
    case "$arg" in
        --no-write) WRITE_SETTINGS=0 ;;
        --force)    FORCE=1 ;;
        --no-hooks) INSTALL_HOOKS=0 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
NODE_TARGET="${TARGET}/statusline-node"

if [ ! -d "$TARGET" ]; then
    echo "Target dir does not exist: $TARGET" >&2
    echo "Create it first (mkdir -p \"$TARGET\") or set CLAUDE_CONFIG_DIR." >&2
    exit 1
fi

# Check prerequisites
missing=()
for cmd in jq awk grep date stat node; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "Install them, then re-run." >&2
    exit 1
fi

echo "Installing to: $TARGET"

# --- Bash scripts ---
echo ""
echo "=== Bash scripts ==="
for f in statusline-command.sh credit-lib.sh credit-project.sh credit-summary.sh display-lib.sh backup-bridge.sh context-lib.sh; do
    src="${SCRIPT_DIR}/bin/${f}"
    dst="${TARGET}/${f}"
    if [ ! -f "$src" ]; then
        echo "  skip $f (not found in bin/)"
        continue
    fi
    # Keep the FIRST (pristine) backup; never clobber it on repeated installs.
    if [ -e "$dst" ] && [ ! -e "${dst}.bak" ]; then
        cp -v "$dst" "${dst}.bak"
    fi
    cp -v "$src" "$dst"
    chmod +x "$dst"
done

# --- Node.js backup scripts ---
echo ""
echo "=== Node.js backup scripts ==="
mkdir -p "$NODE_TARGET"
for f in backup-core.mjs backup-compactor.mjs conv-backup.mjs trigger-backup.mjs context-breakdown.mjs; do
    src="${SCRIPT_DIR}/node/${f}"
    dst="${NODE_TARGET}/${f}"
    if [ ! -f "$src" ]; then
        echo "  skip $f (not found in node/)"
        continue
    fi
    if [ -e "$dst" ] && [ ! -e "${dst}.bak" ]; then
        cp -v "$dst" "${dst}.bak"
    fi
    cp -v "$src" "$dst"
done

# --- Settings.json: statusLine entry ---
SETTINGS="${TARGET}/settings.json"
DESIRED_CMD="bash ${TARGET}/statusline-command.sh"
DESIRED_JSON=$(jq -nc --arg cmd "$DESIRED_CMD" '{type:"command", command:$cmd}')

snippet_statusline() {
    cat <<EOF
  "statusLine": {
    "type": "command",
    "command": "${DESIRED_CMD}"
  }
EOF
}

snippet_hook() {
    cat <<EOF
  "hooks": {
    "PreCompact": [{
      "hooks": [{
        "type": "command",
        "command": "STATUSLINE_PROJECT_DIR=\"\$CLAUDE_PROJECT_DIR\" node ${NODE_TARGET}/conv-backup.mjs",
        "async": true
      }]
    }]
  }
EOF
}

if [ "$WRITE_SETTINGS" -eq 0 ]; then
    echo ""
    echo "Skipping settings.json edit (--no-write). Add manually:"
    echo ""
    snippet_statusline
    echo ""
    snippet_hook
    exit 0
fi

# Initialize settings.json if missing or empty
if [ ! -s "$SETTINGS" ]; then
    echo "Creating $SETTINGS"
    echo '{}' > "$SETTINGS"
    chmod 600 "$SETTINGS"
fi

# Validate it parses
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "Error: $SETTINGS is not valid JSON. Refusing to edit." >&2
    echo "Fix it manually, then add:" >&2
    snippet_statusline >&2
    exit 1
fi

# Keep only the FIRST pristine backup; don't clobber it on repeated installs.
if [ ! -e "${SETTINGS}.bak" ]; then
    cp -v "$SETTINGS" "${SETTINGS}.bak"
fi

# atomic_jq '<filter>' [jq args...] — apply a jq transform to settings.json
# atomically: write to a temp file, verify it still parses, rename into place,
# and re-assert 0600. The temp file is removed on any failure or signal, so a
# broken transform or an interrupt never leaves an orphan or a corrupt file.
atomic_jq() {
    local tmp
    tmp=$(mktemp "${SETTINGS}.XXXXXX") || return 1
    trap 'rm -f "$tmp"' RETURN
    if jq "$@" "$SETTINGS" > "$tmp" && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$SETTINGS"
        chmod 600 "$SETTINGS"
        return 0
    fi
    echo "Error: settings.json transform failed; left unchanged." >&2
    return 1
}

# --- Merge statusLine ---
echo ""
echo "=== statusLine ==="
EXISTING=$(jq -c '.statusLine // empty' "$SETTINGS")

if [ -n "$EXISTING" ]; then
    if [ "$EXISTING" = "$DESIRED_JSON" ]; then
        echo "statusLine already matches. No change."
    else
        echo "Existing statusLine: $EXISTING"
        echo "Replacement:         $DESIRED_JSON"
        if [ "$FORCE" -ne 1 ]; then
            printf "Overwrite? [y/N] "
            read -r ans </dev/tty || ans=""
            case "$ans" in
                y|Y|yes|YES) ;;
                *) echo "Left statusLine untouched."; DESIRED_JSON="" ;;
            esac
        fi
        if [ -n "$DESIRED_JSON" ]; then
            atomic_jq --argjson sl "$DESIRED_JSON" '.statusLine = $sl' && echo "statusLine updated."
        fi
    fi
else
    atomic_jq --argjson sl "$DESIRED_JSON" '.statusLine = $sl' && echo "statusLine added."
fi

# --- Merge PreCompact hook (idempotent rewrite) ---
if [ "$INSTALL_HOOKS" -eq 1 ]; then
    echo ""
    echo "=== PreCompact hook ==="
    HOOK_CMD="STATUSLINE_PROJECT_DIR=\"\$CLAUDE_PROJECT_DIR\" node ${NODE_TARGET}/conv-backup.mjs"
    HOOK_JSON=$(jq -nc --arg cmd "$HOOK_CMD" '[{hooks:[{type:"command", command:$cmd, async:true}]}]')

    # Drop any prior PreCompact entry referencing conv-backup.mjs (so a changed
    # install path — which CC dedups by exact string and would NOT collapse —
    # can't leave a duplicate), tolerate a non-array .hooks.PreCompact, then
    # append the single canonical entry. One atomic pass.
    if atomic_jq --argjson hk "$HOOK_JSON" '
        .hooks //= {} |
        .hooks.PreCompact = (
            ((.hooks.PreCompact // []) | if type == "array" then . else [] end)
            | map(select(((.hooks // []) | map(.command // "") | any(test("conv-backup\\.mjs"))) | not))
        ) + $hk
    '; then
        echo "PreCompact hook installed (idempotent)."
    fi
fi

echo ""
echo "Done. Reload Claude Code (new session) to see changes."
echo "Backup at ${SETTINGS}.bak"
