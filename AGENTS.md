# Warp Command Runner

Public MIT MCP server (Pineapple / M-Pineapple). Speaks MCP over stdio by default. Opt-in `--http` serves Streamable HTTP on `127.0.0.1` only. Users bring their own HTTPS tunnel. This project does not host a relay.

Done means the verification gate is green, docs match the binary, and the tree has no private identity.

## Boundaries

- Public identity is Pineapple / M-Pineapple only. No private-estate names, maintainer tunnels, or real hostnames in git. Sample origin: `https://mcp.example.com`.
- `--http` binds loopback only. Never `0.0.0.0`.
- Stdio owns stdout. Logs go to stderr.
- Do not commit tokens, tunnel credentials, or `oauth-store.json`.
- No money-path. This is not a trading product.

## Coding standards

SwiftPM CLI + MCP. Match existing files. ArgumentParser for flags. Agent workflow when driving this server: `docs/AGENT_CODING_SOP.md`.

## Verification gate

Run from the repo root on macOS. Quote the summary lines. Triage every failure. There is no Xcode project; skip `xcodebuild`.

1. `swift package resolve && ./scripts/patch-swift-sdk.sh && swift build && swift test`
   Green: `Test Suite 'All tests' passed` with 0 failures.
2. `swift build -c release`
   Green: `.build/release/warp-command-runner` exists.
3. Stdio MCP proof against that binary (not debug):
   `./examples/run_test.sh .build/release/warp-command-runner`
   Green: `initialize → Warp Command Runner v<version>` and `tools/list → 40 tools`.
4. Remote HTTP proof against the same binary:
   `./examples/run_http_test.sh .build/release/warp-command-runner`
   Green: line `LOOPBACK_OK` and initialize version matching `AppIdentity.version`.
5. Version: `AppIdentity.version`, `.build/release/warp-command-runner --version`, CHANGELOG `[X.Y.Z]`, and README "What's new in vX.Y.Z" agree.

Known failures: none. `ProcessRunnerTests.testTimeoutTerminatesHungProcess` waits on a real hung child (timeout API), not a test `sleep`.

Whole-tree hazard: `scripts/patch-swift-sdk.sh` is required while pinned to swift-sdk 0.10.x. `swift test` without the patch fails to compile the SDK.

`--port` was removed in v6. Use `--http-port` for the loopback listener.

## Cold path

A brand-new install will speak stdio MCP when a local host spawns the binary with empty args. It will not be reachable from a phone until the user runs `--http` and publishes their own HTTPS URL.

## Useful paths

- `docs/REMOTE.md` — remote MCP
- `docs/COMPATIBILITY.md` — hosts
- `config/` — stdio snippets
