#!/bin/bash
# Runs before `npm pack` / `npm publish`. The npm package does not carry the
# app itself (keeps the upload tiny); it downloads the GitHub release asset
# for its version and checks it against the SHA-256 recorded here.
#
# Release order: ./scripts/release.sh -> gh release create vX.Y.Z build/Obsidian-Reminders.zip -> npm publish
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

plist="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
pkg="$(node -p "require('$ROOT/package.json').version")"
if [ "$plist" != "$pkg" ]; then
  echo "Version mismatch: Info.plist $plist vs package.json $pkg" >&2
  exit 1
fi

url="https://github.com/YorenZZZ/obsidian-reminders/releases/download/v$pkg/Obsidian-Reminders.zip"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
echo "==> Fetching $url"
curl -fsSL --retry 3 "$url" -o "$tmp" || { echo "Release v$pkg has no Obsidian-Reminders.zip yet — publish the GitHub release first." >&2; exit 1; }
shasum -a 256 "$tmp" | cut -d' ' -f1 > "$ROOT/bin/app.sha256"
echo "==> sha256 $(cat "$ROOT/bin/app.sha256")"
