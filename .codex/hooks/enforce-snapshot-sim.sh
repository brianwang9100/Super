#!/usr/bin/env bash
# Codex PreToolUse wrapper for the pinned iOS snapshot simulator guard.

input=$(cat)

command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$input" | python3 "$(dirname "$0")/enforce-snapshot-sim.py"
