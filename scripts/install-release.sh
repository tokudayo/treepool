#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${TREEPOOL_REPOSITORY:-tokudayo/treepool}"
BIN_DIR="${TREEPOOL_BIN_DIR:-$HOME/.local/bin}"
ZSH_DIR="${TREEPOOL_COMPLETION_DIR:-$HOME/.local/share/zsh/site-functions}"
BASH_DIR="${TREEPOOL_BASH_COMPLETION_DIR:-$HOME/.local/share/bash-completion/completions}"
FISH_DIR="${TREEPOOL_FISH_COMPLETION_DIR:-$HOME/.config/fish/completions}"
VERSION="${TREEPOOL_VERSION:-${1:-}}"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required." >&2; exit 1; }

if [[ -z "$VERSION" ]]; then
  VERSION="$(curl -fsSI "https://github.com/$REPOSITORY/releases/latest" \
    | sed -n 's|^[Ll]ocation: .*/tag/v\([^[:space:]\r]*\).*|\1|p' \
    | tr -d '\r' | head -1 || true)"
fi
if [[ -z "$VERSION" ]]; then
  echo "GitHub release redirect lookup failed; trying the API." >&2
  VERSION="$(curl -fsSL "https://api.github.com/repos/$REPOSITORY/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)"
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Could not determine a valid release version." >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform="macos-arm64" ;;
  Darwin-x86_64) echo "Treepool v0.1.1 does not support macOS Intel." >&2; exit 2 ;;
  Linux-x86_64) platform="linux-x86_64" ;;
  Linux-aarch64|Linux-arm64) platform="linux-aarch64" ;;
  *) echo "Unsupported platform: $(uname -s) $(uname -m)" >&2; exit 2 ;;
esac

archive="treepool-v${VERSION}-${platform}.tar.gz"
base="https://github.com/$REPOSITORY/releases/download/v${VERSION}"
stage="$(mktemp -d "${TMPDIR:-/tmp}/treepool-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
curl -fsSL "$base/$archive" -o "$stage/$archive"
curl -fsSL "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
expected="$(awk -v file="$archive" '$2 == file { print $1 }' "$stage/SHA256SUMS")"
[[ -n "$expected" ]] || { echo "No checksum found for $archive." >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$stage/$archive" | awk '{print $1}')"
elif command -v shasum >/dev/null; then
  actual="$(shasum -a 256 "$stage/$archive" | awk '{print $1}')"
else
  echo "sha256sum or shasum is required to verify the release." >&2
  exit 1
fi
[[ "$actual" == "$expected" ]] || { echo "Checksum verification failed." >&2; exit 1; }
if tar -tzf "$stage/$archive" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null; then
  echo "Archive contains an unsafe path; refusing to extract." >&2
  exit 1
fi
tar -xzf "$stage/$archive" -C "$stage"

mkdir -p "$BIN_DIR" "$ZSH_DIR" "$BASH_DIR" "$FISH_DIR"
install -m 0755 "$stage/twt" "$BIN_DIR/.twt.new"
mv -f "$BIN_DIR/.twt.new" "$BIN_DIR/twt"
install -m 0644 "$stage/completions/_twt" "$ZSH_DIR/_twt"
install -m 0644 "$stage/completions/twt.bash" "$BASH_DIR/twt"
install -m 0644 "$stage/completions/twt.fish" "$FISH_DIR/twt.fish"
echo "Installed Treepool $VERSION to $BIN_DIR/twt"
echo "Verified: $("$BIN_DIR/twt" --version)"

if [[ ":${PATH:-}:" != *":$BIN_DIR:"* ]]; then
  echo "Note: $BIN_DIR is not on PATH. Add it, then restart your shell:"
  shell_name="${SHELL:-}"
  case "${shell_name##*/}" in
    zsh)
      printf '  echo '\''export PATH="%s:$PATH"'\'' >> %s/.zshrc\n' "$BIN_DIR" "$HOME"
      ;;
    bash)
      printf '  echo '\''export PATH="%s:$PATH"'\'' >> %s/.bashrc\n' "$BIN_DIR" "$HOME"
      ;;
    fish)
      printf '  fish_add_path "%s"\n' "$BIN_DIR"
      ;;
    *)
      printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
      ;;
  esac
fi
