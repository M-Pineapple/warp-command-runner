#!/bin/bash
# Spawn warp-command-runner --http on loopback and prove OAuth + MCP initialize.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-}"

if [[ -z "$BINARY" ]]; then
    for candidate in \
        "$ROOT/.build/release/warp-command-runner" \
        "$ROOT/warp-command-runner" \
        "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner"
    do
        if [[ -x "$candidate" ]]; then
            BINARY="$candidate"
            break
        fi
    done
fi

if [[ -z "${BINARY:-}" || ! -x "$BINARY" ]]; then
    echo "No warp-command-runner binary found."
    echo "Build on macOS with ./build.sh, then: $0 /path/to/warp-command-runner"
    exit 1
fi

python3 "$ROOT/examples/http_test_client.py" "$BINARY"
