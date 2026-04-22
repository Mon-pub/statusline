#!/usr/bin/env bash
# install.sh — copy statusline + credit scripts into $CLAUDE_CONFIG_DIR
# and print the settings.json snippet needed to wire the statusline up.
#
# Usage:  ./install.sh
#
# Override target dir:  CLAUDE_CONFIG_DIR=/path/to/claude ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

if [ ! -d "$TARGET" ]; then
    echo "Target dir does not exist: $TARGET" >&2
    echo "Create it first or set CLAUDE_CONFIG_DIR." >&2
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

echo "Installing to: $TARGET"

for f in statusline-command.sh credit-lib.sh credit-project.sh; do
    src="${SCRIPT_DIR}/bin/${f}"
    dst="${TARGET}/${f}"
    if [ -e "$dst" ]; then
        cp -v "$dst" "${dst}.bak"
    fi
    cp -v "$src" "$dst"
    chmod +x "$dst"
done

echo ""
echo "Done. To activate, add this to ${TARGET}/settings.json:"
echo ""
cat <<EOF
  "statusLine": {
    "type": "command",
    "command": "bash ${TARGET}/statusline-command.sh"
  }
EOF
echo ""
echo "Then reload Claude Code."
