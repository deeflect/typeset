#!/bin/sh
# Turn the Developer ID export from Scripts/release.sh into a signed,
# notarized, stapled DMG for a GitHub release.
# Usage: APPLE_API_KEY=<key id> APPLE_API_ISSUER=<issuer> APPLE_API_KEY_PATH=<AuthKey .p8> Scripts/dmg.sh
#    or: NOTARY_PROFILE=<notarytool keychain profile> Scripts/dmg.sh
set -eu

cd "$(dirname "$0")/.."

OUT_DIR=${OUT_DIR:-.build-release}
APP="$OUT_DIR/export/Typeset.app"
[ -d "$APP" ] || { echo "No $APP: run TEAM_ID=<team> Scripts/release.sh first." >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  set -- --keychain-profile "$NOTARY_PROFILE"
else
  set -- --key "${APPLE_API_KEY_PATH:?}" --key-id "${APPLE_API_KEY:?}" --issuer "${APPLE_API_ISSUER:?}"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT_DIR/Typeset-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Notarize and staple the app itself first, so it still opens offline once
# it has been copied out of the DMG.
ditto -c -k --keepParent "$APP" "$STAGE/Typeset.zip"
xcrun notarytool submit "$STAGE/Typeset.zip" "$@" --wait
xcrun stapler staple "$APP"
rm "$STAGE/Typeset.zip"

ditto "$APP" "$STAGE/Typeset.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Typeset -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "$@" --wait
xcrun stapler staple "$DMG"

spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -vv "$APP"
shasum -a 256 "$DMG"
