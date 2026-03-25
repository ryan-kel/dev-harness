#!/usr/bin/env bash
set -euo pipefail

# Install dev-harness as a global 'harness' command

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SRC="$SCRIPT_DIR/harness.sh"
LINK_PATH="$HOME/.local/bin/harness"

# Ensure ~/.local/bin exists and is in PATH
mkdir -p "$HOME/.local/bin"

if [[ -L "$LINK_PATH" || -f "$LINK_PATH" ]]; then
  echo "Updating existing link at $LINK_PATH"
  rm "$LINK_PATH"
fi

ln -s "$HARNESS_SRC" "$LINK_PATH"
chmod +x "$HARNESS_SRC"

echo ""
echo "  Installed: harness -> $HARNESS_SRC"
echo ""

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo "  ~/.local/bin is not in your PATH. Add this to your shell rc:"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
else
  echo "  You can now run 'harness' from any project directory."
fi
