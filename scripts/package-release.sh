#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 4 ]] || { echo "usage: $0 PLATFORM ARCH BINARY COMPLETION_BINARY" >&2; exit 2; }
PLATFORM="$1"
ARCH="$2"
BINARY="$3"
COMPLETION_BINARY="$4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="treepool-v${VERSION}-${PLATFORM}-${ARCH}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/treepool-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$ROOT/dist" "$STAGE/completions" "$STAGE/LICENSES"
install -m 0755 "$BINARY" "$STAGE/twt"
"$COMPLETION_BINARY" --generate-completion-script zsh > "$STAGE/completions/_twt"
"$COMPLETION_BINARY" --generate-completion-script bash > "$STAGE/completions/twt.bash"
"$COMPLETION_BINARY" --generate-completion-script fish > "$STAGE/completions/twt.fish"
install -m 0644 "$ROOT/LICENSE" "$STAGE/LICENSE"
install -m 0644 "$ROOT/THIRD_PARTY_NOTICES" "$STAGE/THIRD_PARTY_NOTICES"
install -m 0644 "$ROOT/.build/checkouts/swift-argument-parser/LICENSE.txt" "$STAGE/LICENSES/swift-argument-parser.txt"
COPYFILE_DISABLE=1 tar -czf "$ROOT/dist/$NAME.tar.gz" -C "$STAGE" .
echo "$ROOT/dist/$NAME.tar.gz"
