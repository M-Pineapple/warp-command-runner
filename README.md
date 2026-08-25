# Warp Command Runner

<div align="center">
  <img src="assets/icon.svg" width="256" alt="Warp Command Runner — terminal prompt and Warp glyph">
</div>

**Give any chat AI a real terminal.** You ask in Warp, Claude Desktop, ChatGPT desktop, or any other MCP host. The model types the command into your [Warp](https://app.warp.dev/referral/G9W3EY) tab, captures the output, and tells you what happened. Forty tools: command execution, project setups, file watching, SSH, clipboard, environment intelligence. macOS, Swift, open source.

This is for people who **don't live in Cursor or Claude Code**. If you already chat with Grok, ChatGPT, Claude, or Gemini from a desktop app (especially Warp's agent panel), add this MCP and that chat can read your files and run commands on your machine.

> Built for [Warp Terminal](https://app.warp.dev/referral/G9W3EY). The five most powerful tools route commands **visibly** into your active Warp tab. Register the same binary with as many MCP hosts as you want — the server speaks standard MCP over stdio and does not care which model is calling.

**Can any cloud AI use this?** Any **local MCP host** can. A website (grok.com, chatgpt.com, claude.ai in the browser) cannot spawn a process on your Mac. Full matrix: [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

## What's new in v7.0.0 — rebrand

Formerly **Claude Command Runner**. Same engine, host-agnostic name:

- Product, binary, bundle ID, and config dir renamed to Warp Command Runner (`warp-command-runner`, `~/.warp-command-runner`)
- Existing `~/.claude-command-runner` data is copied on first launch (the old folder is left in place)
- MCP `serverInfo` name is `Warp Command Runner` so every host lists it that way
- Config snippets for Warp, Claude Desktop, ChatGPT desktop, Cursor, VS Code, and a generic stdio host
- Honest compatibility doc: stdio MCP works everywhere a local host exists; it is **not** a remote/HTTPS MCP for browser chats

v6.x history (Warp deeplinks, OSC 777, dual-consumer Warp Agent, 40 tools) is unchanged — see [CHANGELOG.md](CHANGELOG.md).

## Overview

Warp Command Runner is an **MCP server**. One binary, any MCP client:

- Execute terminal commands from a conversation
- Chain commands with pipelines and failure modes
- Stream output for long builds
- Save and reuse command templates with variables
- Auto-capture output with intelligent timing
- Track command history
- Read/write the macOS clipboard
- Probe environment context (git, venv, Docker, Node)
- Parse command output into structured JSON
- Manage workspace profiles (optionally as Warp launch configs)
- Open Warp tabs via `warp://` deeplinks and send commands to the active tab
- Watch files and trigger commands on changes
- Execute commands on remote hosts via SSH
- Surface status into Warp as OSC 777 `warp://cli-agent` events
- Optional shell shim: preexec / command-finished events over a Unix socket

## 🧭 Which app should I register this with?

The protocol is MCP. The **value** depends on whether the host is local and whether Warp is your terminal. Details in [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

| Host | Config | Recommended? |
|---|---|---|
| **[Warp Agent](https://app.warp.dev/referral/G9W3EY)** (Grok, Claude, GPT, Gemini — whatever Warp is set to) | `~/.warp/.mcp.json` | Yes — best fit. See [docs/WARP_AGENT.md](docs/WARP_AGENT.md) |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | Yes |
| **ChatGPT desktop** (Connectors / Developer Mode) | host MCP settings; snippet in `config/chatgpt-mcp.json` | Yes, if your plan exposes local MCP |
| **VS Code / Continue / Cline / Windsurf** | their MCP settings; see `config/` | Optional |
| **Cursor** | `~/.cursor/mcp.json` | Optional — Cursor already has a terminal |
| **Claude Code** | `~/.claude.json` | Niche — it already has Bash |
| **Browser chats** (chatgpt.com, grok.com, claude.ai, Gemini web) | — | No. They cannot launch a local stdio server |

### Quick decision tree

- **You use Warp and chat with Grok / ChatGPT / Claude / Gemini inside Warp?** → Register in `~/.warp/.mcp.json`. That's the whole product.
- **You use Claude Desktop (or ChatGPT desktop) and want commands visible in Warp?** → Register there too. Same binary.
- **You use Cursor or Claude Code and want everything in one pane?** → You probably don't need this.
- **You only use a website chatbot?** → This MCP cannot reach that tab. Use a desktop MCP host.

Five of the 40 tools (`execute_command`, `execute_with_auto_retrieve`, `execute_with_streaming`, `run_template`, `send_to_session`) are the Warp-routing ones. The rest are ordinary server-side utilities (clipboard, SSH, snapshots, …) that work from any host.

## 🎯 Key Features

### Command Pipelines
Chain multiple commands with intelligent failure handling:

```json
{
  "steps": [
    {"name": "Build", "command": "swift build", "on_fail": "stop"},
    {"name": "Test", "command": "swift test", "on_fail": "continue"},
    {"name": "Package", "command": "swift build -c release", "on_fail": "stop"}
  ]
}
```

**Failure modes:**
- `stop` – Halt pipeline on failure
- `continue` – Log error and proceed to next step
- `warn` – Show warning and continue

### Output Streaming
Real-time output for long-running commands:

```json
{
  "command": "swift build -c release",
  "update_interval": 3,
  "max_duration": 180
}
```

Perfect for:
- Long compilation processes
- Test suites
- Any command that previously "hung" waiting for output

### Command Templates
Save reusable patterns with variable substitution:

```json
// Save a template
{
  "name": "swift-release",
  "template": "cd {{project}} && swift build -c release",
  "category": "Swift Development",
  "description": "Build Swift project in release mode"
}

// Run with variables
{
  "name": "swift-release",
  "variables": {"project": "~/GitHub/MyApp"}
}
```

Templates are stored in `~/.warp-command-runner/templates.json` and persist across sessions.

### Smart Auto-Retrieve
The `execute_with_auto_retrieve` command intelligently detects command types and adjusts wait times:
- **Quick commands** (echo, pwd): 2-6 seconds
- **Moderate commands** (git, npm): up to 20 seconds  
- **Build commands** (swift build, make): up to 77 seconds
- **Test commands**: up to 40 seconds

## 📊 Why Warp Terminal?

[Warp Terminal](https://app.warp.dev/referral/G9W3EY) is the primary integration target. Other terminals work for the basics — Warp uniquely unlocks deeplinks, OSC 777, the native agent panel, and launch configs:

| Feature | Warp | Terminal.app | iTerm2 |
|---------|------|--------------|---------|
| `warp://` deeplinks for tab/window | ✅ | ❌ | ❌ |
| Native MCP agent panel — chat with Grok, ChatGPT, Claude, Gemini *in* the terminal | ✅ (`~/.warp/.mcp.json`) | ❌ | ❌ |
| OSC 777 cli-agent event channel for status surfacing | ✅ | ❌ | ❌ |
| Workspace profile → recognized launch config | ✅ (`~/.warp/launch_configurations/`) | ❌ | ❌ |
| AppleScript-driven new tab + keystroke send | ✅ | ✅ | ✅ |
| Modern UI/UX | ✅ | ⚠️ | ⚠️ |

Output capture (`/tmp/<id>.json` polling) and the tools that don't touch the terminal (clipboard, SSH, file watch, env snapshots, etc.) work identically across all terminals.

> Download Warp from [warp.dev](https://app.warp.dev/referral/G9W3EY). It is free, and the Warp-specific surfaces above need it.

## Installation

### Prerequisites
- macOS 13.0 or later
- Swift 6.0+ (Xcode 16+)
- At least one **local MCP host** (Warp Agent, Claude Desktop, ChatGPT desktop, VS Code, …) — not a browser chat tab
- A supported terminal ([Warp](https://app.warp.dev/referral/G9W3EY) strongly recommended)

### Quick Install

1. Clone and build:
```bash
git clone https://github.com/M-Pineapple/warp-command-runner.git
cd warp-command-runner

# For the 5 keystroke-routing tools (execute_command, etc.) to work, the build
# must be SIGNED with your code-signing identity. build.sh auto-detects a single
# Apple Development / Developer ID identity; to be explicit (or if you have
# several), export it first — find yours with:
#   security find-identity -v -p codesigning
export WCR_CODESIGN_IDENTITY="<your-cert-sha1>"   # optional if auto-detect finds one; persist in ~/.zshrc
./build.sh
```
> Only need the 34 non-keystroke tools (incl. `execute_pipeline`)? An unsigned build is fine — skip the `export`.

2. **Pick your MCP host(s)** — you can register the same binary in several. Point at the binary **inside** the `.app` bundle (macOS Sequoia+ needs the Info.plist for TCC prompts on the 5 keystroke-routing tools):

   **A — Warp Agent** (`~/.warp/.mcp.json`) — Grok, ChatGPT, Claude, Gemini, whichever Warp is set to:
   ```json
   {
     "mcpServers": {
       "warp-command-runner": {
         "command": "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner",
         "args": []
       }
     }
   }
   ```
   See [`docs/WARP_AGENT.md`](docs/WARP_AGENT.md).

   **B — Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`) — same JSON shape. ChatGPT desktop, Cursor, VS Code, Continue: copy a snippet from [`config/`](config/README.md) or [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

   After `./build.sh` you can also point at `$(pwd)/.build/release/warp-command-runner.app/Contents/MacOS/warp-command-runner` before copying the bundle to `/Applications/`.

   > **Upgrading from v6.0.0–6.0.2?** Edit your existing config file and append `.app/Contents/MacOS/warp-command-runner` to the path. The legacy bare-binary path still works for the 34 non-keystroke tools, but `execute_command` / `execute_with_auto_retrieve` / `execute_with_streaming` / `run_template` / `send_to_session` will silently fail without the bundle path.

3. **Grant Accessibility permission** (only required for `send_to_session` keystroke injection in v6.0; tab/window opening uses deeplinks and does not require it):
   - Open **System Settings → Privacy & Security → Accessibility**
   - Click **+** and navigate to `warp-command-runner/.build/release/`
   - Press **Cmd+Shift+.** to reveal the hidden `.build` folder
   - Select the `warp-command-runner` binary and toggle it **on**

> **Important:** macOS tracks permissions by binary identity. After every rebuild (`./build.sh`), you must remove the old entry and re-add the new binary in Accessibility settings.

4. **Restart your MCP host(s)** (Warp, Claude Desktop, ChatGPT desktop, …).

5. **(Optional)** Install the shell shim for cleaner block-boundary capture:
   ```bash
   helper/install-shim.sh
   ```
   See `helper/shell-shim.zsh` / `helper/shell-shim.bash` for the implementation. Uninstall with `helper/uninstall-shim.sh`.

### Upgrading from a previous version

If you already have a signed install working (TCC permissions granted), upgrading is:

```bash
cd warp-command-runner
git pull

# Rebuild with the SAME signing identity you used originally. Without it, build.sh
# falls back to an ad-hoc-signed bundle, macOS sees a new identity, and your
# keystroke (TCC) grants stop applying → error 1002 on execute_command.
# (build.sh auto-detects a single identity; export to be explicit.)
export WCR_CODESIGN_IDENTITY="<your-cert-sha1>"   # persist in ~/.zshrc so you don't forget
./build.sh

# Confirm it signed with your cert (NOT adhoc) BEFORE replacing your good bundle:
codesign -dvv .build/release/warp-command-runner.app 2>&1 | grep -E "Authority=Apple|Signature=adhoc"

# Replace the deployed bundle (rm first — cp -R onto an existing .app nests it):
rm -rf "/Applications/Warp Command Runner.app"
cp -R .build/release/warp-command-runner.app "/Applications/Warp Command Runner.app"
```

Then restart your MCP host. If you upgraded from v6 and kept the same signing certificate, existing TCC grants on `com.m-pineapple.claude-command-runner` do **not** transfer to `com.m-pineapple.warp-command-runner` — re-grant Accessibility / Input Monitoring / Full Disk Access / Automation for the new bundle once. After that, same-cert rebuilds keep the grants.

### 🛡️ macOS Sequoia full setup recipe (the 7 ordered steps)

> If `execute_command` / `execute_with_auto_retrieve` / `execute_with_streaming` / `run_template` / `send_to_session` fail with `osascript is not allowed to send keystrokes (1002)` even though you've toggled every panel in System Settings, **follow this in order — skipping any step leaves a silent denial somewhere in the chain.** The other 34 tools work without any of this; `execute_pipeline` is a fully-functional substitute if you want to skip the whole TCC saga entirely.
>
> This is the empirically-verified recipe from a real 6-hour debugging session. v6.0.3+ ships the bundle infrastructure that makes this possible; v6.0.4 is this documentation pass.

**The denial pattern.** macOS Sequoia's TCC and sandbox have layered, *non-obvious* requirements for CLI binaries that drive `osascript → System Events → keystroke`. The error message is misleading — the actual block usually isn't keystroke permission; it's an earlier preflight check that silently aborts the chain. The five gates, in the order macOS evaluates them:

| Gate | TCC service | What grants it |
|---|---|---|
| 1. Bundle promptability | (n/a — policy) | Bundle in `/Applications/`, not `.build/release/` |
| 2. Bundle identity stable | (n/a — codesign) | Signed with a stable cert (cdhash doesn't drift across rebuilds) |
| 3. Sandbox FDA preflight | `kTCCServiceSystemPolicyAllFiles` | Full Disk Access grant on the bundle |
| 4. AppleEvents | `kTCCServiceAppleEvents` | Automation → System Events ☑ |
| 5. Keystroke synthesis | `kTCCServiceListenEvent` / `kTCCServicePostEvent` | Input Monitoring + Accessibility |

#### Step 1 — Have an Apple Development cert (or self-signed Code Signing cert)

If you have a paid Apple Developer account, you already have one (check via `security find-identity -v -p codesigning`). If not, create a self-signed one:

1. **Keychain Access** → menu **Certificate Assistant → Create a Certificate…**
2. Name: `warp-command-runner`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**
3. Click **Create** → **Continue** through warnings → **Done**

Export the cert identifier for `build.sh` to find:
```bash
# Get the SHA-1 hash (more reliable than the cert name)
security find-identity -v -p codesigning
# Then in your shell rc (~/.zshrc, ~/.config/fish/config.fish, etc.):
export WCR_CODESIGN_IDENTITY="<the-sha1-hash-from-above>"
```

#### Step 2 — Build (creates the signed `.app` bundle)

```bash
./build.sh
```

`build.sh` invokes `scripts/make-app-bundle.sh`, which wraps the CLI in `.build/release/warp-command-runner.app/` with a proper `Info.plist` (CFBundleIdentifier `com.m-pineapple.warp-command-runner`, the three required `NSXxxUsageDescription` strings, LSUIElement=true). If `WCR_CODESIGN_IDENTITY` is set, the bundle is signed with that cert as a unit — stable cdhash across rebuilds.

**Verify:**
```bash
codesign --display --verbose=4 .build/release/warp-command-runner.app | grep -E 'Identifier|TeamIdentifier|CDHash'
codesign --verify --deep --strict .build/release/warp-command-runner.app  # should succeed silently
```

#### Step 3 — Install the bundle into `/Applications/` (CRITICAL)

**macOS refuses to prompt for TCC permissions on bundles in `.build/release/` or other dev directories.** The bundle must live in `/Applications/`. Copy it:

```bash
cp -R .build/release/warp-command-runner.app "/Applications/Warp Command Runner.app"
```

Verify the signature survived the copy:
```bash
codesign --verify --deep --strict "/Applications/Warp Command Runner.app"
```

#### Step 4 — Point your MCP config at the `/Applications/` path

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "warp-command-runner": {
      "command": "/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner",
      "args": []
    }
  }
}
```

Mirror in `~/.warp/.mcp.json` if you use the Warp Agent path.

#### Step 5 — Reset stale TCC entries for the bundle ID

If you've been struggling with TCC denials previously, your TCC.db likely has stale `Denied` entries from earlier rebuilds with different cdhashes. Wipe them for the bundle:

```bash
for svc in AppleEvents ListenEvent PostEvent Accessibility; do
    tccutil reset "$svc" com.m-pineapple.warp-command-runner
done
```

Each line should print "Successfully reset". If you see "no entries", that's also fine — means TCC had nothing recorded yet.

#### Step 6 — Grant the *three* TCC permissions (Full Disk Access is the surprise one)

In **System Settings → Privacy & Security**, add `/Applications/Warp Command Runner.app` to each of:

1. **Full Disk Access** — *unexpected but mandatory.* macOS sandbox does a preflight check for `kTCCServiceSystemPolicyAllFiles` before allowing osascript to spawn for keystroke chains. Without FDA on the bundle, the sandbox denies before TCC's AppleEvents check ever fires, and you get the misleading "send keystrokes" error.
2. **Input Monitoring** — for `kTCCServiceListenEvent` / `kTCCServicePostEvent` (synthetic keystroke generation).
3. **Accessibility** — for the `keystroke` AppleEvent action itself.

Each grant requires Touch ID / admin password to confirm. **Bundle name appears as "Warp Command Runner"** in the panels.

#### Step 7 — Restart Claude Desktop, trigger once, grant the Automation prompt

`⌘Q` Claude Desktop, reopen. On your first `execute_command`, macOS may show one more prompt — **Automation → "Warp Command Runner wants to control System Events"** — click Allow. After that, it's permanent. Future rebuilds don't reset anything (the cert keeps cdhash stable; the bundle keeps the identity stable).

---

### Diagnostic: what does TCC see right now?

If something doesn't work after the recipe, the only reliable way to figure out which gate is failing is the TCC log:

```bash
log show --predicate 'process == "tccd"' --last 30s --info --debug \
    | grep -E 'AUTHREQ_CTX|AUTHREQ_RESULT|m-pineapple|promptPolicy|Service Policy'
```

Trigger an `execute_command` first, then immediately run the above. Read it for:
- `service="kTCCServiceXxx"` — which permission category is being checked
- `promptPolicy = 0` → macOS refuses to even prompt; usually a location problem (bundle not in `/Applications/`)
- `promptPolicy = 2` + `Denied (Service Policy)` → you're missing the permission for the named service
- `AttributionChain: responsible={identifier=com.m-pineapple.warp-command-runner, ...}` → good, TCC is identifying us correctly

### If you really can't get it working

`execute_pipeline` is a fully-functional substitute for `execute_command`:

```jsonc
// instead of execute_command: {"command": "git status"}
// use:
{"steps": [{"command": "git status"}]}
```

Pure subprocess, no AppleScript, no TCC layer, captures output cleanly, works on any macOS version regardless of permissions. The visible side-effect (command appearing in your Warp tab) is the only thing you lose — for most agent workflows that's not what you actually need anyway.

---

## Usage

### Available Tools (40)

#### Core Execution

| Tool | Description | Use Case |
|------|-------------|----------|
| `execute_command` | Execute with manual output retrieval | Simple commands |
| `execute_with_auto_retrieve` | Execute with intelligent auto-retrieval | Most common usage ⭐ |
| `execute_pipeline` | Chain commands with conditional logic | Build workflows, CI/CD |
| `execute_with_streaming` | Real-time output streaming | Long builds, test suites |
| `save_template` | Save reusable command pattern | Create shortcuts |
| `run_template` | Execute saved template with variables | Run saved patterns |
| `list_templates` | View all saved templates | Manage templates |
| `delete_template` | Remove a saved template by name | Manage templates |
| `get_command_output` | Manually retrieve command output | Debugging |
| `preview_command` | Preview without executing | Safety check |
| `suggest_command` | Suggest commands (pass `working_directory` for git/Swift/Node-aware ideas) | Discovery |
| `list_recent_commands` | View command history | Analytics |
| `self_check` | System health diagnostics | Troubleshooting |

#### Clipboard (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `copy_to_clipboard` | Write text to macOS clipboard | Share output |
| `read_from_clipboard` | Read current clipboard content | Paste context |

#### Notifications (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `set_notification_preference` | Toggle macOS notifications | Personalisation |

#### Environment Intelligence (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `get_environment_context` | Probe git, venv, Node, Docker state | Context awareness |
| `execute_and_parse` | Execute and parse output to structured JSON | Smart output |
| `capture_environment` | Snapshot your real shell environment (sources your login profile) | Before/after comparison |
| `diff_environment` | Compare two environment snapshots | Change detection |

#### Workspace Profiles (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `save_workspace_profile` | Save project context as named profile | Project switching |
| `load_workspace_profile` | Restore a saved project context | Resume work |
| `list_workspace_profiles` | View all saved profiles | Organisation |
| `delete_workspace_profile` | Remove a workspace profile | Cleanup |

#### Multi-Terminal Sessions (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `open_terminal_tab` | Open a new named terminal tab (Warp: via `warp://action/new_tab` deeplink in v6.0) | Long-running processes |
| `send_to_session` | Send command to a specific tab (AppleScript keystroke; tab-targeting limited on Warp) | Targeted execution |
| `list_sessions` | View active terminal sessions | Session overview |
| `close_session` | Close a named session | Cleanup |
| `cleanup_sessions` | Bulk-remove stale sessions; optionally close their tabs | Hygiene |

#### Interactive Command Detection (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `check_interactive` | Classify a command for TTY/stdin requirements before running it | Avoid hangs from `vim`, `ssh`, `psql`, REPLs |

#### File Watching (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `add_file_watch` | Watch directory and trigger command on changes | Auto-rebuild, auto-test |
| `remove_file_watch` | Stop watching a directory | Cleanup |
| `list_file_watches` | View active watchers | Overview |

#### SSH Remote Execution (v5.0)

| Tool | Description | Use Case |
|------|-------------|----------|
| `ssh_execute` | Run command on remote host via SSH | Remote ops |
| `save_ssh_profile` | Save SSH connection profile | Quick connect |
| `list_ssh_profiles` | View saved SSH profiles | Overview |
| `delete_ssh_profile` | Remove an SSH profile | Cleanup |

#### Warp v6.0 — deeplinks, OSC 777, shell shim

| Tool | Description | Use Case |
|------|-------------|----------|
| `focus_warp_session` | Dispatch `warp://session/<uuid>` to focus a Warp pane (UUID must be one Warp recognises — typically from the optional shell shim's events) | Resume work in a specific pane |
| `emit_warp_event` | Build a `printf` invocation that emits an OSC 777 `warp://cli-agent` JSON event into Warp's UI. Schema: `session_start` / `prompt_submit` / `tool_complete` / `stop` / `permission_request` / `idle_prompt`. The returned `printf` must be run inside a Warp pane (e.g. via `execute_command`) to take effect | Status notifications |
| `shell_shim_status` | Report optional shell-shim socket state and recent events | Verify shim is wired up |

### Example Workflows

**Simple Command:**
```
You: "Check my Swift version"
Assistant: [execute_with_auto_retrieve: swift --version]
Assistant: "You're running Swift 6.0.2"
```

**Build Pipeline:**
```
You: "Build, test, and package my app"
Assistant: [execute_pipeline with build → test → package steps]
Assistant: "Pipeline complete! Build: ✅ Test: ✅ Package: ✅"
```

**Streaming Long Build:**
```
You: "Build this large project"
Assistant: [execute_with_streaming: swift build -c release]
Assistant: "Building... [live updates every 3 seconds]"
Assistant: "Build completed in 45 seconds!"
```

**Using Templates:**
```
You: "Save a template for deploying to staging"
Assistant: [save_template: name="deploy-staging", template="cd {{project}} && ./deploy.sh staging"]

You: "Deploy MyApp to staging"
Assistant: [run_template: name="deploy-staging", variables={project: "MyApp"}]
```

**Environment Context (v5.0):**
```
You: "What's my current dev environment?"
Assistant: [get_environment_context]
Assistant: "You're on branch feature/auth, Python venv active, Node 20.11, 3 Docker containers running."
```

**Workspace Profiles (v5.0):**
```
You: "Save this as my API project profile"
Assistant: [save_workspace_profile: name="api-project", directory="~/Projects/api", ...]

You: "Switch to the API project"
Assistant: [load_workspace_profile: name="api-project"]
```

**File Watching (v5.0):**
```
You: "Rebuild whenever a Swift file changes"
Assistant: [add_file_watch: path="./Sources", pattern="*.swift", command="swift build"]
Assistant: "Watching ./Sources for *.swift changes. Will run swift build on each change."
```

**SSH Remote Execution (v5.0):**
```
You: "Check disk space on the staging server"
Assistant: [ssh_execute: host="staging.example.com", username="deploy", command="df -h"]
Assistant: "Here's the disk usage on staging..."
```

## Configuration

The configuration file is located at `~/.warp-command-runner/config.json`:

```json
{
  "terminal": {
    "preferred": "auto",
    "fallbackOrder": ["Warp", "WarpPreview", "iTerm", "Terminal"]
  },
  "security": {
    "blockedCommands": ["rm -rf /", "format"],
    "maxCommandLength": 1000
  },
  "history": {
    "enabled": true,
    "maxEntries": 10000
  },
  "notifications": {
    "enabled": true,
    "soundEnabled": true,
    "showOnSuccess": false,
    "showOnFailure": true,
    "minimumDuration": 10
  },
  "fileWatching": {
    "maxWatchers": 5,
    "defaultDebounce": 2.0,
    "autoExpireMinutes": 60
  },
  "ssh": {
    "defaultTimeout": 30,
    "allowPasswordAuth": false
  },
  "interactiveDetection": {
    "enabled": true,
    "customPatterns": []
  }
}
```

Templates are stored separately at `~/.warp-command-runner/templates.json`.
Workspace profiles are stored at `~/.warp-command-runner/profiles.json`.
SSH profiles are stored at `~/.warp-command-runner/ssh_profiles.json`.

## 🤔 Frequently Asked Questions

### Q: Can Grok, ChatGPT, or Gemini use this — not just Claude?
**A:** Yes, if you chat inside a **local MCP host**. Warp's agent panel is the usual path: set Warp's model to Grok (or GPT, Claude, Gemini) and register this server in `~/.warp/.mcp.json`. ChatGPT desktop and Claude Desktop work the same way. **Browser** tabs on grok.com / chatgpt.com / claude.ai cannot launch a local process. Full matrix: [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

### Q: What's new in v7.0.0?
**A:** Rebrand from Claude Command Runner to Warp Command Runner. Same 40 tools and stdio MCP protocol; names, bundle ID, and `~/.warp-command-runner` paths updated. v6 config is copied on first launch.

### Q: What's new in v6.0.0?
**A:** Re-pivot to Warp after Warp went open source. Dual-consumer architecture (register the same binary in `~/.warp/.mcp.json` to use it from Warp's native agent panel, in addition to Claude Desktop). `warp://` deeplinks replace AppleScript menu-clicking for tab/window operations. New OSC 777 emitter (`emit_warp_event`) surfaces structured events into Warp's UI. New optional shell shim emits clean preexec/command-finished events to the MCP. Workspace profiles can now also emit Warp-native launch configs. ~460 LOC of dead code removed. Tool count goes from a previously-undercounted 36 (the v5 README claimed 30) up to **39**. See [CHANGELOG.md](CHANGELOG.md) and [docs/WARP_AGENT.md](docs/WARP_AGENT.md) for the full story.

### Q: What was new in v5.0.0?
**A:** Ten new feature categories bringing the tool count from 12 to 36 (the v5 README under-counted as 30; the dispatch table actually registered 36). Highlights: clipboard integration, macOS notifications, environment intelligence, structured output parsing, workspace profiles, multi-terminal sessions, file watchers, SSH remote execution.

### Q: When should I use pipelines vs regular commands?
**A:** Use pipelines when you need:
- Multiple sequential commands
- Conditional logic (stop on build failure, continue on test failure)
- A summary of all steps with timing
- CI/CD-style workflows

### Q: Why does my command "hang" with execute_with_auto_retrieve?
**A:** For very long commands, use `execute_with_streaming` instead. It provides real-time output updates and handles commands that run for minutes. This was the main motivation for adding streaming in v4.0.

### Q: How do I use templates with multiple variables?
**A:** Define variables in your template with `{{variable_name}}` syntax:
```json
{
  "template": "cd {{project}} && git checkout {{branch}} && swift build -c {{config}}"
}
```
Then provide all variables when running:
```json
{
  "variables": {"project": "~/MyApp", "branch": "main", "config": "release"}
}
```

### Q: Where are my templates stored?
**A:** In `~/.warp-command-runner/templates.json`. They persist across sessions and MCP host restarts.

### Q: How long will auto-retrieve wait for my command?
**A:** It depends on the command type:
- Simple commands: 6 seconds
- Git/npm commands: 20 seconds
- Build commands: 77 seconds
- Unknown commands: 30 seconds

For longer commands, use `execute_with_streaming` instead.

### Q: Can I use this with Terminal.app or iTerm2?
**A:** Yes, basic command execution works with any terminal. Automatic output capture and Warp-specific features (deeplinks, OSC 777, agent panel) need Warp. Download it from [warp.dev](https://app.warp.dev/referral/G9W3EY).

### Q: Is it secure to let an AI run commands?
**A:** Commands are sent directly to your terminal and execute automatically — there is no manual "press Enter" step. Configure blocked commands in `~/.warp-command-runner/config.json`. Only attach this MCP to a host you trust. Do not expose it as a public HTTP server.

### Q: What happens if a pipeline step fails?
**A:** Depends on the `on_fail` setting:
- `stop` – Pipeline halts immediately, remaining steps are skipped
- `continue` – Error is logged, pipeline continues to next step
- `warn` – Warning is shown, pipeline continues

### Q: Can I nest pipelines or run templates inside pipelines?
**A:** Not directly. You can create templates that contain multiple commands separated by `&&` or `;`, or compose by calling `run_template` and `execute_pipeline` from the same conversation.

### Q: Where is my command history stored?
**A:** In an SQLite database at `~/.warp-command-runner/warp_commands.db`. It tracks all commands, outputs, exit codes, and execution times.

## 🛠️ Troubleshooting

### macOS Permission Error: "osascript is not allowed to send keystrokes" (Error 1002)

This error affects the 5 AppleScript-keystroke-routed tools (`execute_command`, `execute_with_auto_retrieve`, `execute_with_streaming`, `run_template`, `send_to_session`). The other 34 tools — including `execute_pipeline` — are unaffected.

**Don't waste hours toggling System Settings panels.** This is a layered problem with macOS Sequoia's TCC + sandbox enforcement, and partial fixes leave silent denials in deeper layers. The canonical fix is the [**🛡️ macOS Sequoia full setup recipe**](#-macos-sequoia-full-setup-recipe-the-7-ordered-steps) above (in the Installation section) — seven ordered steps including: build the `.app` bundle, install into `/Applications/` (not `.build/`), `tccutil reset` for the bundle ID, and grant THREE TCC permissions including the surprise one (**Full Disk Access** on the bundle — sandbox preflights this before allowing the keystroke chain). Follow it top to bottom; skipping any step leaves a hidden denial.

**Quick triage — am I hitting this?**

Run this immediately after a failed `execute_command`:
```bash
log show --predicate 'process == "tccd"' --last 20s --info --debug | grep -E 'm-pineapple|promptPolicy|Service Policy'
```
You'll see one of:
- `promptPolicy = 0` → bundle isn't in `/Applications/` (or no bundle at all). Fix: Steps 2-3 of the recipe.
- `promptPolicy = 2` + `Denied (Service Policy)` for `kTCCServiceSystemPolicyAllFiles` → missing Full Disk Access on the bundle. Fix: Step 6 of the recipe.
- `AttributionChain: responsible={identifier=warp-command-runner, ...}` (no `m-pineapple`) → you're not running from the bundle, you're running the bare binary. Fix: re-run `./build.sh` and update your MCP config to the `.app` path (Steps 2-4 of the recipe).

**Workaround if you don't want to bother with the recipe:**
```jsonc
// Use execute_pipeline instead of execute_command:
{"steps": [{"command": "git status"}]}
```
Pure subprocess, no AppleScript, zero TCC. Works on any macOS regardless of permissions. The 34 non-keystroke tools all work too.

**Bundle ID Reference:** `com.m-pineapple.warp-command-runner` (this project), `com.anthropic.claudefordesktop` (Claude Desktop).

---

### macOS Accessibility Permission Issues

The MCP binary requires **Accessibility** permission only for the AppleScript keystroke path used by `send_to_session` (typing into a specific Warp tab) and the legacy non-Warp paths in `execute_command` for iTerm/Terminal/Alacritty. **Most v6.0 tools work without Accessibility:** subprocess-based execution, `warp://` deeplinks for tab opening, clipboard, SSH, env snapshots, file watch, profiles, and all 24 server-side tools.

**Symptoms (when it does matter):**
- Error message: `osascript is not allowed assistive access. (-1719)`
- `send_to_session` fails; clipboard, SSH, env-context, deeplink-based `open_terminal_tab` all work fine

**Solution:**

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button and navigate to your `warp-command-runner` binary:
   ```
   /path/to/warp-command-runner/.build/release/warp-command-runner
   ```
3. The `.build` folder is hidden by default — press **Cmd+Shift+.** in Finder to reveal it
4. Toggle the permission **on** for the binary

**Important:** macOS tracks Accessibility permissions by binary identity. After every `swift build`, the binary changes and you must **re-add it** to the Accessibility list. This only affects keystroke-injection paths — most tools are unaffected.

---

### MCP Not Responding
1. Check the client logs (Claude Desktop or Warp). The MCP server runs as a child of the client over stdio — there is no listening TCP port in v6.0.
2. Restart the client (Claude Desktop and/or Warp).
3. Rebuild with `./build.sh`. (And re-add the binary to Accessibility if `send_to_session` is failing.)

### Commands Not Appearing in Terminal
1. Ensure Warp/WarpPreview is running
2. Check Claude Desktop logs for errors
3. Verify your MCP configuration path

### Streaming Not Updating
1. Check that the command is actually running (not waiting for input)
2. Increase `update_interval` if updates are too frequent
3. Check `/tmp/wcr_stream_*.log` for output files

### Pipeline Steps Skipped Unexpectedly
1. Check the `on_fail` setting – `stop` will skip remaining steps
2. Verify each command works individually first
3. Check exit codes in the pipeline summary

### Templates Not Saving
1. Ensure `~/.warp-command-runner/` directory exists
2. Check write permissions on templates.json
3. Verify JSON syntax in template definition

### Auto-Retrieve Not Working
1. Ensure you're using `execute_with_auto_retrieve` (not `execute_command`)
2. Check if command output file exists: `ls /tmp/wcr_output_*.json`
3. For long commands, use `execute_with_streaming` instead

### Database Issues
If commands execute but aren't saved to the database:

1. **Check database integrity**:
   ```bash
   sqlite3 ~/.warp-command-runner/warp_commands.db "PRAGMA integrity_check;"
   ```
   
2. **If corrupted**, backup and remove:
   ```bash
   mv ~/.warp-command-runner/warp_commands.db ~/.warp-command-runner/warp_commands.db.backup
   # Restart the MCP host — a new database is created automatically
   ```

## Architecture

```
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │ Warp Agent   │  │ Claude Desk. │  │ ChatGPT /    │
  │ (Grok, GPT,  │  │              │  │ Cursor / VS  │
  │  Claude, …)  │  │              │  │ Code / …     │
  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
         │ stdio MCP       │ stdio MCP       │ stdio MCP
         └─────────────────┴─────────────────┘
                           ▼
         ┌─────────────────────────────────┐
         │  warp-command-runner v7.0       │
         │  Swift MCP server · 40 tools    │
         └─────────┬───────────┬───────────┘
                   │           │
                   ▼           ▼
         ┌──────────────┐  ┌─────────────────────┐
         │ Warp Terminal│  │ Optional shell shim │
         │ warp://      │  │ /tmp/wcr-shell-shim-│
         │ OSC 777      │  │   <uid>.sock        │
         └──────────────┘  └─────────────────────┘
```

Any local MCP host, one server. Tab/window operations use Warp's `warp://` URL scheme; status events use OSC 777; typing into a tab still uses AppleScript keystrokes (Warp has no API for that). Browser chats cannot connect — see [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

## Contributing

We love contributions! Here's how:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Setup
```bash
git clone https://github.com/M-Pineapple/warp-command-runner.git
cd warp-command-runner
swift package resolve
swift build
```

## 💖 Support This Project

If Warp Command Runner has helped enhance your development workflow or saved you time with intelligent command execution, consider supporting its development:

<a href="https://www.buymeacoffee.com/mpineapple" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

Your support helps me:
* Maintain and improve Warp Command Runner with new features
* Keep the project open-source and free for everyone
* Dedicate more time to addressing user requests and bug fixes
* Explore new terminal integrations and command intelligence

Thank you for considering supporting my work! 🙏

## License

MIT License – see [LICENSE](LICENSE) file for details

---

**Built with ❤️**, originally by 🍍 as Claude Command Runner. v7 rebrands the same MCP for any host.

*If this helps, star the repo and try [Warp](https://app.warp.dev/referral/G9W3EY).*