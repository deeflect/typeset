#!/bin/sh
# Build an unsigned QA archive, or a signed export when TEAM_ID is supplied.
# Usage: Scripts/release.sh [--dry-run]
#        TEAM_ID=ABCDE12345 EXPORT_METHOD=developer-id|app-store-connect Scripts/release.sh
set -eu

cd "$(dirname "$0")/.."

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
ARCHIVE_PATH="$OUT_DIR/Typeset.xcarchive"
EXPORT_PATH="$OUT_DIR/export"

case "$EXPORT_METHOD" in
  app-store) EXPORT_METHOD=app-store-connect ;;
  developer-id|app-store-connect) ;;
  *) echo "unsupported EXPORT_METHOD: $EXPORT_METHOD" >&2; exit 1 ;;
esac

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run]'
    for arg in "$@"; do printf ' %s' "$arg"; done
    printf '\n'
  else
    "$@"
  fi
}

if [ -n "$TEAM_ID" ]; then
  case "$TEAM_ID" in *[!A-Z0-9]*) echo "invalid TEAM_ID" >&2; exit 1 ;; esac
  if [ "${#TEAM_ID}" -ne 10 ]; then echo "TEAM_ID must be 10 characters" >&2; exit 1; fi
  # App Store uses Xcode automatic signing; Developer ID needs a local identity.
  CERT_CLASS='Developer ID Application:'
  if [ "$DRY_RUN" != 1 ] && [ "$EXPORT_METHOD" = developer-id ] && \
      ! security find-identity -v -p codesigning 2>/dev/null | grep -F "$CERT_CLASS" | grep -Fq "($TEAM_ID)"; then
    echo "Missing $CERT_CLASS signing identity for team $TEAM_ID; archive not started." >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" != 1 ]; then mkdir -p "$OUT_DIR"; fi
run xcodegen generate

if [ -z "$TEAM_ID" ]; then
  run xcodebuild -scheme Marco -configuration Release -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO archive
  echo "Unsigned QA archive: $ARCHIVE_PATH/Products/Applications/Typeset.app"
  exit 0
fi

if [ "$EXPORT_METHOD" = app-store-connect ]; then
  run xcodebuild -scheme Marco -configuration Release -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' "DEVELOPMENT_TEAM=$TEAM_ID" \
    -allowProvisioningUpdates archive
else
  run xcodebuild -scheme Marco -configuration Release -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS' "DEVELOPMENT_TEAM=$TEAM_ID" \
    "CODE_SIGN_IDENTITY=$CERT_CLASS" -allowProvisioningUpdates archive
fi

PLIST="$OUT_DIR/ExportOptions.plist"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] export options: $PLIST (method=$EXPORT_METHOD, teamID=$TEAM_ID, signingStyle=automatic)"
else
  cat > "$PLIST" <<OPTIONS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
OPTIONS
fi
run xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$PLIST" -allowProvisioningUpdates
echo "Exported to $EXPORT_PATH"
if [ "$EXPORT_METHOD" = developer-id ]; then
  echo "Next: notarize and staple the exported app (see SHIPPING.md)."
else
  echo "Next: upload the exported package with Transporter or App Store Connect."
fi
