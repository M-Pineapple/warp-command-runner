#!/bin/bash

# Make scripts executable
chmod +x build.sh
chmod +x scripts/patch-swift-sdk.sh
chmod +x examples/run_test.sh
chmod +x examples/test_client.py

echo "Warp Command Runner setup complete!"
echo ""
echo "Next steps:"
echo "1. Run './build.sh' to build the project (macOS)"
echo "2. Register the binary with an MCP host — see docs/COMPATIBILITY.md"
echo "3. Warp Agent: copy config/warp-agent-mcp.json to ~/.warp/.mcp.json and fix the path"
