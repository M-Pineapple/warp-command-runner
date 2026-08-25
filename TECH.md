# TECH.md — warp-command-runner v6.0

**Status:** Draft (2026-05-07)
**Branch:** `v6.0-warp-pivot`
**Companion:** [PRODUCT.md](./PRODUCT.md)

---

## Reading order

This document complements `PRODUCT.md`. PRODUCT.md is the **what and why**; TECH.md is the **how, in what order, what we already verified, what we still need to verify**.

---

## 1. Architecture

### 1.1 The dual-consumer model

```
┌─────────────────┐                    ┌─────────────────┐
│ Claude Desktop  │                    │   Warp Agent    │
│   (TS client)   │                    │  (rmcp client)  │
└────────┬────────┘                    └────────┬────────┘
         │ stdio                                │ stdio
         │ MCP protocol                         │ MCP protocol
         └──────────────┬───────────────────────┘
                        │
                        ▼
          ┌─────────────────────────────┐
          │  warp-command-runner      │
          │  (Swift, MCP server)        │
          │  36+ tools                  │
          └─────────────┬───────────────┘
                        │
                        │ Mostly subprocess + filesystem
                        │ Some warp:// deeplinks (Tier B)
                        │ Some OSC 777 emission (Tier B)
                        │ Optional shell-shim socket (Tier E)
                        ▼
          ┌─────────────────────────────┐
          │       Warp Terminal         │
          └─────────────────────────────┘
```

**Two clients calling the same server.** The MCP protocol abstracts the consumer; the server doesn't need to know which is calling. Verification work (Tier D) is to confirm this abstraction holds.

### 1.2 Why not other approaches

| Considered | Rejected because |
|---|---|
| Become a Warp cli-agent (OSC 777 events only) | One-way notification channel; no inbound. Closed enum at `cli_agent.rs:124-160` keeps third parties as `Unknown` only. Doesn't let user *talk to Claude in Warp*. |
| Read Warp's SQLite directly | ~80 Diesel migrations in 5 years; schema renames columns. Stable for one Warp version, breaks the next. `WarpDatabaseIntegration.swift` already proves this approach is fragile (it's currently dead code, never merged into the dispatch). |
| Build a Warp plugin | No third-party plugin API. Internal plugin host is for Warp's own bundled JS. WASM only used for web build. |
| Build a Warp fork | AGPL invocation cascades; massive maintenance burden; defeats the point of an integration product. |
| Bridge Claude Desktop → Warp | Claude Desktop is pull-based; no server-push. Would require inventing a relay. Reinvents Claude Code. Out of scope. |

### 1.3 Tool taxonomy (post-cleanup)

| Class | Count | Examples | Bridge mechanism after v6.0 |
|---|---|---|---|
| Pure server-side | 24 | `copy_to_clipboard`, `ssh_execute`, `add_file_watch`, `save_workspace_profile`, `list_recent_commands` | None — direct Swift, no Warp interaction |
| Subprocess-execution (no Warp) | included above | `execute_pipeline`, `get_environment_context` | `Process` / `/bin/bash -c` |
| Warp-driving (post-cleanup) | 6 | `execute_command`, `execute_with_auto_retrieve`, `execute_with_streaming`, `run_template`, `open_terminal_tab`, `send_to_session` | Deeplinks for *open*; AppleScript keystroke for *type*; `/tmp/<id>.json` polling for *capture* (or shell shim if installed) |
| New in v6.0 | 1+ | `emit_warp_event` | OSC 777 |

---

## 2. Implementation order

The order matters — earlier tiers de-risk later ones.

```
Tier A (cleanup)
  └── lowest risk; pure deletions; build-verifiable
        │
        ▼
Tier B (deeplinks + OSC 777)
  └── new code; build-verifiable; testable without Warp running
        │
        ▼
Tier C (workspace profile alignment)
  └── small change; opt-in flag; doesn't touch existing path
        │
        ▼
Tier D (Warp Agent integration)
  └── verification-heavy; requires Warp running; some rework expected
        │
        ▼
Tier E (shell shim)
  └── separate component; user-installed; gated by flag
        │
        ▼
Tier F (polish, CHANGELOG, README, demo)
```

Each tier ends with a clean commit on `v6.0-warp-pivot`. Build must pass after every commit.

---

## 3. Tier A — Cleanup

### 3.1 Files to delete

| Path | LOC | Reason |
|---|---|---|
| `Sources/WarpCommandRunner/WarpDatabaseIntegration.swift` | 260 | Never reached from any registered tool. Hardcoded Warp schema. Confirmed dead by audit. |
| `Sources/WarpCommandRunner/CommandReceiverService.swift` | ~190 | TCP listener on `127.0.0.1:9876` with `suggest`/`execute`/`ping` mock handlers only. Never invoked from production code. |

