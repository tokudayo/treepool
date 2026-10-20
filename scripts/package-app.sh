#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 BINARY OUTPUT_APP" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$1"
APP="$2"
[[ ! -e "$APP" ]] || { echo "App destination already exists: $APP" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$BINARY" "$APP/Contents/MacOS/TreepoolMenu"
install -m 0644 "$ROOT/assets/Treepool.icns" "$APP/Contents/Resources/"
install -m 0644 "$ROOT"/Sources/TreepoolMenu/Resources/*.png "$APP/Contents/Resources/"
install -m 0644 "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES" "$APP/Contents/Resources/"
sed "s/@VERSION@/$VERSION/g" "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
