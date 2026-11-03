#!/bin/zsh
# Runs the package tests. Extra arguments go to `swift test`, e.g. --filter ConversationSession
set -euo pipefail
source "${0:A:h}/env.sh"

swift test --scratch-path "$BUILD_DIR/swiftpm" "$@"
