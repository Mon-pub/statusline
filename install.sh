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
for f in statusline-command.sh credit-lib.sh credit-project.sh credit-summary.sh display-lib.sh backup-bridge.sh; do
    src="${SCRIPT_DIR}/bin/${f}"
    dst="${TARGET}/${f}"
    if [ ! -f "$src" ]; then
        echo "  skip $f (not found in bin/)"
        continue
    fi
    if [ -e "$dst" ]; then
        cp -v "$dst" "${dst}.bak"
    fi
    cp -v "$src" "$dst"
    chmod +x "$dst"
done

# --- Node.js backup scripts ---
echo ""
echo "=== Node.js backup scripts ==="
mkdir -p "$NODE_TARGET"
for f in backup-core.mjs backup-compactor.mjs conv-backup.mjs trigger-backup.mjs; do
    src="${SCRIPT_DIR}/node/${f}"
    dst="${NODE_TARGET}/${f}"
    if [ ! -f "$src" ]; then
        echo "  skip $f (not found in node/)"
        continue
    fi
    if [ -e "$dst" ]; then
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
fi

# Validate it parses
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "Error: $SETTINGS is not valid JSON. Refusing to edit." >&2
    echo "Fix it manually, then add:" >&2
    snippet_statusline >&2
    exit 1
fi

# Backup settings
cp -v "$SETTINGS" "${SETTINGS}.bak"

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
            tmp=$(mktemp "${SETTINGS}.XXXXXX")
            jq --argjson sl "$DESIRED_JSON" '.statusLine = $sl' "$SETTINGS" > "$tmp"
            mv "$tmp" "$SETTINGS"
            echo "statusLine updated."
        fi
    fi
else
    tmp=$(mktemp "${SETTINGS}.XXXXXX")
    jq --argjson sl "$DESIRED_JSON" '.statusLine = $sl' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "statusLine added."
fi

# --- Merge PreCompact hook ---
if [ "$INSTALL_HOOKS" -eq 1 ]; then
    echo ""
    echo "=== PreCompact hook ==="
    HOOK_CMD="STATUSLINE_PROJECT_DIR=\"\$CLAUDE_PROJECT_DIR\" node ${NODE_TARGET}/conv-backup.mjs"

    # Check if PreCompact hook already exists with our command
    existing_hook=$(jq -r '.hooks.PreCompact // empty | .[] | .hooks[]? | .command // empty' "$SETTINGS" 2>/dev/null | grep -F "conv-backup.mjs" || true)

    if [ -n "$existing_hook" ]; then
        echo "PreCompact hook already configured. No change."
    else
        # Build the hook entry as JSON
        HOOK_JSON=$(jq -nc --arg cmd "$HOOK_CMD" '[{hooks:[{type:"command", command:$cmd, async:true}]}]')

        # Merge: append to existing PreCompact array or create it
        tmp=$(mktemp "${SETTINGS}.XXXXXX")
        jq --argjson hk "$HOOK_JSON" '
            .hooks //= {} |
            .hooks.PreCompact = (.hooks.PreCompact // []) + $hk
        ' "$SETTINGS" > "$tmp"
        mv "$tmp" "$SETTINGS"
        echo "PreCompact hook added."
    fi
fi

echo ""
echo "Done. Reload Claude Code (new session) to see changes."
echo "Backup at ${SETTINGS}.bak"
