#!/bin/bash
# credit-summary.sh — DEPRECATED. Kept so old commands keep working; it now runs
# credit-report.sh, which is the single implementation of cost accounting.
#
# Usage:
#   credit-summary.sh                          # all sessions, all time
#   credit-summary.sh 2026-05-01               # spend from May 1, 2026 onward
#   credit-summary.sh 2026-05-01 ~/my-project  # since date, one project
#   credit-summary.sh "" ~/my-project          # all time, one project
#   credit-summary.sh 2026-05-01 --json        # flags are forwarded as-is
#
# Why this is a wrapper now: the original version had two accounting faults.
# It selected sessions by transcript *modification time* and then billed each
# one's entire lifetime into the window — but Claude Code rewrites a transcript
# every time you resume it, so a session holding work from May could be charged
# to September. And it read only the top-level <project>/*.jsonl files, missing
# every subagent and workflow-agent transcript under <session>/subagents/**.
# credit-report.sh attributes each message to the day it was produced and prices
# the agent transcripts with the session that spawned them.
#
# Equivalent modern command:
#   credit-report.sh --all [--since <date>] [<project-dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

since_date=""; project_dir=""; passthru=(); forward=0

while [ $# -gt 0 ]; do
    arg="$1"; shift
    if [ "$forward" -eq 1 ]; then passthru+=("$arg"); continue; fi
    case "$arg" in
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        # From the first option onward everything is handed to credit-report.sh
        # untouched, so a flag and its value stay together.
        -*) forward=1; passthru+=("$arg") ;;
        "") : ;;   # empty string = placeholder, skip
        *)
            if [ -z "$since_date" ] && [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                since_date="$arg"
            elif [ -z "$project_dir" ] && [ -d "$arg" ]; then
                project_dir="$arg"
            else
                echo "Unknown arg or not a directory: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

args=(--all)
[ -n "$since_date" ]  && args+=(--since "$since_date")
[ -n "$project_dir" ] && args+=("$project_dir")
args+=(${passthru[@]+"${passthru[@]}"})

echo "credit-summary.sh is deprecated — running: credit-report.sh ${args[*]}" >&2
exec bash "${SCRIPT_DIR}/credit-report.sh" "${args[@]}"
