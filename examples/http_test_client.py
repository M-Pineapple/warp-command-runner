#!/usr/bin/env python3
"""Loopback proof for warp-command-runner --http (OAuth + Streamable HTTP MCP)."""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.parse


def pick_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def req(port: int, method: str, path: str, data=None, headers=None, form=False):
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data)
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        else:
            body = json.dumps(data)
            hdrs.setdefault("Content-Type", "application/json")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    conn.request(method, path, body=body, headers=hdrs)
    resp = conn.getresponse()
    raw = resp.read()
    hdr = {k.lower(): v for k, v in resp.getheaders()}
    status = resp.status
    conn.close()
    return status, hdr, raw


def wait_health(port: int, deadline: float) -> None:
    last = None
    while time.monotonic() < deadline:
        try:
            st, _, raw = req(port, "GET", "/health")
            if st == 200 and json.loads(raw).get("ok") is True:
                return
            last = (st, raw)
        except OSError as err:
            last = err
        time.sleep(0.05)
    raise RuntimeError(f"loopback HTTP never became healthy: {last}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: http_test_client.py /path/to/warp-command-runner", file=sys.stderr)
        return 1
    binary = os.path.abspath(sys.argv[1])
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        print(f"not executable: {binary}", file=sys.stderr)
        return 1

    port = pick_port()
    proc = subprocess.Popen(
        [binary, "--http", "--http-port", str(port)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_health(port, time.monotonic() + 15)

        st, _, _ = req(port, "POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "ping"})
        if st != 401:
            raise RuntimeError(f"expected 401 without Bearer, got {st}")

        st, _, raw = req(
            port,
            "POST",
            "/register",
            {"client_name": "loopback-smoke", "redirect_uris": ["http://127.0.0.1/cb"]},
        )
        if st != 201:
            raise RuntimeError(f"DCR failed {st}: {raw!r}")
        client_id = json.loads(raw)["client_id"]

        verifier = secrets.token_urlsafe(32)
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .rstrip(b"=")
            .decode()
        )
        st, hdrs, raw = req(
            port,
            "POST",
            "/authorize",
            {
                "decision": "allow",
                "client_id": client_id,
                "redirect_uri": "http://127.0.0.1/cb",
                "code_challenge": challenge,
                "state": "s1",
                "resource": f"http://127.0.0.1:{port}/mcp",
            },
            form=True,
        )
        if st != 303:
            raise RuntimeError(f"consent failed {st}: {raw!r}")
        code = urllib.parse.parse_qs(urllib.parse.urlparse(hdrs["location"]).query)["code"][0]

        st, _, raw = req(
            port,
            "POST",
            "/token",
            {
                "grant_type": "authorization_code",
                "code": code,
                "client_id": client_id,
                "redirect_uri": "http://127.0.0.1/cb",
                "code_verifier": verifier,
            },
            form=True,
        )
        if st != 200:
            raise RuntimeError(f"token failed {st}: {raw!r}")
        access = json.loads(raw)["access_token"]
        auth = {"Authorization": f"Bearer {access}"}

        st, _, raw = req(
            port,
            "POST",
            "/mcp",
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "http-test-client", "version": "0"},
                },
            },
            headers=auth,
        )
        if st != 200:
            raise RuntimeError(f"initialize failed {st}: {raw!r}")
        info = json.loads(raw)["result"]["serverInfo"]
        print(f"http initialize → {info.get('name')} v{info.get('version')}")

        st, _, raw = req(
            port,
            "POST",
            "/mcp",
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "execute_command",
                    "arguments": {"command": "echo should-not-run"},
                },
            },
            headers=auth,
        )
        body = json.loads(raw)
        if st != 200 or not body["result"].get("isError"):
            raise RuntimeError(f"keystroke tool should be refused: {body}")

        st, _, _ = req(port, "POST", "/revoke", {"token": access}, form=True)
        if st != 200:
            raise RuntimeError(f"revoke failed {st}")
        st, _, _ = req(
            port,
            "POST",
            "/mcp",
            {"jsonrpc": "2.0", "id": 9, "method": "ping"},
            headers=auth,
        )
        if st != 401:
            raise RuntimeError(f"expected 401 after revoke, got {st}")

        print("LOOPBACK_OK")
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
