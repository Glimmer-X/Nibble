#!/bin/zsh
# Builds the app and prints its path on the last line.
#   scripts/build.sh            Debug: "Nibble Dev" (com.glimmer.Nibble.dev)
#   scripts/build.sh release    Release: "Nibble" (com.glimmer.Nibble)
# The full xcodebuild log is build/logs/build.log (replaced on every build).
set -euo pipefail
source "${0:A:h}/env.sh"

case "${1:-debug}" in
    debug) CONFIG=Debug; APP_NAME="Nibble Dev" ;;
    release) CONFIG=Release; APP_NAME="Nibble" ;;
    *) echo "usage: scripts/build.sh [debug|release]" >&2; exit 2 ;;
esac

# Signed by the team in local.env (NIBBLE_TEAM), so privacy permissions such as Screen Recording
# survive rebuilds; without a team, ad hoc (macOS then asks for permissions again after a rebuild).
if [[ -n "${NIBBLE_TEAM:-}" ]]; then
    SIGNING=(DEVELOPMENT_TEAM="$NIBBLE_TEAM" -allowProvisioningUpdates)
else
    SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

xcodegen generate --quiet --spec project.yml
mkdir -p "$BUILD_DIR/logs"
LOG="$BUILD_DIR/logs/build.log"
if ! xcodebuild -project Nibble.xcodeproj -scheme Nibble -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
        "${SIGNING[@]}" build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -30 >&2
    echo "BUILD FAILED (full log: $LOG)" >&2
    exit 1
fi
grep -E "warning:" "$LOG" | grep -v "appintentsmetadataprocessor" | sort -u | head -30 >&2 || true
echo "$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME.app"
