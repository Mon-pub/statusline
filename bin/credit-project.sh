#!/bin/bash
# credit-project.sh — DEPRECATED. Kept so old commands keep working; it now runs
# credit-report.sh, which is the single implementation of cost accounting.
#
# Usage:
#   credit-project.sh <project-dir> [extra credit-report.sh flags...]
#
# <project-dir> is either a real project path (~/my-project) or its encoded
# directory under ~/.claude/projects/.
#
# Why this is a wrapper now: the original version summed only the top-level
# <project>/*.jsonl transcripts, so every subagent and workflow-agent file under
# <session>/subagents/** was invisible. On a multi-agent setup those are most of
# the spend. Rather than maintain a second pricing pipeline that has to agree
# with credit-report.sh forever, this forwards to it.
#
# Equivalent modern command:
#   credit-report.sh --all <project-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    [ $# -lt 1 ] && exit 1
    exit 0
fi

project_dir="$1"; shift
if [ ! -d "$project_dir" ]; then
    echo "Error: directory not found: $project_dir" >&2
    exit 1
fi

echo "credit-project.sh is deprecated — running: credit-report.sh --all $project_dir" >&2
exec bash "${SCRIPT_DIR}/credit-report.sh" --all "$project_dir" "$@"
