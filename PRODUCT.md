# PRODUCT.md — Warp Command Runner v7.0

**Status:** Shipped (2026-08-25)
**Replaces:** Claude Command Runner v6.2.0

v7.0 is a **rebrand**, not a rewrite. The MCP server, 40 tools, Warp deeplinks, and stdio transport are the v6 engine. The product name, identifiers, and docs now describe what the code already was: a host-agnostic MCP that drives Warp, usable from Grok / ChatGPT / Claude / Gemini as long as the *app* speaking MCP is a local host.

See [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) for the honest "can any cloud AI add this?" answer.

The v6.0 notes below are historical (Warp pivot). They still describe the architecture.

---

# Historical: warp-command-runner v6.0

**Status:** Draft (2026-05-07) — kept as design record
**Branch:** `v6.0-warp-pivot`
**Replaces:** v5.0.0

---

## Why v6.0 exists

Warp Terminal went open source under AGPL-3.0 in early May 2026 (`https://github.com/warpdotdev/warp`). That triggered three things:

1. We can finally **prove** what surfaces Warp does and does not expose to external integrators, instead of probing AppleScript and clipboard behaviour by hand.
2. We discovered Warp's **native agent panel** is a full MCP client that loads servers from `~/.warp/.mcp.json` — meaning `warp-command-runner` can serve **two consumers** with the same code: Claude Desktop (over stdio) and Warp's own agent (over the MCP protocol Warp speaks internally).
3. We can identify and remove **dead code** with confidence, replace **fragile AppleScript** paths with `warp://` deeplinks where Warp ships a real entrypoint, and add a **structured event channel** (OSC 777) into Warp's UI that didn't previously exist for us.

v6.0 ships all of the above as a **single coordinated release**. No partial bundles, no incremental punts — one cleanup, one re-architecture, one re-launch.

---

## Who this is for

Two distinct user journeys after v6.0:

### Journey A — "I drive Claude Desktop, and Claude reaches into my terminal"

Unchanged in spirit from v5. The user is in Claude Desktop. Claude needs to run shell commands. `warp-command-runner` is registered in `claude_desktop_config.json`. Claude calls tools; commands appear in (and produce output through) Warp.

**What changes:** the bridging is less fragile. Tab opening uses Warp's native deeplink instead of clicking menu items. Status events become visible in Warp's own UI rather than being invisible state inside the MCP.

### Journey B — "I'm in Warp, and I'm chatting with Warp's agent, which uses my MCP"

**New in v6.0.** The user opens Warp's native agent panel (the one above the terminal, not the cli-agent footer). They type a question. Warp's configured LLM (Claude Sonnet, Opus, GPT, etc.) decides whether to call any of `warp-command-runner`'s 36+ tools. Output renders inline in Warp's chat. The LLM's reply renders inline. The conversation stays in Warp.

The user's MCP **is the integration layer** — same tools, same code path on the server, but now the consumer is Warp's agent rather than Claude Desktop. Configuration is `~/.warp/.mcp.json`.

### Honest caveat

The "Claude" in Journey B is **whichever model is configured in Warp**, *not* the Claude Desktop process. Two conversations, two sessions, both can call the MCP, neither sees the other. v6.0 does not attempt to bridge them — that would require a server-push architecture that doesn't fit MCP and would reinvent Claude Code.

---

## What ships in v6.0

### A. Cleanup

| Change | User impact |
|---|---|
| Remove dead code (`WarpDatabaseIntegration.swift`, `CommandReceiverService.swift`, unused background-monitor path) | Smaller binary; eliminates surface area that would silently break on Warp updates. No tool removed. |
| README claims 30 tools → corrected to **36** | Six previously-undocumented tools (`set_notification_preference`, `cleanup_sessions`, `list_file_watches`, `delete_workspace_profile`, `list_ssh_profiles`, `delete_ssh_profile`) are now documented. |

### B. Deeplinks instead of AppleScript

| Change | User impact |
|---|---|
| `open_terminal_tab` uses `warp://action/new_tab?path=...` | No more menu-clicking. Faster. Opening a tab no longer requires Accessibility permission (only typing into one does). |
| `warp://session/<uuid>` for focus | First time we can reliably *focus* a previously-opened tab on Warp. (Send-input-to-tab still has no Warp API; AppleScript keystroke remains.) |
| New tool: `emit_warp_event` | Surface tool-execution status in Warp's UI via OSC 777. The MCP can now announce "started", "tool_complete", "stop" to whatever Warp pane is focused. |

### C. Workspace profiles align with Warp's launch configs

`save_workspace_profile` now optionally writes a TOML file to `~/.warp/launch_configs/` in addition to the private CCR JSON. Warp recognizes these natively and offers them in its launch UI. Opt-in via a new boolean parameter; existing profiles unaffected.

### D. Warp Agent integration (headline)

**New install path:** documented and supported registration in `~/.warp/.mcp.json`. Once registered, every `warp-command-runner` tool is callable by Warp's native agent.

| Tool category (24 of 36 tools) | Behavior in Warp Agent |
|---|---|
| Pure server-side (clipboard, SSH, env snapshots, file watch, profiles, history, etc.) | Identical behavior to Claude Desktop. No Warp-coupling. |
| Terminal-driving (6 tools) | Behaves correctly when Warp is the active terminal — i.e. Warp's agent calls our tool, our tool drives Warp. Confirmed compatible since the consumer (Warp Agent) and the target (Warp) are the same app. |

