#!/usr/bin/env bash
# Behavioral checks for the checked-in Codex command policy.

set -u

repo=$(cd "$(dirname "$0")/../../.." && pwd)
rules="$repo/.codex/rules/default.rules"
failures=0

check_allowed() {
  local output
  output=$(codex execpolicy check --rules "$rules" "$@" 2>&1)
  if [[ "$output" != *'"decision":"allow"'* ]]; then
    printf 'FAIL: expected allow for %s: %s\n' "$*" "$output"
    failures=$((failures + 1))
  fi
}

check_not_allowed() {
  local output
  output=$(codex execpolicy check --rules "$rules" "$@" 2>&1)
  if [[ "$output" == *'"decision":"allow"'* ]]; then
    printf 'FAIL: expected normal approval flow for %s: %s\n' "$*" "$output"
    failures=$((failures + 1))
  fi
}

check_allowed git status --short
check_not_allowed git diff --output=/tmp/codex-policy-must-not-write
check_not_allowed git diff --output /tmp/codex-policy-must-not-write
check_not_allowed git log --output=/tmp/codex-policy-must-not-write
check_not_allowed git log --output /tmp/codex-policy-must-not-write

if [ "$failures" -gt 0 ]; then
  printf 'Rule fixture tests failed: %s\n' "$failures"
  exit 1
fi

printf 'Rule fixture tests passed\n'
