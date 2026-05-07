#!/bin/bash

# Make scripts executable
chmod +x build.sh
chmod +x scripts/patch-swift-sdk.sh
chmod +x examples/run_test.sh
chmod +x examples/test_client.py

echo "Claude Command Runner setup complete!"
echo ""
echo "Next steps:"
echo "1. Run './build.sh' to build the project"
echo "2. Configure Warp Terminal with the MCP server"
echo "3. Test with './examples/run_test.sh'"
