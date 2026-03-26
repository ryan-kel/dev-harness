#!/usr/bin/env bash
set -euo pipefail

# Install dev-harness as a global 'harness' command
# Requires: claude CLI, python3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SRC="$SCRIPT_DIR/harness.sh"
LINK_PATH="$HOME/.local/bin/harness"

# Check dependencies
if ! command -v python3 &>/dev/null; then
  echo "  Error: python3 is required (for live streaming). Install it first."
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "  Warning: claude CLI not found. Install it: https://docs.anthropic.com/en/docs/claude-code"
fi

# Ensure ~/.local/bin exists and is in PATH
mkdir -p "$HOME/.local/bin"

if [[ -L "$LINK_PATH" || -f "$LINK_PATH" ]]; then
  echo "  Updating existing link at $LINK_PATH"
  rm "$LINK_PATH"
fi

ln -s "$HARNESS_SRC" "$LINK_PATH"
chmod +x "$HARNESS_SRC"

echo ""
echo "  Installed: harness -> $HARNESS_SRC"
echo "  Stream processor: $SCRIPT_DIR/stream_processor.py"
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
