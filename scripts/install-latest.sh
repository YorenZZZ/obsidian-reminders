#!/bin/bash
# One-line installer: downloads the latest release of Obsidian Reminders,
# installs it into /Applications (or ~/Applications) and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/YorenZZZ/obsidian-reminders/main/scripts/install-latest.sh | bash
set -euo pipefail

REPO="YorenZZZ/obsidian-reminders"
APP_NAME="Obsidian Reminders"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Obsidian-Reminders.zip"

major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then
  echo "Obsidian Reminders needs macOS 14 (Sonoma) or later. This Mac runs $(sw_vers -productVersion)."
  exit 1
fi

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $ZIP_URL"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

echo "==> Installing to $DEST"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST/$APP_NAME.app"
ditto "$TMP/$APP_NAME.app" "$DEST/$APP_NAME.app"
# The app is not notarized; clear the download flag so Gatekeeper lets it open.
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true

echo "==> Opening $APP_NAME"
open "$DEST/$APP_NAME.app"
echo
echo "Done. Click \"OK\"/\"Allow\" when macOS asks for access to Reminders (and to your documents folder)."
echo "完成。macOS 询问「提醒事项」（以及文稿文件夹）访问权限时，请点「好」/「允许」。"
