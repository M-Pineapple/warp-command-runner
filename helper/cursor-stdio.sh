#!/bin/sh
# Cursor's MCP host splits `command` on spaces, so
# /Applications/Warp Command Runner.app/... becomes spawn /Applications/Warp ENOENT.
# Warp and Claude Desktop do not have this bug — leave those on the .app path.
# Do not rename the bundle. This wrapper is a path with no spaces.
exec "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner" "$@"
