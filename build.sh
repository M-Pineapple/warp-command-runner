#!/bin/bash

# Build script for Claude Command Runner

set -e

echo "Building Claude Command Runner..."
echo "================================"

# Clean previous builds
echo "Cleaning previous builds..."
swift package clean

# Resolve dependencies (so .build/checkouts/swift-sdk exists for the patch step)
echo "Resolving dependencies..."
swift package resolve

# Apply the swift-sdk strict-concurrency patch (idempotent; required while
# pinned to swift-sdk 0.10.x — see scripts/patch-swift-sdk.sh).
echo "Applying swift-sdk patch..."
./scripts/patch-swift-sdk.sh

# Build in release mode
echo "Building in release mode..."
swift build -c release

# v6.0.2: optionally code-sign the binary with a stable certificate.
#
# Without this step, every `swift build` produces an ad-hoc signed binary
# with a NEW cdhash, which orphans any macOS TCC permission grant from
# previous builds. Symptom: `osascript is not allowed to send keystrokes
# (1002)` silently re-appearing after every rebuild even though System
# Settings → Privacy & Security toggles look correct.
#
# Set CCR_CODESIGN_IDENTITY to the name of a code-signing identity in your
# Keychain (e.g. a self-signed cert, or a Developer ID Application cert if
# you have an Apple Developer account). The binary then has a stable cdhash
# across rebuilds and TCC grants persist.
#
# See README "Stable code signing" for cert generation steps.
if [[ -n "${CCR_CODESIGN_IDENTITY:-}" ]]; then
    echo "Code-signing with identity: $CCR_CODESIGN_IDENTITY"
    codesign --force --sign "$CCR_CODESIGN_IDENTITY" \
        --identifier claude-command-runner \
        --options runtime \
        .build/release/claude-command-runner
    NEW_HASH=$(codesign -d --verbose=4 .build/release/claude-command-runner 2>&1 | grep CandidateCDHash | head -1)
    echo "Code-signing complete. $NEW_HASH"
else
    echo "(Skipping stable code-signing — CCR_CODESIGN_IDENTITY not set.)"
    echo "  TCC permissions for keystroke-routing tools (execute_command etc.)"
    echo "  will break on every rebuild without it. See README 'Stable code"
    echo "  signing' to set up a one-time self-signed cert."
fi

# Create a convenient symlink
echo "Creating symlink..."
ln -sf .build/release/claude-command-runner claude-command-runner

echo ""
echo "Build complete!"
echo ""
echo "Executable location:"
echo "  $(pwd)/.build/release/claude-command-runner"
echo ""
echo "To install with Claude Desktop:"
echo "  Edit ~/Library/Application Support/Claude/claude_desktop_config.json"
echo "  See README Quick Install for the JSON snippet."
echo ""
echo "To install with Warp's native agent panel:"
echo "  Edit ~/.warp/.mcp.json (see docs/WARP_AGENT.md)."
echo ""
echo "To test locally:"
echo "  ./claude-command-runner --verbose"
