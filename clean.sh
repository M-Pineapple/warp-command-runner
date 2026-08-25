#!/bin/bash

# Clean build script - removes all build artifacts and caches

echo "Cleaning build artifacts and caches..."
echo "====================================="

# Remove local build directory
if [ -d ".build" ]; then
    echo "Removing .build directory..."
    rm -rf .build
fi

# Remove .swiftpm directory
if [ -d ".swiftpm" ]; then
    echo "Removing .swiftpm directory..."
    rm -rf .swiftpm
fi

# Remove Package.resolved if it exists
if [ -f "Package.resolved" ]; then
    echo "Removing Package.resolved..."
    rm -f Package.resolved
fi

# Remove any symlinks
if [ -L "warp-command-runner" ]; then
    echo "Removing symlink..."
    rm -f warp-command-runner
fi

echo ""
echo "Clean complete!"
echo ""
echo "You can now run ./build.sh to build fresh"
