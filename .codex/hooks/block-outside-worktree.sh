#!/usr/bin/env bash
# Codex PreToolUse guard that keeps edits inside the active git worktree.
# Paths are lexically normalized (`..` collapsed) before comparison, without
# touching the filesystem. Parse or detection failures deliberately fail open
# so this guard remains a worktree-safety backstop rather than a hard wedge.

input=$(cat)

command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$input" | python3 -c '
import json
import os
import re
import subprocess
import sys


def allow():
    sys.exit(0)


def deny(path, root):
    reason = (
        "Path is outside the active worktree (" + root + "). This session runs "
        "in a worktree; rewrite the path under the worktree root before editing. "
        "See AGENTS.md \"Worktree discipline\". Blocked: " + path
    )
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or ""
except Exception:
    allow()

if tool_name not in {"apply_patch", "Edit", "Write"}:
    allow()
if not os.path.isabs(cwd):
    allow()

try:
    root = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
        capture_output=True, check=True, text=True, timeout=10,
    ).stdout.strip()
except Exception:
    allow()
if not root:
    allow()

if tool_name == "apply_patch":
    command = tool_input.get("command") or ""
    paths = re.findall(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", command, re.MULTILINE)
    paths += re.findall(r"^\*\*\* Move to: (.+)$", command, re.MULTILINE)
else:
    path = tool_input.get("file_path") or ""
    paths = [path] if path else []

for path in paths:
    target = os.path.normpath(path if os.path.isabs(path) else os.path.join(cwd, path))
    if target != root and not target.startswith(root.rstrip("/") + "/"):
        deny(path, root)

allow()
'
