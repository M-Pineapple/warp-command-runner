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
    echo "Code-signing bare binary with identity: $CCR_CODESIGN_IDENTITY"
    codesign --force --sign "$CCR_CODESIGN_IDENTITY" \
        --identifier claude-command-runner \
        .build/release/claude-command-runner
    NEW_HASH=$(codesign -d --verbose=4 .build/release/claude-command-runner 2>&1 | grep CandidateCDHash | head -1)
    echo "Bare-binary code-signing complete. $NEW_HASH"
else
    echo "(Skipping stable bare-binary code-signing — CCR_CODESIGN_IDENTITY not set.)"
fi

# v6.0.3: wrap the CLI binary in a proper .app bundle with embedded
# Info.plist containing NSXxxUsageDescription strings. Without this,
# modern macOS silently denies TCC permission requests from CLI binaries
# (no prompt ever appears). The bundle gives TCC a proper entity to
# prompt for. See scripts/make-app-bundle.sh for the why and the Info.plist.
echo ""
echo "Creating .app bundle wrapper..."
./scripts/make-app-bundle.sh

# Create a convenient symlink
echo "Creating symlink..."
ln -sf .build/release/claude-command-runner claude-command-runner

echo ""
echo "Build complete!"
echo ""
echo "============================================================"
echo "v6.0.3 install path (RECOMMENDED — needed for keystroke tools):"
echo ""
echo "  $(pwd)/.build/release/claude-command-runner.app/Contents/MacOS/claude-command-runner"
echo ""
echo "Use this path in BOTH:"
echo "  - Claude Desktop:  ~/Library/Application Support/Claude/claude_desktop_config.json"
echo "  - Warp Agent:      ~/.warp/.mcp.json"
echo ""
echo "See config/claude-desktop-config.json and config/warp-agent-mcp.json for templates."
echo "============================================================"
echo ""
echo "Legacy bare-binary path (still works, but the 5 keystroke-routing tools"
echo "will silently fail on macOS Sequoia+ due to missing Info.plist):"
echo "  $(pwd)/.build/release/claude-command-runner"
echo ""
echo "To test locally:"
echo "  ./claude-command-runner --verbose"