### 3.2 Files to edit

| Path | Change |
|---|---|
| `Sources/WarpCommandRunner/CommandHistory.swift` | Remove the single `:218-222` block that referenced `WarpDatabaseIntegration` (it's the only call site, and it's not reachable from a registered tool). Keep the rest of the file (used by `list_recent_commands`). |
| `Sources/WarpCommandRunner/WarpCommandRunner.swift` | Remove any startup wiring that instantiated `CommandReceiverService` (verify in `init` or `run`). |
| `Sources/WarpCommandRunner/CommandHandlers.swift` | The `:386` Task-based background-monitor path is unused. Remove it. The `CommandHandlersStable.swift` path is the live one and stays. |
| `README.md` | Replace "30 tools" with "36 tools" (multiple occurrences). Add the six undocumented tools to the feature listing: `set_notification_preference`, `cleanup_sessions`, `list_file_watches`, `delete_workspace_profile`, `list_ssh_profiles`, `delete_ssh_profile`. |

### 3.3 Verification

```bash
swift build -c release
swift test
grep -r "WarpDatabaseIntegration\|CommandReceiverService" Sources/  # expect 0 hits
```

### 3.4 Commit message

```
chore: remove dead code (WarpDatabaseIntegration, CommandReceiverService, unused background monitor)

- WarpDatabaseIntegration.swift (260 LOC) was never reached from the dispatch
  table. Hardcoded Warp schema; would silently break on Warp updates.
- CommandReceiverService.swift TCP listener (127.0.0.1:9876) had only mock
  handlers; never invoked from production.
- CommandHandlers.swift:386 background-monitor path was disabled to prevent
  server crashes; CommandHandlersStable.swift remains the live path.

README updated to document all 36 registered tools (was claiming 30).
No tool removed; no behavior change.
```

---

## 4. Tier B — Deeplinks and OSC 777

### 4.1 `open_terminal_tab` — switch to deeplink

**Before** (`TerminalSessions.swift:91-101`):
```swift
let script = """
tell application "Warp"
  activate
  tell application "System Events" to tell process "Warp"
    click menu item "New Tab" of menu "Shell" of menu bar 1
    -- ...
  end tell
end tell
"""
runOsascript(script)
```

**After:**
```swift
let url = "warp://action/new_tab?path=\(escapedPath)"
let proc = Process()
proc.launchPath = "/usr/bin/open"
proc.arguments = [url]
try proc.run()
proc.waitUntilExit()
```

**Notes:**
- Path must be percent-encoded (use `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`).
- `open(1)` returns immediately; tab open is async. If we need to know when the tab is ready, fall back to a short delay (300ms) before subsequent operations. This mirrors the AppleScript behavior; not worse.
- No Accessibility permission needed for *opening*. (Still needed for typing.)

### 4.2 `warp://session/<uuid>` focus support

**New behavior:** when we open a tab, capture and persist a session UUID. When the user later requests focus on a previously-opened tab, dispatch `warp://session/<uuid>`.

**Open question:** Warp's `warp://action/new_tab` does not return the new tab's UUID. Approaches:

1. **(preferred)** Mint our own UUID, pass it as a query parameter Warp ignores, but include in our session registry. Use it for deduplication only. Warp's session UUID we can't directly bind to.
2. Subscribe to OSC 777 `session_start` events (which include the session ID) by running our shell shim — but shim is opt-in.
3. Open a tab, then immediately query Warp's SQLite for the most recent `tabs` row (race-prone, schema-fragile).

**Decision:** ship (1) for v6.0. Document the limitation. (2) becomes the "better path" once shell shim is installed. (3) is rejected.

### 4.3 New tool: `emit_warp_event`

**Schema:**
```jsonc
{
  "name": "emit_warp_event",
  "description": "Emit a structured event into Warp's UI via OSC 777. Visible to Warp panes subscribed to warp://cli-agent.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "event_type": {
        "type": "string",
        "enum": ["session_start", "prompt_submit", "tool_complete", "stop", "permission_request", "idle_prompt"]
      },
      "payload": { "type": "object" },
      "session_id": { "type": "string" }
    },
    "required": ["event_type", "payload"]
  }
}
```

