#!/bin/bash
# Runs before `npm pack` / `npm publish`: builds the universal app and puts
# the zip where the npm package expects it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

plist="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
pkg="$(node -p "require('$ROOT/package.json').version")"
if [ "$plist" != "$pkg" ]; then
  echo "Version mismatch: Info.plist $plist vs package.json $pkg" >&2
  exit 1
fi

"$ROOT/scripts/release.sh"
mkdir -p "$ROOT/dist"
cp "$ROOT/build/Obsidian-Reminders.zip" "$ROOT/dist/Obsidian-Reminders.zip"
