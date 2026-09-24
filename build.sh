#!/bin/bash
# Builds "Obsidian Reminders.app" into ./build and (optionally) installs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP_NAME="Obsidian Reminders"
APP="$BUILD/$APP_NAME.app"
BUNDLE_ID="io.github.yorenzzz.obsidian-reminders"

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Swift sources (universal: arm64 + x86_64)"
for ARCH in arm64 x86_64; do
  swiftc \
    -O \
    -target "$ARCH-apple-macosx14.0" \
    -framework AppKit \
    -framework EventKit \
    -framework CoreServices \
    -framework SwiftUI \
    -framework ServiceManagement \
    -o "$BUILD/ObsidianReminders-$ARCH" \
    "$ROOT"/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/ObsidianReminders" \
  "$BUILD/ObsidianReminders-arm64" "$BUILD/ObsidianReminders-x86_64"
rm -f "$BUILD"/ObsidianReminders-*

echo "==> Assembling bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (no AppIcon.icns yet — run Tools/make-icon.sh first)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> Built: $APP"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  osascript -e 'tell application "Obsidian Reminders" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  # Nudge Finder/Dock to pick up the new bundle.
  /usr/bin/touch "/Applications/$APP_NAME.app"
  echo "==> Installed: /Applications/$APP_NAME.app"
fi
