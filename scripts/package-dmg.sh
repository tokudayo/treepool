#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 APP_BINARY" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/treepool-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/package-app.sh" "$1" "$STAGE/Treepool.app"
# Keep packaging tools isolated from the developer's Python environment.
TOOLS="$ROOT/.build/dmg-tools"
if [[ ! -x "$TOOLS/bin/python3" ]]; then
  python3 -m venv "$TOOLS"
fi
"$TOOLS/bin/python3" -m pip install --disable-pip-version-check 'dmgbuild==1.6.5'
swift "$ROOT/scripts/dmg-background.swift" "$STAGE/background.png"
mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/treepool-v${VERSION}-macos-arm64.dmg"
"$TOOLS/bin/python3" "$ROOT/scripts/dmg-settings.py" \
  "$STAGE/Treepool.app" "$STAGE/background.png" "$DMG"
hdiutil verify "$DMG"
echo "$DMG"
