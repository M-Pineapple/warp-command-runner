#!/bin/bash

# Build script for Warp Command Runner

set -e

echo "Building Warp Command Runner..."
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
# Set WCR_CODESIGN_IDENTITY to the name of a code-signing identity in your
# Keychain (e.g. a self-signed cert, or a Developer ID Application cert if
# you have an Apple Developer account). The binary then has a stable cdhash
# across rebuilds and TCC grants persist.
#
# See README "Stable code signing" for cert generation steps.
# If WCR_CODESIGN_IDENTITY isn't set, try to auto-detect a single signing
# identity from the keychain. This prevents the common "forgot to export the
# identity -> ad-hoc build -> TCC grants revoked -> error 1002" trap. Only
# auto-selects when exactly ONE Apple Development / Developer ID identity exists;
# with zero or several it stays unset (set WCR_CODESIGN_IDENTITY yourself).
# Exported so scripts/make-app-bundle.sh inherits it and signs the bundle too.
# v6 used CCR_CODESIGN_IDENTITY — still accepted as an alias.
if [[ -z "${WCR_CODESIGN_IDENTITY:-}" && -n "${CCR_CODESIGN_IDENTITY:-}" ]]; then
    export WCR_CODESIGN_IDENTITY="$CCR_CODESIGN_IDENTITY"
    echo "Using CCR_CODESIGN_IDENTITY (v6 alias) as WCR_CODESIGN_IDENTITY"
fi
if [[ -z "${WCR_CODESIGN_IDENTITY:-}" ]]; then
    AUTO_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E "Apple Development|Developer ID Application" || true)
    AUTO_COUNT=$(printf '%s' "$AUTO_IDENTITIES" | grep -c . || true)
    if [[ "$AUTO_COUNT" -eq 1 ]]; then
        WCR_CODESIGN_IDENTITY=$(printf '%s\n' "$AUTO_IDENTITIES" | awk '{print $2}')
        export WCR_CODESIGN_IDENTITY
        echo "Auto-detected code-signing identity: $WCR_CODESIGN_IDENTITY"
        echo "(Export WCR_CODESIGN_IDENTITY yourself to override.)"
    elif [[ "$AUTO_COUNT" -gt 1 ]]; then
        echo "⚠️  Multiple signing identities found — not auto-selecting one."
        echo "   Set WCR_CODESIGN_IDENTITY explicitly (run: security find-identity -v -p codesigning)."
    fi
fi

if [[ -n "${WCR_CODESIGN_IDENTITY:-}" ]]; then
    echo "Code-signing bare binary with identity: $WCR_CODESIGN_IDENTITY"
    codesign --force --sign "$WCR_CODESIGN_IDENTITY" \
        --identifier warp-command-runner \
        .build/release/warp-command-runner
    NEW_HASH=$(codesign -d --verbose=4 .build/release/warp-command-runner 2>&1 | grep CandidateCDHash | head -1)
    echo "Bare-binary code-signing complete. $NEW_HASH"
else
    echo "⚠️  No signing identity (none auto-detected, WCR_CODESIGN_IDENTITY unset)."
    echo "   Building AD-HOC — the 5 keystroke-routing tools won't receive TCC grants."
    echo "   See README → 'Upgrading from a previous version' / the Sequoia recipe."
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
ln -sf .build/release/warp-command-runner warp-command-runner

echo ""
echo "Build complete!"
echo ""
echo "============================================================"
echo "v6.0.3 install path (RECOMMENDED — needed for keystroke tools):"
echo ""
echo "  $(pwd)/.build/release/warp-command-runner.app/Contents/MacOS/warp-command-runner"
echo ""
echo "Point any MCP host at this path. Templates live in config/:"
echo "  - Warp Agent:      ~/.warp/.mcp.json"
echo "  - Claude Desktop:  ~/Library/Application Support/Claude/claude_desktop_config.json"
echo "  - ChatGPT / Cursor / VS Code / Continue / Gemini CLI: see docs/COMPATIBILITY.md"
echo "============================================================"
echo ""
echo "Legacy bare-binary path (still works, but the 5 keystroke-routing tools"
echo "will silently fail on macOS Sequoia+ due to missing Info.plist):"
echo "  $(pwd)/.build/release/warp-command-runner"
echo ""
echo "To test locally:"
echo "  ./warp-command-runner --verbose"
