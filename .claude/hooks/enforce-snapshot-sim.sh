#!/usr/bin/env bash
# PreToolUse hook (Bash).
#
# Backstops the pinned iOS snapshot trio (iPhone 17 / iOS 26.4 / Xcode 26.4.1):
# denies any `xcodebuild` command whose concrete iOS-Simulator -destination
# resolves to a different device or runtime, or whose effective Xcode is not the
# pinned version. See enforce-snapshot-sim.py for the full logic and AGENTS.md
# "iOS testing: match CI's Xcode + simulator runtime + iPhone" for why.
#
# Thin wrapper: the deny decision is carried in the PreToolUse JSON the Python
# prints to stdout, NOT the exit code, so this always exits 0. Fails OPEN when
# python3 is unavailable (allows the command) rather than wedging the session.

input=$(cat)

command -v python3 >/dev/null 2>&1 || exit 0

printf '%s' "$input" | python3 "$(dirname "$0")/enforce-snapshot-sim.py"
exit 0
