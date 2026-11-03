#!/bin/zsh
# Removes what building produced.
#   scripts/clean.sh         build/ and the generated Xcode project
#   scripts/clean.sh --dev   also the Debug app's data, preferences and privacy permissions
set -euo pipefail
cd "${0:A:h:h}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

pkill -x "Nibble Dev" 2>/dev/null || true
if [[ -d build ]]; then
    find build -name '*.app' -type d -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
fi
rm -rf build .build .swiftpm Nibble.xcodeproj
echo "Removed build products"

if [[ "${1:-}" == "--dev" ]]; then
    DEV_ID=com.glimmer.Nibble.dev
    rm -rf "$HOME/Library/Application Support/$DEV_ID" \
           "$HOME/Library/Caches/$DEV_ID" \
           "$HOME/Library/HTTPStorages/$DEV_ID" \
           "$HOME/Library/Saved Application State/$DEV_ID.savedState"
    defaults delete "$DEV_ID" >/dev/null 2>&1 || true
    tccutil reset All "$DEV_ID" >/dev/null 2>&1 || true
    echo "Removed the Debug app's data, preferences and permissions"
fi
