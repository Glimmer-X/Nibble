#!/bin/zsh
# Builds the release for GitHub: signed with a Developer ID, notarized by Apple and stapled.
# Writes build/release/Nibble-VERSION.zip and its .sha256; prints the zip's path last.
#
#   scripts/release.sh
#
# Needs, in local.env: NIBBLE_TEAM (the Developer ID's team) and NIBBLE_NOTARY_PROFILE (a
# notarytool keychain profile, made with `xcrun notarytool store-credentials`); NIBBLE_IDENTITY
# picks a certificate when the team has several. The build has its own DerivedData, so the
# Release build that scripts/link.sh links (development-signed) is left as it is.
set -euo pipefail
source "${0:A:h}/env.sh"

[[ -n "${NIBBLE_TEAM:-}" ]] || { echo "Set NIBBLE_TEAM in local.env." >&2; exit 1; }
[[ -n "${NIBBLE_NOTARY_PROFILE:-}" ]] || { echo "Set NIBBLE_NOTARY_PROFILE in local.env." >&2; exit 1; }
IDENTITY="${NIBBLE_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .*($NIBBLE_TEAM)\)\"/\1/p" | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate of team $NIBBLE_TEAM in the keychain." >&2; exit 1; }

OUT="$BUILD_DIR/release"
DERIVED="$OUT/DerivedData"
mkdir -p "$OUT" "$BUILD_DIR/logs"
LOG="$BUILD_DIR/logs/release.log"

xcodegen generate --quiet --spec project.yml
# Signed while it is built, nested code included: Developer ID, the hardened runtime (on in
# project.yml), a secure timestamp, and none of the debugging entitlement development builds get.
if ! xcodebuild -project Nibble.xcodeproj -scheme Nibble -configuration Release \
        -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$NIBBLE_TEAM" \
        OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        clean build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -30 >&2
    echo "BUILD FAILED (full log: $LOG)" >&2
    exit 1
fi
APP="$DERIVED/Build/Products/Release/Nibble.app"

codesign --verify --strict --deep --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "The app carries get-task-allow; notarization would refuse it." >&2
    exit 1
fi
# Nothing of the machine that built it: no home folder paths or user name in any file.
if grep -rlaF -e "$HOME" -e "/Users/$USER/" "$APP" >/dev/null 2>&1; then
    echo "The app holds paths of this Mac:" >&2
    grep -rlaF -e "$HOME" -e "/Users/$USER/" "$APP" >&2
    exit 1
fi

# Notarize a zip of the app, staple the ticket to the app, then package the stapled app.
SUBMISSION="$TMPDIR/Nibble-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NIBBLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$OUT/Nibble-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
cat "$ZIP.sha256"
echo "$ZIP"
