#!/bin/sh
# Builds a Release archive of Marco and exports it, degrading gracefully
# when there's no signing identity / team on this machine (PLAN §7 M5).
#
# Usage:
#   Scripts/release.sh                # unsigned/ad-hoc local export
#   Scripts/release.sh --dry-run      # print the exact commands, run nothing
#   TEAM_ID=ABCDE12345 Scripts/release.sh                     # Developer ID
#   TEAM_ID=ABCDE12345 EXPORT_METHOD=app-store Scripts/release.sh  # App Store Connect
#
# With no TEAM_ID set (or no matching signing identity installed), this
# still produces a working .app in the archive for local testing/QA — it
# just can't produce a distributable, notarizable export. The script prints
# exactly what's missing for real distribution in that case.
#
# See SHIPPING.md for the full notarization / App Store Connect flow this
# feeds into.
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

TEAM_ID=${TEAM_ID:-}
EXPORT_METHOD=${EXPORT_METHOD:-developer-id}
OUT_DIR=${OUT_DIR:-.build-release}
ARCHIVE_PATH="$OUT_DIR/Marco.xcarchive"
EXPORT_PATH="$OUT_DIR/export"

# --dry-run: print exactly what would run and exit — no project generation,
# no archive, no export. Useful to sanity-check the invocations (paths,
# flags, TEAM_ID plumbing) without paying for a multi-minute archive build.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] '
    for a in "$@"; do printf '%s ' "$a"; done
    printf '\n'
  else
    "$@"
  fi
}

mkdir -p "$OUT_DIR"

echo "==> Generating Xcode project"
run xcodegen generate

echo "==> Archiving Release build"
run xcodebuild -scheme Marco -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/Marco.app"
if [ "$DRY_RUN" != "1" ] && [ ! -d "$APP_PATH" ]; then
  # Name follows Config/App.xcconfig's APP_NAME; fall back to a glob if
  # the app has been renamed since this script was last touched.
  APP_PATH=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
fi
echo "==> Archived: $APP_PATH"

HAS_IDENTITY=0
if [ -n "$TEAM_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAM_ID"; then
  HAS_IDENTITY=1
fi

if [ "$HAS_IDENTITY" = "1" ]; then
  echo "==> Exporting ($EXPORT_METHOD, team $TEAM_ID)"
  PLIST="$OUT_DIR/ExportOptions.plist"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would write $PLIST (method=$EXPORT_METHOD, teamID=$TEAM_ID, signingStyle=automatic)"
  else
    mkdir -p "$OUT_DIR"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$EXPORT_METHOD</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
  fi
  run xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$PLIST"
  echo "==> Exported to $EXPORT_PATH"
  echo ""
  echo "Next steps for real distribution (see SHIPPING.md):"
  echo "  - notarize: xcrun notarytool submit <zip-of-export> --keychain-profile <profile> --wait"
  echo "  - staple:   xcrun stapler staple \"$EXPORT_PATH/Marco.app\""
  if [ "$EXPORT_METHOD" = "app-store" ]; then
    echo "  - upload:   xcrun altool --upload-app -f <pkg> -t macos --apiKey <key> --apiIssuer <issuer>"
    echo "              (or: xcrun notarytool / Transporter.app, then submit for review in App Store Connect)"
  fi
else
  echo "==> No signing identity for TEAM_ID='$TEAM_ID' on this machine."
  echo "    Skipping export — the unsigned archive is still usable for local QA:"
  echo "      open \"$APP_PATH\""
  echo ""
  echo "Missing for a real distributable build:"
  [ -z "$TEAM_ID" ] && echo "  - TEAM_ID env var (your Apple Developer Team ID)"
  echo "  - A Developer ID Application (or Apple Distribution, for App Store) certificate"
  echo "    installed in this machine's keychain and matching TEAM_ID"
  echo "  - Re-run: TEAM_ID=<your-team-id> Scripts/release.sh"
fi
