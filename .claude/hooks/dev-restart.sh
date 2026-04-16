#!/bin/bash
# Auto build & restart SpaceWidget when Swift files have been modified.
# Triggered by Claude Code "Stop" hook (after Claude finishes responding).

cd "$(dirname "$0")/../.." || exit 0

# Check if any Swift source files changed (staged or unstaged)
if ! git diff --name-only --diff-filter=d HEAD 2>/dev/null | grep -q '\.swift$' &&
   ! git diff --name-only --diff-filter=d 2>/dev/null | grep -q '\.swift$' &&
   ! git ls-files --others --exclude-standard 2>/dev/null | grep -q '\.swift$'; then
    exit 0
fi

# Check if SpaceWidget is actually running — skip if not
if ! pgrep -x SpaceWidget >/dev/null 2>&1; then
    exit 0
fi

# Build
if ! swift build 2>/dev/null; then
    echo '{"hookSpecificOutput":{"message":"Build failed — skipping restart"}}' >&2
    exit 0
fi

# Restart
killall SpaceWidget 2>/dev/null
nohup .build/debug/SpaceWidget >/dev/null 2>&1 &
disown
