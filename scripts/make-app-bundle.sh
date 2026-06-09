#!/usr/bin/env bash
# scripts/make-app-bundle.sh
#
# Wrap the built `claude-command-runner` CLI binary into a proper macOS .app
# bundle with embedded Info.plist. v6.0.3 introduced this because modern
# macOS (Sequoia+) silently denies TCC permission requests from CLI binaries
# that lack an Info.plist with NSXxxUsageDescription strings. Wrapping in a
# .app bundle gives TCC a proper entity to prompt for, and the usage strings
# are what macOS displays in the permission dialog.
#
# Without this wrapper, the 5 AppleScript-keystroke-routed tools
# (execute_command, execute_with_auto_retrieve, execute_with_streaming,
# run_template, send_to_session) silently fail with "osascript is not allowed
# to send keystrokes" (error 1002) — no permission prompt ever appears.
#
# Idempotent — re-running overwrites the bundle. Safe to call from build.sh
# after every swift build.
#
# Optional: set CCR_CODESIGN_IDENTITY to also codesign the bundle. This is
# the recommended path (gives the bundle a stable cdhash across rebuilds
# so TCC grants persist).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/release"
BINARY="${BUILD_DIR}/claude-command-runner"
BUNDLE="${BUILD_DIR}/claude-command-runner.app"

# Read version from the Swift source (single source of truth: the
# `static let version` constant). The `|| true` matters: under set -e a
# non-matching grep would otherwise kill the script silently before the
# bundle is created. Fall back to the older `version: "x.y.z"` pattern,
# then to a hardcoded floor.
VERSION=$(grep -E 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' "${PROJECT_ROOT}/Sources/ClaudeCommandRunner/ClaudeCommandRunner.swift" 2>/dev/null | head -1 | sed -E 's/.*version = "([^"]+)".*/\1/' || true)
if [[ -z "${VERSION}" ]]; then
    VERSION=$(grep -E 'version: "[0-9]+\.[0-9]+\.[0-9]+"' "${PROJECT_ROOT}/Sources/ClaudeCommandRunner/ClaudeCommandRunner.swift" 2>/dev/null | head -1 | sed -E 's/.*version: "([^"]+)".*/\1/' || true)
fi
if [[ -z "${VERSION}" ]]; then
    VERSION="6.1.0"
fi

if [[ ! -f "${BINARY}" ]]; then
    echo "make-app-bundle: binary not found at ${BINARY} — run swift build first."
    exit 1
fi

# Tear down any prior bundle so we start clean
rm -rf "${BUNDLE}"

# Create the standard .app skeleton: Contents/MacOS + Contents/Info.plist.
# This is the minimum macOS recognizes as a valid bundle. No Resources,
# no icon — pure CLI-wrapped-in-bundle.
mkdir -p "${BUNDLE}/Contents/MacOS"

# Copy the binary into the bundle. (mv would be faster but cp keeps the
# original at .build/release/claude-command-runner so existing scripts
# that reference that path don't break — backwards compat.)
cp "${BINARY}" "${BUNDLE}/Contents/MacOS/claude-command-runner"

# Write the Info.plist. The three NSXxxUsageDescription keys are the
# critical bits — without them, macOS won't prompt for the corresponding
# TCC permission. LSUIElement=true tells macOS not to show a Dock icon
# when the bundle is launched (we're a CLI, not a UI app).
cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.m-pineapple.claude-command-runner</string>
    <key>CFBundleName</key>
    <string>Claude Command Runner</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Command Runner</string>
    <key>CFBundleExecutable</key>
    <string>claude-command-runner</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claude Command Runner uses AppleEvents to send commands to Warp Terminal so they appear typed in your active tab.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Claude Command Runner needs Input Monitoring to inject keystrokes that drive command execution in your terminal.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Claude Command Runner needs Accessibility access to drive Warp Terminal via System Events for the keystroke-routing tools.</string>
</dict>
</plist>
PLIST

# Codesign the bundle. When you codesign a .app bundle, codesign signs
# the binary inside Contents/MacOS/ AND includes the Info.plist in the
# signature — so the usage descriptions become tamper-evident metadata
# that TCC trusts. Without codesigning, the bundle still works but
# every rebuild produces a different identity (ad-hoc) so TCC grants
# go stale (the same problem v6.0.2 documented for the bare binary).
if [[ -n "${CCR_CODESIGN_IDENTITY:-}" ]]; then
    echo "Code-signing bundle with identity: ${CCR_CODESIGN_IDENTITY}"
    codesign --force --sign "${CCR_CODESIGN_IDENTITY}" \
        --identifier "com.m-pineapple.claude-command-runner" \
        "${BUNDLE}"
    NEW_HASH=$(codesign -d --verbose=4 "${BUNDLE}" 2>&1 | grep CandidateCDHash | head -1)
    echo "Bundle code-signing complete. ${NEW_HASH}"
else
    echo "(Skipping bundle code-signing — CCR_CODESIGN_IDENTITY not set.)"
    echo "  TCC grants for the .app bundle will reset on every rebuild without"
    echo "  it. See README 'Stable code signing'."
fi

echo "App bundle ready at: ${BUNDLE}"
echo "Install path for Claude Desktop / Warp Agent MCP config:"
echo "  ${BUNDLE}/Contents/MacOS/claude-command-runner"
