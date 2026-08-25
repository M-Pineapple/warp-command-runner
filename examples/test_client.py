#!/usr/bin/env python3
"""
Minimal stdio MCP client for Warp Command Runner.

This is the whole protocol: spawn the server, JSON-RPC on stdin/stdout.
Any host (Warp, Claude Desktop, ChatGPT desktop, Cursor, a 40-line script)
does the same thing. There is no Claude-specific handshake.

Usage:
  python3 examples/test_client.py /path/to/warp-command-runner
"""

from __future__ import annotations

import json
import os
import subprocess
import sys


def rpc(proc: subprocess.Popen, method: str, params: dict | None = None, msg_id: int = 1) -> dict:
    payload = {"jsonrpc": "2.0", "id": msg_id, "method": method}
    if params is not None:
        payload["params"] = params
    line = json.dumps(payload) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line)
    proc.stdin.flush()
    assert proc.stdout is not None
    raw = proc.stdout.readline()
    if not raw:
        stderr = proc.stderr.read() if proc.stderr else b""
        raise RuntimeError(f"server closed stdout. stderr={stderr!r}")
    return json.loads(raw)


def notify(proc: subprocess.Popen, method: str, params: dict | None = None) -> None:
    payload = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        payload["params"] = params
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def main() -> int:
    binary = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "warp-command-runner"
    )
    binary = os.path.abspath(binary)
    if not os.path.isfile(binary):
        print(f"Binary not found: {binary}", file=sys.stderr)
        print("Build on macOS with ./build.sh, then pass the path to the executable.", file=sys.stderr)
        return 1

    print("Warp Command Runner — stdio MCP example")
    print(f"Spawning {binary}\n")

    proc = subprocess.Popen(
        [binary],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        init = rpc(
            proc,
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "warp-command-runner-example", "version": "7.0.0"},
            },
            msg_id=1,
        )
        server = init.get("result", {}).get("serverInfo", {})
        print(f"initialize → {server.get('name')} v{server.get('version')}")

        notify(proc, "notifications/initialized")

        listed = rpc(proc, "tools/list", {}, msg_id=2)
        tools = listed.get("result", {}).get("tools", [])
        names = [t.get("name") for t in tools]
        print(f"tools/list → {len(names)} tools")
        for name in names[:12]:
            print(f"  - {name}")
        if len(names) > 12:
            print(f"  … {len(names) - 12} more")
        return 0
    finally:
        proc.kill()
        proc.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
