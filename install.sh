#!/usr/bin/env bash
# Install mlxctl by symlinking it into ~/.local/bin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/bin/mlxctl"
DEST_DIR="$HOME/.local/bin"
DEST="$DEST_DIR/mlxctl"

[[ -f "$SRC" ]] || { echo "error: $SRC not found"; exit 1; }

mkdir -p "$DEST_DIR"
ln -sf "$SRC" "$DEST"
chmod +x "$SRC"

echo "Installed: $DEST -> $SRC"

if ! command -v mlxctl >/dev/null 2>&1; then
  echo
  echo "Note: $DEST_DIR is not in your PATH."
  echo "Add this to your shell rc file:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

if ! command -v jq >/dev/null 2>&1; then
  echo
  echo "Note: 'jq' is required. Install with:  brew install jq"
fi
