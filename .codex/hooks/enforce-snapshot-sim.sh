#!/usr/bin/env bash
# Codex PreToolUse wrapper for the pinned iOS snapshot simulator guard.

input=$(cat)

deny_unavailable() {
  # Python cannot produce the normal hook response, so emit a static denial.
  # Unrelated commands do not depend on simulator verification.
  if [[ "$input" == *xcodebuild* && "$input" == *"iOS Simulator"* ]]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Cannot run the simulator guard. Restore Python and the guard before using a concrete iOS simulator destination."}}'
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  deny_unavailable
  exit 0
fi
if result=$(printf '%s' "$input" | python3 "$(dirname "$0")/enforce-snapshot-sim.py"); then
  printf '%s' "$result"
else
  deny_unavailable
fi
