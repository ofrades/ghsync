#!/bin/bash
# ghsync installer - Install with: curl -fsSL https://raw.githubusercontent.com/ofrades/ghsync/main/install.sh | bash

set -e

REPO="ofrades/ghsync"
INSTALL_DIR="${GHSYNC_INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_NAME="ghsync"

echo "Installing ghsync..."

# Create install directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Download the script
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/ghsync.sh" -o "$INSTALL_DIR/$SCRIPT_NAME"

# Make it executable
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Check if install dir is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "Add ghsync to your PATH by adding this to your shell config:"
  echo ""
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
fi

echo "ghsync installed to $INSTALL_DIR/$SCRIPT_NAME"
echo ""
echo "Get started:"
echo "  ghsync init <repo-url> [token]"
echo ""
