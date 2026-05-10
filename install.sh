#!/bin/bash
# Install Zet — knowledge system framework
# Usage: curl -fsSL https://raw.githubusercontent.com/xinyun2020/zet/main/install.sh | bash
#
# Options (via env vars):
#   ZET_INSTALL_DIR  Where to install (default: ~/.zet)
#   ZET_BRANCH       Git branch to install (default: main)

set -e

REPO="https://github.com/xinyun2020/zet.git"
INSTALL_DIR="${ZET_INSTALL_DIR:-$HOME/.zet}"
BRANCH="${ZET_BRANCH:-main}"

echo "=== Installing Zet ==="
echo ""

# Check dependencies
for cmd in git bash awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is required but not installed." >&2
        exit 1
    fi
done

# Clone or update
if [ -d "$INSTALL_DIR" ]; then
    echo "Updating existing installation at $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" 2>/dev/null || {
        echo "WARNING: could not pull latest — using existing version"
    }
else
    echo "Cloning Zet to $INSTALL_DIR..."
    git clone --branch "$BRANCH" --depth 1 "$REPO" "$INSTALL_DIR"
fi

# Make CLI executable
chmod +x "$INSTALL_DIR/bin/zet"

# Detect shell and config file
SHELL_NAME="$(basename "$SHELL")"
case "$SHELL_NAME" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    *)    SHELL_RC="" ;;
esac

# Add to PATH if not already there
BIN_PATH="$INSTALL_DIR/bin"
if [ -n "$SHELL_RC" ]; then
    if ! grep -q "$BIN_PATH" "$SHELL_RC" 2>/dev/null; then
        echo "" >> "$SHELL_RC"
        echo "# Zet — knowledge system framework" >> "$SHELL_RC"
        echo "export PATH=\"$BIN_PATH:\$PATH\"" >> "$SHELL_RC"
        echo "Added $BIN_PATH to PATH in $SHELL_RC"
    else
        echo "$BIN_PATH already in PATH"
    fi
else
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$BIN_PATH:\$PATH\""
fi

echo ""
echo "Installed: $("$BIN_PATH/zet" version)"
echo ""
echo "Get started:"
echo "  mkdir my-harness && cd my-harness"
echo "  zet init"
echo "  zet generate"
echo "  zet test"
echo ""
echo "Docs: https://github.com/xinyun2020/zet"
