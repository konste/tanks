#!/usr/bin/env bash
set -euo pipefail

# Builds Tanks, stages a signed .app bundle under dist/, and launches it in place — no install to
# /Applications. The dev build:
#   - is signed with a stable Apple Development identity when one exists (keychain grants are keyed
#     to identity + bundle id), otherwise ad-hoc;
#   - uses its own bundle id (dev.konste.tanks), so it never touches OpenUsage's settings,
#     keychain items or process (the binary is named Tanks, so pkill never hits OpenUsage);
#   - has no update feed, no telemetry, no iCloud container.
#
# Usage: script/build_and_run.sh [run|build|logs|verify]
# Env:   CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        CONFIG             "release" (default) or "debug"

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"

TARGET_NAME="Tanks"                     # SwiftPM product / binary name
APP_DISPLAY="Tanks"                     # user-facing app name
CLI_NAME="tanks"
BUNDLE_ID="${BUNDLE_ID:-dev.konste.tanks}"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="0.1.0"
APP_BUILD="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
CLI_BINARY="$APP_HELPERS/$CLI_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SIGN_ENTITLEMENTS="$ROOT_DIR/script/Tanks.entitlements.plist"
ICONSET="$ROOT_DIR/assets/Tanks.iconset"

pkill -x "$TARGET_NAME" >/dev/null 2>&1 || true

# The macOS 27 Command Line Tools default to the 27 SDK, whose SwiftUI expands @State through the
# SwiftUIMacros compiler plugin; only Xcode ships that plugin, so a CLT-only Mac fails with
# "plugin for module 'SwiftUIMacros' not found" (2026-09-27). Fall back to the newest 26.x SDK.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
  CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
  if [[ -d "$CLT_SDKS/MacOSX27.sdk" ]]; then
    FALLBACK_SDK="$(ls -d "$CLT_SDKS"/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$FALLBACK_SDK" ]]; then
      export SDKROOT="$FALLBACK_SDK"
      echo "==> CLT-only toolchain with the 27 SDK; building against $(basename "$FALLBACK_SDK")"
    fi
  fi
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/tanks-cli"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi
if [ ! -x "$BUILD_CLI_BINARY" ]; then
  echo "missing built CLI: $BUILD_CLI_BINARY" >&2
  exit 1
fi

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance on the linked SDK,
# so restamp the sdk to 26.0 while keeping minos at MIN_SYSTEM_VERSION. Re-signed below.
echo "==> stamping linked SDK 26.0 (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Stage every SwiftPM resource bundle (OpenUsage_OpenUsage.bundle carries the provider SVGs and the
# pricing snapshots) into Contents/Resources. Bundle.openUsageResources loads it from there.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Icon: a classic .icns built with iconutil from assets/Tanks.iconset (no actool needed, so this
# works with Command Line Tools alone).
if [ -d "$ICONSET" ]; then
  echo "==> building app icon (iconutil)"
  iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns"
else
  echo "WARNING: $ICONSET missing; continuing without an icon" >&2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION-dev</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Pick a stable Apple Development identity so ad-hoc cdhash churn doesn't re-trigger keychain
# prompts on every rebuild. Fall back to ad-hoc only if none is found.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi

if [ -n "$CODESIGN_IDENTITY" ]; then
  /usr/bin/codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$SIGN_ENTITLEMENTS" \
    "$APP_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$SIGN_ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    launch_app
    echo "==> launched $APP_DISPLAY (dist/$APP_DISPLAY.app)"
    ;;
  build)
    : # build + stage + sign only
    ;;
  logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    launch_app
    sleep 1
    pgrep -x "$TARGET_NAME" >/dev/null && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
