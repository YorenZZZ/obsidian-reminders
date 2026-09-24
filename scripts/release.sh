#!/bin/bash
# Builds the universal app and zips it for a GitHub release:
#   ./scripts/release.sh            -> build/Obsidian-Reminders.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/build.sh"
cd "$ROOT/build"
rm -f Obsidian-Reminders.zip
ditto -c -k --sequesterRsrc --keepParent "Obsidian Reminders.app" Obsidian-Reminders.zip
echo "==> $ROOT/build/Obsidian-Reminders.zip ($(du -h Obsidian-Reminders.zip | cut -f1))"
