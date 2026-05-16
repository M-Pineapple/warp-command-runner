# Using claude-command-runner with Warp's native Agent

**Status:** v6.0 (May 2026) — first-class supported install path.

`claude-command-runner` is a **dual-consumer MCP server**: the same binary serves both Claude Desktop and Warp's built-in agent. Same code, same tools, same behavior — only the consumer differs.

This guide is for the **Warp Agent** path. For Claude Desktop registration, see the main README.

---

## The 60-second story

Warp ships its own native agent panel (the chat box above the terminal output, separate from the cli-agent footer used by Claude Code / Codex / Gemini). That panel is a full **MCP client** — it loads MCP servers from `~/.warp/.mcp.json` and treats the tools they expose as callable actions for whichever LLM you've configured in Warp's AI settings (Claude Sonnet, Opus, GPT, etc.).

Once `claude-command-runner` is registered there, you can:

- Open Warp
- Type a request into the agent panel ("show me the last 20 git commits and group them by author")
- Warp's agent decides which of our 38 tools to call
- Output renders inline in Warp's chat

The "Claude" answering you in Warp is **whichever model you've configured in Warp's AI settings**. That model has access to the *same* tools your Claude Desktop instance does. The two conversations are independent — no relay.

---

## Install

### 1. Build the binary

```bash
cd path/to/claude-command-runner
./build.sh
```

The release binary lands at `.build/release/claude-command-runner`.

### 2. Register with Warp

Two equivalent paths:

**Option A — Settings UI (recommended for first-time setup):**

1. Open Warp → Settings → AI → Manage MCP servers → `+ Add` → `CLI Server (Command)`
2. Path: `/absolute/path/to/claude-command-runner/.build/release/claude-command-runner`
3. Args: leave empty
4. Save

**Option B — `~/.warp/.mcp.json` (for scripted setup):**

```json
{
  "mcpServers": {
    "claude-command-runner": {
      "command": "/Users/you/path/to/claude-command-runner/.build/release/claude-command-runner.app/Contents/MacOS/claude-command-runner",
      "args": []
    }
  }
}
```

> **v6.0.3+** ships a `.app` bundle wrapper around the CLI binary. Point at the binary INSIDE the bundle (the path above). The bundle's `Info.plist` declares the `NSAppleEventsUsageDescription` / `NSInputMonitoringUsageDescription` strings macOS Sequoia needs to actually prompt for TCC permissions on the keystroke-routing tools — without it, those tools silently fail.

A template lives at `config/warp-agent-mcp.json` in this repo — copy, edit the path, drop into `~/.warp/.mcp.json`. If you already have an `mcpServers` entry, merge the keys.

### 3. Restart Warp

Warp loads MCP servers at launch. Restart so it picks up the new config.

### 4. Verify

In Warp's agent panel, type:

> List the tools you have available.

The model should mention `claude-command-runner` tools (`execute_command`, `suggest_command`, `emit_warp_event`, etc.). If it doesn't, check Warp Settings → AI → Manage MCP servers for the server's status.

---

## Tools that shine in the Warp Agent context

All 38 tools work, but a few are particularly natural in Warp:

| Tool | Why it's a fit |
|---|---|
| `execute_command` | Run a command, see output inline in Warp's chat without breaking the conversation |
| `execute_pipeline` | Chain commands with conditional logic; useful for build/test/deploy flows |
| `get_environment_context` | "What's the current git branch / venv / node version?" — one tool call |
| `save_workspace_profile` (with `include_warp_launch_config: true`) | Captures your project context AND emits a Warp launch config so the project shows up in Warp's launch UI |
| `emit_warp_event` | Surface tool-execution status as OSC 777 notifications inside Warp's UI |
| `focus_warp_session` | When you have a Warp session UUID (from the optional shell shim), focus that pane |

---

## What about Claude Code in a Warp pane?

Claude Code is a separate product — a TUI agent that runs inside a Warp pane and uses the cli-agent OSC 777 channel. It can use MCP servers too (via `~/.claude.json`). If you want the same `claude-command-runner` tools available to Claude Code, register it in `~/.claude.json` as well — same `command` path, same args.

These are three independent consumers of the same MCP server:

| Consumer | Config path |
|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Warp's native agent | `~/.warp/.mcp.json` |
| Claude Code | `~/.claude.json` |

You don't need all three. Pick whichever fits your workflow. The MCP server doesn't care.

---

## Honest limitations

1. **You're not chatting with your Claude Desktop instance.** The agent in Warp is Warp's agent, with its own conversation history and its own configured model. We do not bridge the two.
2. **Send-input-to-tab still uses AppleScript keystrokes.** `send_to_session` injects into whichever pane is active — not the named tab in the registry. Warp has no public API for "send input to tab X." Limited improvement until/unless Warp ships one.
3. **Block-level command output capture stays subprocess-based.** `execute_command` still injects a bash wrapper that writes `/tmp/claude_output_<id>.json`. Tier E's optional shell shim is the cleaner alternative for users who want it.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Warp doesn't see the MCP server after editing `.mcp.json` | Warp loads at launch | Quit Warp completely (`⌘Q`), reopen |
| MCP shows "starting…" indefinitely | Binary path wrong, or binary not executable | Verify with `ls -la` and `./claude-command-runner --help` |
| Tools work in Claude Desktop but error in Warp | Response-format mismatch between TS and `rmcp` clients | File an issue with the tool name and the `rmcp` error log |
| `execute_command` opens a new tab unexpectedly | This is `open_terminal_tab` behavior; check which tool the agent called | Ask the agent to use `execute_command` for commands that don't need a visible tab |

For deeper issues, run with `--verbose` and check the log output Warp captures.
