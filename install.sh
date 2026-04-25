#!/usr/bin/env bash
# install.sh — copy statusline + credit scripts into $CLAUDE_CONFIG_DIR
# and wire the statusLine key into settings.json (with confirmation).
#
# Usage:  ./install.sh                # interactive
#         ./install.sh --no-write     # skip settings.json edit, just print snippet
#         ./install.sh --force        # overwrite an existing different statusLine without prompting
#
# Override target dir:  CLAUDE_CONFIG_DIR=/path/to/claude ./install.sh

set -euo pipefail

WRITE_SETTINGS=1
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --no-write) WRITE_SETTINGS=0 ;;
        --force)    FORCE=1 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

if [ ! -d "$TARGET" ]; then
    echo "Target dir does not exist: $TARGET" >&2
    echo "Create it first (mkdir -p \"$TARGET\") or set CLAUDE_CONFIG_DIR." >&2
    exit 1
fi

# Check prerequisites
missing=()
for cmd in jq awk grep date stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "Install them, then re-run." >&2
    exit 1
fi

echo "Installing scripts to: $TARGET"

for f in statusline-command.sh credit-lib.sh credit-project.sh; do
    src="${SCRIPT_DIR}/bin/${f}"
    dst="${TARGET}/${f}"
    if [ -e "$dst" ]; then
        cp -v "$dst" "${dst}.bak"
    fi
    cp -v "$src" "$dst"
    chmod +x "$dst"
done

SETTINGS="${TARGET}/settings.json"
DESIRED_CMD="bash ${TARGET}/statusline-command.sh"
DESIRED_JSON=$(jq -nc --arg cmd "$DESIRED_CMD" '{type:"command", command:$cmd}')

snippet() {
    cat <<EOF
  "statusLine": {
    "type": "command",
    "command": "${DESIRED_CMD}"
  }
EOF
}

if [ "$WRITE_SETTINGS" -eq 0 ]; then
    echo ""
    echo "Skipping settings.json edit (--no-write). Add manually:"
    echo ""
    snippet
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
    snippet >&2
    exit 1
fi

EXISTING=$(jq -c '.statusLine // empty' "$SETTINGS")

if [ -n "$EXISTING" ]; then
    if [ "$EXISTING" = "$DESIRED_JSON" ]; then
        echo "settings.json already has matching statusLine entry. Nothing to do."
        exit 0
    fi
    echo "settings.json already has a different statusLine:"
    echo "  $EXISTING"
    echo "Replacement:"
    echo "  $DESIRED_JSON"
    if [ "$FORCE" -ne 1 ]; then
        printf "Overwrite? [y/N] "
        read -r ans </dev/tty || ans=""
        case "$ans" in
            y|Y|yes|YES) ;;
            *) echo "Left settings.json untouched. Snippet to merge manually:"; snippet; exit 0 ;;
        esac
    fi
fi

# Atomic write: tmp file + mv
cp -v "$SETTINGS" "${SETTINGS}.bak"
tmp=$(mktemp "${SETTINGS}.XXXXXX")
jq --argjson sl "$DESIRED_JSON" '.statusLine = $sl' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

echo ""
echo "Wrote statusLine into $SETTINGS"
echo "Backup at ${SETTINGS}.bak"
echo "Reload Claude Code (start new session) to see the statusline."
