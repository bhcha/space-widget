#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
APP_NAME="SpaceWidget"
INSTALLED_BIN="/usr/local/bin/$APP_NAME"
DEBUG_BIN="$PROJECT_DIR/.build/debug/$APP_NAME"
STDOUT_LOG="/tmp/spacewidget.stdout"
STDERR_LOG="/tmp/spacewidget.stderr"

cd "$PROJECT_DIR"

pkill -f "/$APP_NAME" 2>/dev/null || true

if [ -x "$INSTALLED_BIN" ]; then
    nohup "$INSTALLED_BIN" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
    echo "Launched installed binary: $INSTALLED_BIN"
    exit 0
fi

swift build
nohup "$DEBUG_BIN" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
echo "Launched debug binary: $DEBUG_BIN"
