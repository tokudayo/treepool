#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${TREEPOOL_BIN_DIR:-$HOME/.local/bin}"
COMPLETION_DIR="${TREEPOOL_COMPLETION_DIR:-$HOME/.local/share/zsh/site-functions}"
BASH_COMPLETION_DIR="${TREEPOOL_BASH_COMPLETION_DIR:-$HOME/.local/share/bash-completion/completions}"
FISH_COMPLETION_DIR="${TREEPOOL_FISH_COMPLETION_DIR:-$HOME/.config/fish/completions}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/treepool-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"
command -v swift >/dev/null || { echo "Treepool source installation requires Swift 6." >&2; exit 1; }
command -v git >/dev/null || { echo "Treepool requires Git 2.34 or newer." >&2; exit 1; }
swift build -c release --product twt
mkdir -p "$BIN_DIR" "$COMPLETION_DIR" "$BASH_COMPLETION_DIR" "$FISH_COMPLETION_DIR"
install -m 0755 .build/release/twt "$STAGE/twt"
"$STAGE/twt" --generate-completion-script zsh > "$STAGE/_twt"
"$STAGE/twt" --generate-completion-script bash > "$STAGE/twt.bash"
"$STAGE/twt" --generate-completion-script fish > "$STAGE/twt.fish"
install -m 0755 "$STAGE/twt" "$BIN_DIR/.twt.new"
mv -f "$BIN_DIR/.twt.new" "$BIN_DIR/twt"
install -m 0644 "$STAGE/_twt" "$COMPLETION_DIR/_twt"
install -m 0644 "$STAGE/twt.bash" "$BASH_COMPLETION_DIR/twt"
install -m 0644 "$STAGE/twt.fish" "$FISH_COMPLETION_DIR/twt.fish"

if [[ "$(uname -s)" == "Darwin" ]]; then
  APP_DIR="${TREEPOOL_APP_DIR:-$HOME/Applications}"
  swift build -c release --product TreepoolMenu
  APP_STAGE="$STAGE/Treepool.app"
  mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources" "$APP_DIR"
  install -m 0755 .build/release/TreepoolMenu "$APP_STAGE/Contents/MacOS/TreepoolMenu"
  install -m 0644 "$ROOT/assets/Treepool.icns" "$APP_STAGE/Contents/Resources/Treepool.icns"
  install -m 0644 "$ROOT/Sources/TreepoolMenu/Resources/Treepool-symbol-on-dark.png" "$APP_STAGE/Contents/Resources/"
  install -m 0644 "$ROOT/Sources/TreepoolMenu/Resources/Treepool-symbol-on-light.png" "$APP_STAGE/Contents/Resources/"
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  sed "s/@VERSION@/$VERSION/g" "$ROOT/scripts/Info.plist.in" > "$APP_STAGE/Contents/Info.plist"
  codesign --force --sign - "$APP_STAGE"
  rm -rf "$APP_DIR/Treepool.app"
  cp -R "$APP_STAGE" "$APP_DIR/Treepool.app"
  touch "$APP_DIR/Treepool.app"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR/Treepool.app"
  fi
  echo "Installed app: $APP_DIR/Treepool.app"
fi

echo "Installed CLI: $BIN_DIR/twt"

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
