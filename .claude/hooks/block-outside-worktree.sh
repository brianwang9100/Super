#!/usr/bin/env bash
# PreToolUse hook (Edit | Write | NotebookEdit).
#
# Blocks any file write whose absolute, normalized target path falls outside the
# active git worktree, so edits never silently land in the main repo checkout
# when a session runs inside a worktree (see AGENTS.md "Worktree discipline").
#
# Allowed without challenge:
#   - relative paths (resolve under the session cwd = the worktree)
#   - paths under the current worktree root (`git rev-parse --show-toplevel`)
#   - paths under $HOME/.claude/ (plan files, auto-memory, settings)
#
# The target path is lexically normalized (`..` collapsed) before comparison so
# a path like "<worktree>/../Packages/x.swift" — which resolves into the main
# repo — can't slip past a purely textual prefix check.
#
# Fails OPEN: any parse/detection error allows the write rather than wedging the
# session. This is a backstop for the common paste-an-agent's-absolute-path
# mistake, not a security sandbox.
#
# Denies via the PreToolUse JSON contract (permissionDecision: "deny") so the
# model sees an actionable reason instead of an opaque non-zero exit.

input=$(cat)

# Active worktree root, from the hook's cwd (the session's working directory).
# Not a git repo → nothing to protect; allow.
root=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$root" ] && exit 0

# Parse (from stdin), normalize, and decide in one python pass. The program is
# passed via -c (so the piped JSON stays on stdin) and uses only double quotes
# so it nests inside bash single quotes. os.path.normpath collapses `..`
# lexically without touching the filesystem. Prints the deny JSON, or nothing.
printf '%s' "$input" | HOOK_ROOT="$root" python3 -c '
import json, os, sys
root = os.environ["HOOK_ROOT"]
claude_state = os.path.join(os.path.expanduser("~"), ".claude")
try:
    payload = json.load(sys.stdin)
    path = (payload.get("tool_input") or {}).get("file_path") or ""
except Exception:
    sys.exit(0)
if not path.startswith("/"):
    sys.exit(0)
target = os.path.normpath(path)
def inside(child, parent):
    parent = parent.rstrip("/")
    return child == parent or child.startswith(parent + "/")
if inside(target, claude_state) or inside(target, root):
    sys.exit(0)
reason = (
    "Path is outside the active git worktree (" + root + "). This session runs "
    "in a worktree; absolute paths copied from subagent output, docs, or git "
    "log usually point at the main repo checkout. Rewrite the path under the "
    "worktree root before editing. See AGENTS.md \"Worktree discipline\". "
    "Blocked: " + path
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
'
exit 0
