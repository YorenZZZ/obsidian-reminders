#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/MakeIcon.swift
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/build/AppIcon.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift "$ROOT/Tools/MakeIcon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "==> Wrote $ROOT/Resources/AppIcon.icns"
ls -la "$ROOT/Resources/AppIcon.icns"
