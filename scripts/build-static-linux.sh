#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-x86_64-swift-linux-musl}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/$TARGET"

cd "$ROOT"
swift build -c release --product twt --swift-sdk "$TARGET"
mkdir -p "$OUT"
install -m 0755 ".build/$TARGET/release/twt" "$OUT/twt"
(
  cd "$OUT"
  if command -v sha256sum >/dev/null; then
    sha256sum twt > twt.sha256
  else
    shasum -a 256 twt > twt.sha256
  fi
)
echo "Created $OUT/twt"