**Verification scope** (acceptance criteria below): all 36 tools must be exercised end-to-end via Warp's agent with the same expected outcomes as via Claude Desktop, with Warp-specific edge cases handled cleanly.

### E. Shell shim for block-boundary capture (opt-in beta)

**New optional feature:** a small zsh/bash hook the user can install in their shell rc that mirrors Warp's DCS hook payload to a Unix socket the MCP owns. When enabled, `execute_command` no longer needs to inject a bash wrapper writing to `/tmp/<id>.json` — the MCP receives clean Preexec/CommandFinished events from the user's shell directly.

**Trade-off the user accepts when enabling:** a one-line addition to `~/.zshrc` or `~/.bashrc`. Off by default; v6.0 ships fully without it. Documented as "experimental".

### F. Polish

- Full CHANGELOG v6.0 entry
- README rewrite reflecting dual-consumer architecture
- Install docs: separate sections for Claude Desktop path and Warp Agent path
- Demo material (GIF or recorded session) showing both journeys

---

## Non-goals (deliberately out of scope)

1. **Bridging Claude Desktop conversations into Warp.** The two consumers are independent. We will not build a relay.
2. **Replacing Claude Code.** If the user wants a TUI agent inside a Warp pane, Claude Code already exists. We are tools, not an agent.
3. **Reading Warp's internal SQLite.** The schema migrates aggressively (~80 Diesel migrations in 5 years). Not worth pinning Warp versions.
4. **Becoming a Warp plugin.** No third-party plugin API exists. The cli-agent registry is a closed enum.
5. **Wave Terminal support.** The previous direction was wrong. Wave is not a target.

---

## Acceptance criteria (validation)

### v6.0 ships when ALL of the following are true:

#### Cleanup
- [ ] `swift build -c release` succeeds with zero warnings related to dead-code removal
- [ ] No reference to `WarpDatabaseIntegration` or `CommandReceiverService` remains in `Sources/`
- [ ] README tool count matches dispatch table count (verified by a count-matching unit test or a doc-comment grep)

#### Deeplinks
- [ ] `open_terminal_tab` opens a new Warp tab in the requested directory **without** invoking `osascript` or System Events
- [ ] `warp://session/<uuid>` correctly focuses a previously-opened tab when given the UUID returned at creation time
- [ ] `emit_warp_event` produces an OSC 777 sequence with the documented JSON schema; visible in a Warp pane subscribed to `warp://cli-agent` notifications

#### Workspace profiles
- [ ] `save_workspace_profile path=foo include_warp_launch_config=true` produces a valid TOML file in `~/.warp/launch_configs/` that Warp's launch UI lists
- [ ] Existing JSON profile store is unaffected when the flag is false (default)

#### Warp Agent integration
- [ ] All 36 tools exercised through Warp's native agent panel with the same I/O contract as via Claude Desktop
- [ ] An example `~/.warp/.mcp.json` snippet is in the README
- [ ] Tool dispatch latency from Warp Agent is within 2× of Claude Desktop dispatch (informal benchmark — no API contract)

#### Shell shim (opt-in)
- [ ] Installer script writes ~5 lines to the user's shell rc with a clear marker block
- [ ] Uninstaller cleanly removes those lines
- [ ] When enabled, `execute_command` receives Preexec/CommandFinished events without `/tmp/<id>.json` polling
- [ ] When disabled or not installed, `execute_command` falls back to v5 behavior — no regression

#### Polish
- [ ] CHANGELOG v6.0 lists every user-visible change
- [ ] README has clear "Use with Claude Desktop" and "Use with Warp Agent" sections
- [ ] At least one demo asset (GIF or recording) shows Journey B end-to-end

---

## Risks the user should know about

1. **Warp Agent verification is the unknown unknown.** Warp uses the `rmcp` Rust crate as its MCP client; Claude Desktop uses TypeScript. We've never run our server against `rmcp`. Possible outcomes from Tier D testing: most tools work unchanged, a few need response-format tweaks. Budget: assume some rework.
2. **AGPL hygiene.** Warp is AGPL. We talk to it over IPC (deeplinks, OSC, MCP protocol), so copyleft does not propagate. **But:** we must NOT vendor Warp's `.sh` bootstrap scripts, OSC parsers, or `crates/ipc` source. Reimplement the OSC 777 emitter from spec only.
3. **Shell-shim scope creep.** The temptation will be to make the shim do everything (history sync, completions, status line). Resist. v6.0's shim does block-boundary mirroring only.
4. **Memory of the abandoned Wave direction.** The old codebase had ~1500 lines of Wave-specific work. That's archived as a diff; do not let stale ideas leak into v6.0.
5. **Public release means public scrutiny.** Once v6.0 ships, every fragile AppleScript path users hit will become an issue ticket. Better to acknowledge the keystroke-injection limitation up-front in the README than be surprised by it.

---

## Decisions locked

- Single coordinated release. No partial ship.
- Include the shell shim (Tier E) as opt-in beta, not punt to v6.1.
- Keep AppleScript fallback for `send_to_session` typing — there is no Warp API for it; deletion would break a tool.
- Wave Terminal direction is fully abandoned; archived diff is the only record.
- Branch: `v6.0-warp-pivot` off `main`. Squash-merge or fast-forward at user's preference at release time.