**Implementation** (`OSCEmitter.swift`, new file):
```swift
func emitOSC777(event: WarpCliAgentEvent) {
    // Schema reference: warp/app/src/terminal/cli_agent_sessions/event/v1.rs:14-76
    let json = try JSONEncoder().encode(event)
    let hex = json.map { String(format: "%02x", $0) }.joined()
    // OSC 777 ; notify ; warp://cli-agent ; <json> ST
    let sequence = "\u{1B}]777;notify;warp://cli-agent;\(json)\u{07}"
    FileHandle.standardOutput.write(sequence.data(using: .utf8)!)
}
```

**AGPL note:** the JSON schema is observed from Warp's source; we **reimplement**, do not vendor. The `event/v1.rs` types are AGPL; our Swift structs are independent.

### 4.4 Verification

- Build passes
- `open_terminal_tab` opens a tab without `osascript` showing in `Activity Monitor` traces
- `emit_warp_event` produces a string starting `\x1b]777;notify;warp://cli-agent;` and ending `\x07`
- Manual: with Warp running, observe the event in Warp's cli-agent notification UI

### 4.5 Commit messages

```
feat(tab): use warp:// deeplinks for new tab/window operations

Replaces the AppleScript "click menu item New Tab" path that fought with Warp's
focus and timing. open(1) -> warp://action/new_tab is the documented Warp
entrypoint and avoids the Accessibility-permission requirement for the open
path. AppleScript keystroke fallback retained for send_to_session typing —
Warp has no API for sending input to a specific tab.
```

```
feat(events): add emit_warp_event tool for OSC 777 status surfacing

Emits warp://cli-agent JSON events that Warp parses into its notification UI
(see warp/app/src/terminal/cli_agent_sessions/event/v1.rs:14-76). Schema is
reimplemented from the Warp source, not vendored — AGPL hygiene.
```

---

## 5. Tier C — Workspace profile alignment

### 5.1 `~/.warp/launch_configs/` format

Warp expects YAML in `~/.warp/launch_configs/<name>.yaml` (verify by inspecting `crates/warp_core/src/paths.rs` and a sample launch config from a running Warp install). Schema covers:

- `name`
- `windows[]` with `tabs[]` containing `layout`, `commands[]`, `cwd`, `env`

### 5.2 `save_workspace_profile` schema change

Add optional parameter:
```jsonc
{
  "include_warp_launch_config": { "type": "boolean", "default": false }
}
```

When true, after writing the existing JSON, also serialize a Warp-compatible YAML to `~/.warp/launch_configs/<sanitized_name>.yaml`. On `delete_workspace_profile`, if the YAML exists, also delete it (with a flag to be safe).

### 5.3 Verification

- Existing JSON profile flow unchanged when flag is false
- When true, file appears in `~/.warp/launch_configs/`
- Warp's launch UI lists the profile (manual verification)

---

## 6. Tier D — Warp Agent integration

### 6.1 The verification matrix

This is **the hardest tier** because it requires running both Warp and the MCP and exercising tools through Warp's `rmcp` client. We have not previously tested against `rmcp`.

For each of 36 tools:

