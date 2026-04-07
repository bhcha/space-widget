#!/bin/bash
set -e

SIGN_IDENTITY="SpaceWidgetDev"

swift build "$@"
codesign --force --sign "$SIGN_IDENTITY" .build/debug/SpaceWidget
echo "Built and signed with $SIGN_IDENTITY"
