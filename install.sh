#!/bin/bash
# Build, install to /Applications and launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Obsidian Reminders"

# Make sure the icon exists before assembling the bundle.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  "$ROOT/Tools/make-icon.sh"
fi

"$ROOT/build.sh" --install

echo "==> Launching"
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
sleep 1
open "/Applications/$APP_NAME.app"

echo
echo "Done. If this is the first launch, approve the two system prompts:"
echo "  1. access to Reminders"
echo "  2. access to your Documents folder"
echo
echo "Logs:    ~/Library/Logs/ObsidianReminders/app.log"
echo "Preview: \"/Applications/$APP_NAME.app/Contents/MacOS/ObsidianReminders\" --dry-run"
