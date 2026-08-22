#!/usr/bin/env bash
# Fixture tests for Codex PreToolUse repository guardrails.

set -u

repo=$(cd "$(dirname "$0")/../../.." && pwd)
worktree_hook="$repo/.codex/hooks/block-outside-worktree.sh"
snapshot_hook="$repo/.codex/hooks/enforce-snapshot-sim.sh"
failures=0

run_hook() {
  local hook=$1
  local event=$2
  output=$(printf '%s' "$event" | bash "$hook" 2>&1)
  status=$?
}

assert_allowed() {
  if [ "$status" -ne 0 ]; then
    printf 'FAIL: expected allowed event (status %s): %s\n' "$status" "$output"
    failures=$((failures + 1))
  fi
}

assert_denied() {
  local reason=$1
  if [ "$status" -eq 0 ] || [[ "$output" != *'"decision": "deny"'* ]] || [[ "$output" != *"$reason"* ]]; then
    printf 'FAIL: expected denial containing %s (status %s): %s\n' "$reason" "$status" "$output"
    failures=$((failures + 1))
  fi
}

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** End Patch"}}'
assert_allowed

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** Add File: /tmp/escape.txt\n*** End Patch"}}'
assert_denied "outside the active worktree"

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: ../escape.txt\n*** End Patch"}}'
assert_denied "outside the active worktree"

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** Move to: docs/AGENTS-moved.md\n*** End Patch"}}'
assert_allowed

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** Move to: /tmp/escape.txt\n*** End Patch"}}'
assert_denied "outside the active worktree"

run_hook "$worktree_hook" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Add File: '"$repo"'/in-tree.txt\n*** Update File: AGENTS.md\n*** Delete File: docs/obsolete.md\n*** End Patch"}}'
assert_allowed

run_hook "$worktree_hook" '{not JSON'
assert_allowed

run_hook "$worktree_hook" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Add File: /tmp/not-an-edit.txt\n*** End Patch"}}'
assert_allowed

run_hook "$worktree_hook" '{"tool_name":"Edit","cwd":"'"$repo"'","tool_input":{"file_path":"/tmp/compatibility-escape.txt"}}'
assert_denied "outside the active worktree"

run_hook "$snapshot_hook" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"command":"xcodebuild build -destination \"generic/platform=iOS Simulator\""}}'
assert_allowed

run_hook "$snapshot_hook" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"command":"xcodebuild test -destination \"platform=iOS Simulator,name=iPhone 16,OS=26.4\""}}'
assert_denied "pinned simulator"

if [ "$failures" -gt 0 ]; then
  printf 'Hook fixture tests failed: %s\n' "$failures"
  exit 1
fi

printf 'Hook fixture tests passed\n'
