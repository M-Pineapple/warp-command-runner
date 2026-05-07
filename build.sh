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

# Create a convenient symlink
echo "Creating symlink..."
ln -sf .build/release/claude-command-runner claude-command-runner

echo ""
echo "Build complete!"
echo ""
echo "Executable location:"
echo "  $(pwd)/.build/release/claude-command-runner"
echo ""
echo "To install in Warp Terminal:"
echo "1. Open Warp Settings > AI > Manage MCP servers"
echo "2. Click '+ Add' and choose 'CLI Server (Command)'"
echo "3. Use the path: $(pwd)/.build/release/claude-command-runner"
echo "4. Add arguments: --port 9876"
echo ""
echo "To test locally:"
echo "  ./claude-command-runner --verbose"
