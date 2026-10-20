#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 APP_BINARY" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/treepool-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/package-app.sh" "$1" "$STAGE/Treepool.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install.txt" <<'TEXT'
Drag Treepool.app into Applications, then open it.
Treepool requires macOS 14 or later on Apple Silicon.
This app is ad-hoc signed, without Apple Developer ID signing or notarization.
If macOS blocks it, dismiss the alert, open System Settings > Privacy & Security,
and choose Open Anyway for Treepool, then confirm Open.
See https://support.apple.com/102445 for Apple's instructions.
Install the twt CLI separately using the instructions at:
https://github.com/tokudayo/Treepool#installation
TEXT
mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/treepool-v${VERSION}-macos-arm64.dmg"
hdiutil create -volname Treepool -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
echo "$DMG"
