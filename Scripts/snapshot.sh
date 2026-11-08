#!/bin/sh
# Headless Markdown → PNG snapshot capture (see SnapshotRunner.swift).
#
# The debug app is sandboxed (App/Sources/Typeset/Typeset.entitlements), so it
# can't read an arbitrary fixture path outside its container — only files
# the user actually picked (Open panel / Finder) or a granted
# FolderAccessStore bookmark are readable. For headless capture there's no
# user to pick anything, so this script builds the Debug app, makes a
# throwaway copy, and re-signs *that copy* ad-hoc with the sandbox
# entitlement stripped, then runs it directly with TYPESET_SNAPSHOT set. The
# checked-in app is untouched; this only affects the disposable copy under
# .build-snap/. (Documented in the M4/J3 "outline sidebar" commit.)
#
# Usage:
#   Scripts/snapshot.sh <markdown-file> [out-dir] [variant] [width] [scale]
#
#   variant: reading (default) | empty
#
# Examples:
#   Scripts/snapshot.sh Tests/Fixtures/sibling-demo/doc.md
#   Scripts/snapshot.sh Tests/Fixtures/outline-demo.md .build-snap reading 540
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

MD_FILE=${1:?"usage: Scripts/snapshot.sh <markdown-file> [out-dir] [reading|empty] [width] [scale]"}
OUT_DIR=${2:-.build-snap}
VARIANT=${3:-reading}
WIDTH=${4:-760}
SCALE=${5:-1.0}

DERIVED_DATA="$ROOT/.build-dd"
UNSANDBOXED_APP="$ROOT/.build-snap/Typeset-unsandboxed.app"

mkdir -p "$OUT_DIR"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Typeset (Debug)"
xcodebuild \
  -project Typeset.xcodeproj \
  -scheme Typeset \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  build >/dev/null

BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Typeset.app"
[ -d "$BUILT_APP" ] || { echo "error: build didn't produce $BUILT_APP" >&2; exit 1; }

echo "==> Re-signing a throwaway copy without the sandbox entitlement"
rm -rf "$UNSANDBOXED_APP"
mkdir -p "$(dirname "$UNSANDBOXED_APP")"
cp -R "$BUILT_APP" "$UNSANDBOXED_APP"

NO_SANDBOX_ENTITLEMENTS=$(mktemp -t typeset-no-sandbox-entitlements).plist
cat > "$NO_SANDBOX_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.print</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --entitlements "$NO_SANDBOX_ENTITLEMENTS" "$UNSANDBOXED_APP"
rm -f "$NO_SANDBOX_ENTITLEMENTS"

ABS_MD_FILE=$(cd "$(dirname "$MD_FILE")" && pwd)/$(basename "$MD_FILE")
ABS_OUT_DIR=$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)

echo "==> Capturing snapshot(s) for $ABS_MD_FILE (variant=$VARIANT)"
TYPESET_SNAPSHOT="$ABS_MD_FILE" \
TYPESET_SNAPSHOT_OUT="$ABS_OUT_DIR" \
TYPESET_SNAPSHOT_VARIANT="$VARIANT" \
TYPESET_SNAPSHOT_WIDTH="$WIDTH" \
TYPESET_SNAPSHOT_SCALE="$SCALE" \
  "$UNSANDBOXED_APP/Contents/MacOS/Typeset"

echo "==> Wrote PNGs to $ABS_OUT_DIR"
