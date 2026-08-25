#!/usr/bin/env bash
# Install a no-space stdio shim for Cursor (~/.local/bin/warp-command-runner).
# Warp / Claude Desktop should keep using the /Applications bundle path.
set -euo pipefail

APP="/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner"
DEST="${HOME}/.local/bin/warp-command-runner"

if [[ ! -x "$APP" ]]; then
    echo "install-cursor-wrapper: binary not found at:" >&2
    echo "  $APP" >&2
    echo "Install the .app first (see README)." >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
# Copy so Cursor does not depend on this repo staying on disk.
cp "$(cd "$(dirname "$0")" && pwd)/cursor-stdio.sh" "$DEST"
chmod +x "$DEST"
echo "Cursor MCP command (no spaces):"
echo "  $DEST"
echo "Merge config/cursor-mcp.json into ~/.cursor/mcp.json and set command to that path."
