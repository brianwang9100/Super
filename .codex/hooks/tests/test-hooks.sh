#!/usr/bin/env bash
# Fixture tests for Codex PreToolUse repository guardrails.

set -u

repo=$(cd "$(dirname "$0")/../../.." && pwd)
worktree_hook="$repo/.codex/hooks/block-outside-worktree.sh"
snapshot_hook="$repo/.codex/hooks/enforce-snapshot-sim.sh"
hooks_config="$repo/.codex/hooks.json"
nested_cwd="$repo/Packages/Chat"
failures=0

run_hook() {
  local hook=$1
  local event=$2
  output=$(printf '%s' "$event" | bash "$hook" 2>&1)
  status=$?
}

assert_allowed() {
  if [ "$status" -ne 0 ] || [ -n "$output" ]; then
    printf 'FAIL: expected allowed event with no output (status %s): %s\n' "$status" "$output"
    failures=$((failures + 1))
  fi
}

assert_denied() {
  local reason=$1
  if [ "$status" -ne 0 ] \
    || [[ "$output" != *'"hookEventName": "PreToolUse"'* ]] \
    || [[ "$output" != *'"permissionDecision": "deny"'* ]] \
    || [[ "$output" != *'"permissionDecisionReason":'* ]] \
    || [[ "$output" != *"$reason"* ]]; then
    printf 'FAIL: expected denial containing %s (status %s): %s\n' "$reason" "$status" "$output"
    failures=$((failures + 1))
  fi
}

registered_command() {
  local matcher=$1
  node -e '
    const fs = require("node:fs")
    const [configPath, matcher] = process.argv.slice(1)
    const config = JSON.parse(fs.readFileSync(configPath, "utf8"))
    const entry = config.hooks.PreToolUse.find((item) => item.matcher === matcher)
    if (!entry || entry.hooks.length !== 1) process.exit(1)
    process.stdout.write(entry.hooks[0].command)
  ' "$hooks_config" "$matcher"
}

run_registered_hook() {
  local matcher=$1
  local event=$2
  local command
  command=$(registered_command "$matcher") || {
    printf 'FAIL: could not extract registered command for %s\n' "$matcher"
    failures=$((failures + 1))
    return
  }
  output=$(cd "$nested_cwd" && printf '%s' "$event" | bash -c "$command" 2>&1)
  status=$?
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

run_hook "$snapshot_hook" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"cmd":"xcodebuild build -destination \"generic/platform=iOS Simulator\""}}'
assert_allowed

run_hook "$snapshot_hook" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"cmd":"xcodebuild test -destination \"platform=iOS Simulator,name=iPhone 16,OS=26.4\""}}'
assert_denied "pinned simulator"

# Codex runs registered hooks from the session cwd. Exercise both configured
# commands from a nested package so a repository-root-relative path is required.
run_registered_hook "apply_patch|Edit|Write" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** End Patch"}}'
assert_allowed

run_registered_hook "apply_patch|Edit|Write" '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Add File: /tmp/registered-escape.txt\n*** End Patch"}}'
assert_denied "outside the active worktree"

run_registered_hook "exec_command|Bash" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"cmd":"xcodebuild build -destination \"generic/platform=iOS Simulator\""}}'
assert_allowed

run_registered_hook "exec_command|Bash" '{"tool_name":"exec_command","cwd":"'"$repo"'","tool_input":{"cmd":"xcodebuild test -destination \"platform=iOS Simulator,name=iPhone 16,OS=26.4\""}}'
assert_denied "pinned simulator"

if [ "$failures" -gt 0 ]; then
  printf 'Hook fixture tests failed: %s\n' "$failures"
  exit 1
fi

printf 'Hook fixture tests passed\n'