1. Call from Claude Desktop → record exact response (already known to work in v5)
2. Call from Warp Agent with the same arguments → record response
3. Diff. If different, identify whether:
   - Response format mismatch (e.g. `rmcp` expects different content-type) → server-side fix
   - Behavior mismatch (e.g. tool doesn't make sense in Warp Agent context) → document or skip

**Expected outcomes** (informed prediction, not a guarantee):
- 24 pure server-side tools: identical behavior. ~0 rework.
- 6 Warp-driving tools: identical behavior, since target IS Warp. ~0 rework.
- New `emit_warp_event`: works because it's in the same surface Warp parses.
- Edge cases: long-output tools may stream differently between TS and Rust MCP clients; structured-content tools may need `outputSchema` audited.

**Budget:** assume 1-3 tools need response-format adjustments. Plan for 2 days of test+fix cycle.

### 6.2 `~/.warp/.mcp.json` example

To ship in README:

```json
{
  "mcpServers": {
    "warp-command-runner": {
      "command": "/Users/<you>/Github/warp-command-runner/.build/release/WarpCommandRunner",
      "args": []
    }
  }
}
```

### 6.3 Verification

- Manual matrix run, results recorded in `verification/v6.0-warp-agent-matrix.md` (transient, not checked in to main but kept on the branch during release prep)
- All blocking issues fixed; non-blocking ones become release notes

---

## 7. Tier E — Shell shim (opt-in beta)

### 7.1 Protocol

The shim writes its own structured events to a Unix socket the MCP listens on (e.g. `/tmp/wcr-shell-shim.sock`).

**Wire format** (line-delimited JSON):
```jsonc
{ "type": "preexec",          "block_id": "...", "command": "git status", "ts": "..." }
{ "type": "command_finished", "block_id": "...", "exit_code": 0, "duration_ms": 142, "ts": "..." }
```

The shim parses Warp's DCS payload from the controlling terminal and forwards the relevant fields. **It does not vendor Warp's parser; it observes the documented hex-JSON DCS format and re-decodes it.**

### 7.2 Files

| File | Purpose |
|---|---|
| `helper/shell-shim.zsh` | The script users source from `~/.zshrc` |
| `helper/shell-shim.bash` | Bash equivalent |
| `helper/install-shim.sh` | Idempotent installer that adds a marker block to the user's shell rc |
| `Sources/WarpCommandRunner/ShimSocket.swift` | NIO Unix-domain-socket listener; consumed by execute_command path |

### 7.3 Behavior

- `execute_command` first attempts shim; if shim not connected, falls back to `/tmp/<id>.json` polling (v5 path).
- Shim auto-disables itself if the user opens a non-Warp shell (no Warp DCS hooks to observe).
- Marker block in shell rc is single-line bracketed for clean uninstall.

### 7.4 Verification

- `bash helper/install-shim.sh` adds five clean lines to `~/.zshrc`; second run is no-op.
- `bash helper/uninstall-shim.sh` removes them cleanly.
- With shim active, `execute_command` produces output without `/tmp/<id>.json` files appearing.
- With shim absent, behavior matches v5.

---

## 8. Tier F — Polish

### 8.1 CHANGELOG.md

New top entry, ~50 lines, organized by Tier with user-impact framing.

### 8.2 README.md rewrite

Two-path narrative:
1. **Use with Claude Desktop** (Journey A) — mostly v5 docs, light updates.
2. **Use with Warp Agent** (Journey B) — new section with `~/.warp/.mcp.json` snippet, screenshot of Warp's agent panel calling our tools.

### 8.3 Demo asset

One short GIF (or video) showing a complete Journey B turn: type in Warp, agent calls `execute_command`, output renders, agent replies. Asset path: `assets/demo-warp-agent.gif`.

---

## 9. Risks and open questions

### 9.1 Will tools work as-is via Warp Agent's `rmcp`?

**Unknown until tested.** Highest-risk unknowns:
- Tools that return large output (e.g. `get_environment_context`)
- Tools that use MCP `progress` notifications (`execute_with_streaming`)
- Tools whose `outputSchema` we never tightened

Mitigation: dedicate Tier D's first day to running the matrix and adjusting before any other Tier D work.

### 9.2 Warp UUID binding

Documented in §4.2. Decision: ship (1) for v6.0; revisit when shell shim is GA.

### 9.3 AGPL hygiene checkpoint

Before merging:
- [ ] No verbatim copy of any `crates/ipc/*` content
- [ ] No verbatim copy of any `app/assets/bundled/bootstrap/*.sh`
- [ ] No verbatim copy of OSC parser code from Warp
- All schemas (OSC 777 event JSON, DCS hex-JSON) are reimplemented in our types

### 9.4 Tooling drift

Warp moves fast. The `cli-agent` events we use (`tool_complete`, etc.) might have schema changes by the time we ship. Lock to the v1 schema (`event/v1.rs`); add version detection if/when Warp introduces v2.

---

## 10. Test strategy

### 10.1 Existing test surface

`swift test` — keep all passing. New tests for Tier A cleanup are not necessary (deletions are verified by build + grep).

### 10.2 New unit tests

- `OSCEmitterTests.swift` — emit known event, verify byte sequence
- `DeeplinkBuilderTests.swift` — verify URL construction with edge cases (paths with spaces, unicode, etc.)
- `ShellShimSocketTests.swift` — feed canned DCS payloads, verify parsed events

### 10.3 Manual / integration

- Tier D matrix (per §6.1)
- Shell shim install/uninstall (per §7.4)
- Demo recording

### 10.4 No-go checks before release

- [ ] `swift build -c release` clean (no warnings introduced this branch)
- [ ] `swift test` 100% pass
- [ ] Tier D matrix all-green or documented exceptions
- [ ] AGPL checklist complete (§9.3)
- [ ] CHANGELOG complete

---

## 11. Branching, merge, release

- All work on `v6.0-warp-pivot`
- One commit per Tier (or sub-Tier where logical), squashable later if user prefers
- Release: tag `v6.0.0`, push to `M-Pineapple/warp-command-runner`, draft GitHub Release notes from CHANGELOG
- Memory file `project_claude_command_runner_v6.md` updated with final commit SHA at release time
