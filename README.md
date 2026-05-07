# Claude Command Runner

<div align="center">
  <img src="https://github.com/user-attachments/assets/13d56902-b9d7-4368-b44f-2cefa15bf746">
</div>

A powerful Model Context Protocol (MCP) server that bridges Claude Desktop and terminal applications, enabling seamless command execution with intelligent output retrieval, command pipelines, real-time streaming, workspace profiles, environment intelligence, and 36 integrated tools.

## 🚀 What's New in v5.0.0

**Major release: 36 tools, up from 12.** Every feature below is a new MCP tool accessible directly from Claude Desktop.

- **Clipboard Bridge**: Read from and write to the macOS clipboard without leaving the conversation
- **macOS Notifications**: Get native notifications when long-running commands finish
- **Environment Intelligence**: Probe your terminal context (git branch, active venv, Node version, Docker containers) in one call
- **Output Parsers**: Structured JSON parsing for `git status`, `docker ps`, test results, and more
- **Environment Snapshots**: Capture and diff environment variables before/after installs or config changes
- **Workspace Profiles**: Save and restore project contexts (directory, env vars, common commands) per project
- **Multi-Terminal Sessions**: Open, name, and send commands to multiple terminal tabs
- **Interactive Command Detection**: Smart detection of interactive commands (vim, ssh, python REPL) with graceful handling
- **File System Watchers**: Watch directories for changes and trigger commands automatically
- **SSH Remote Execution**: Run commands on remote hosts via SSH key authentication

### Previous Releases (Included)

- **v4.0**: Command pipelines, output streaming, reusable templates
- **v3.0**: Smart auto-retrieve, SQLite history, configurable security

## Overview

Claude Command Runner revolutionises the development workflow by allowing Claude to:
- Execute terminal commands directly from conversations
- Chain commands with conditional logic using pipelines
- Stream output in real-time for long builds
- Save and reuse command templates with variables
- Automatically capture output with intelligent timing
- Track command history and patterns
- Read/write the macOS clipboard
- Probe environment context (git, venv, Docker, Node)
- Parse command output into structured JSON
- Manage workspace profiles per project
- Orchestrate multiple terminal tabs
- Watch files and trigger commands on changes
- Execute commands on remote hosts via SSH

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

Templates are stored in `~/.claude-command-runner/templates.json` and persist across sessions.

### Smart Auto-Retrieve
The `execute_with_auto_retrieve` command intelligently detects command types and adjusts wait times:
- **Quick commands** (echo, pwd): 2-6 seconds
- **Moderate commands** (git, npm): up to 20 seconds  
- **Build commands** (swift build, make): up to 77 seconds
- **Test commands**: up to 40 seconds

## 📊 Why Warp Terminal?

For the best experience, we recommend [Warp Terminal](https://app.warp.dev/referral/G9W3EY):

| Feature | Warp | Terminal.app | iTerm2 |
|---------|------|--------------|---------|
| Auto Output Capture | ✅ | ❌ | ❌ |
| Command History Integration | ✅ | ❌ | ❌ |
| AI-Powered Features | ✅ | ❌ | ❌ |
| Modern UI/UX | ✅ | ⚠️ | ⚠️ |

> 💡 **Get Warp Free**: [Download Warp Terminal](https://app.warp.dev/referral/G9W3EY) – It's free and makes Claude Command Runner significantly more powerful!

## Installation

### Prerequisites
- macOS 13.0 or later
- Swift 6.0+ (Xcode 16+)
- Claude Desktop
- A supported terminal ([Warp](https://app.warp.dev/referral/G9W3EY) strongly recommended)

### Quick Install

1. Clone and build:
```bash
git clone https://github.com/M-Pineapple/claude-command-runner.git
cd claude-command-runner
./build.sh
```

2. Configure Claude Desktop by adding to your MCP settings:
```json
{
  "claude-command-runner": {
    "command": "/path/to/claude-command-runner/.build/release/claude-command-runner",
    "args": ["--port", "9876"],
    "env": {}
  }
}
```

3. Grant Accessibility permission (required for all command execution):
   - Open **System Settings → Privacy & Security → Accessibility**
   - Click **+** and navigate to `claude-command-runner/.build/release/`
   - Press **Cmd+Shift+.** to reveal the hidden `.build` folder
   - Select the `claude-command-runner` binary and toggle it **on**

> **Important:** macOS tracks permissions by binary identity. After every rebuild (`./build.sh`), you must remove the old entry and re-add the new binary in Accessibility settings.

4. Restart Claude Desktop

## Usage

### Available Tools (30)

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
| `get_command_output` | Manually retrieve command output | Debugging |
| `preview_command` | Preview without executing | Safety check |
| `suggest_command` | Get command suggestions | Discovery |
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
| `capture_environment` | Snapshot all environment variables | Before/after comparison |
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
| `open_terminal_tab` | Open a new named terminal tab | Parallel workflows |
| `send_to_session` | Send command to a specific tab | Targeted execution |
| `list_sessions` | View active terminal sessions | Session overview |
| `close_session` | Close a named session | Cleanup |

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

### Example Workflows

**Simple Command:**
```
You: "Check my Swift version"
Claude: [execute_with_auto_retrieve: swift --version]
Claude: "You're running Swift 6.0.2"
```

**Build Pipeline:**
```
You: "Build, test, and package my app"
Claude: [execute_pipeline with build → test → package steps]
Claude: "Pipeline complete! Build: ✅ Test: ✅ Package: ✅"
```

**Streaming Long Build:**
```
You: "Build this large project"
Claude: [execute_with_streaming: swift build -c release]
Claude: "Building... [live updates every 3 seconds]"
Claude: "Build completed in 45 seconds!"
```

**Using Templates:**
```
You: "Save a template for deploying to staging"
Claude: [save_template: name="deploy-staging", template="cd {{project}} && ./deploy.sh staging"]

You: "Deploy MyApp to staging"
Claude: [run_template: name="deploy-staging", variables={project: "MyApp"}]
```

**Environment Context (v5.0):**
```
You: "What's my current dev environment?"
Claude: [get_environment_context]
Claude: "You're on branch feature/auth, Python venv active, Node 20.11, 3 Docker containers running."
```

**Workspace Profiles (v5.0):**
```
You: "Save this as my API project profile"
Claude: [save_workspace_profile: name="api-project", directory="~/Projects/api", ...]

You: "Switch to the API project"
Claude: [load_workspace_profile: name="api-project"]
```

**File Watching (v5.0):**
```
You: "Rebuild whenever a Swift file changes"
Claude: [add_file_watch: path="./Sources", pattern="*.swift", command="swift build"]
Claude: "Watching ./Sources for *.swift changes. Will run swift build on each change."
```

**SSH Remote Execution (v5.0):**
```
You: "Check disk space on the staging server"
Claude: [ssh_execute: host="staging.example.com", username="deploy", command="df -h"]
Claude: "Here's the disk usage on staging..."
```

## Configuration

The configuration file is located at `~/.claude-command-runner/config.json`:

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

Templates are stored separately at `~/.claude-command-runner/templates.json`.
Workspace profiles are stored at `~/.claude-command-runner/profiles.json`.
SSH profiles are stored at `~/.claude-command-runner/ssh_profiles.json`.

## 🤔 Frequently Asked Questions

### Q: What's new in v5.0.0?
**A:** Ten new feature categories bringing the tool count from 12 to 30. Highlights include clipboard integration, macOS notifications, environment intelligence, structured output parsing, workspace profiles, multi-terminal sessions, file watchers, and SSH remote execution. See the full changelog for details.

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
**A:** In `~/.claude-command-runner/templates.json`. They persist across sessions and Claude Desktop restarts.

### Q: How long will auto-retrieve wait for my command?
**A:** It depends on the command type:
- Simple commands: 6 seconds
- Git/npm commands: 20 seconds
- Build commands: 77 seconds
- Unknown commands: 30 seconds

For longer commands, use `execute_with_streaming` instead.

### Q: Can I use this with Terminal.app or iTerm2?
**A:** Yes, basic command execution works with any terminal. However, automatic output capture and advanced features require Warp Terminal. [Get Warp free here](https://app.warp.dev/referral/G9W3EY).

### Q: Is it secure to let Claude run commands?
**A:** Commands are sent directly to your terminal and execute automatically — there is no manual "press Enter" step. However, you can configure blocked commands and patterns in the config file to prevent dangerous operations. Always review the command Claude proposes before confirming in the chat interface.

### Q: What happens if a pipeline step fails?
**A:** Depends on the `on_fail` setting:
- `stop` – Pipeline halts immediately, remaining steps are skipped
- `continue` – Error is logged, pipeline continues to next step
- `warn` – Warning is shown, pipeline continues

### Q: Can I nest pipelines or run templates inside pipelines?
**A:** Not directly in v4.0, but you can create templates that contain multiple commands separated by `&&` or `;`.

### Q: Where is my command history stored?
**A:** In an SQLite database at `~/.claude-command-runner/claude_commands.db`. It tracks all commands, outputs, exit codes, and execution times.

## 🛠️ Troubleshooting

### macOS Permission Error: "osascript is not allowed to send keystrokes" (Error 1002)

This error occurs when macOS blocks AppleScript automation. It's common after fresh macOS installs, major updates (like Sequoia), or when the Automation permissions cache becomes corrupted.

**Symptoms:**
- Error message: `System Events got an error: osascript is not allowed to send keystrokes. (1002)`
- Toggling permissions off/on in System Settings doesn't help
- No permission prompt appears when the MCP tries to run

**Solution:**

1. **Reset Automation permissions** (this resets ALL Automation permissions, not just for this app):
   ```bash
   tccutil reset AppleEvents
   ```

2. **Full Mac restart** (not just logout – a complete restart is required)

3. **Open your terminal app first** (Warp, WarpPreview, or whichever you use)

4. **Open Claude Desktop**

5. **Trigger the permission prompt manually** by running this in Terminal:
   ```bash
   osascript -e 'tell application "System Events" to keystroke "x"'
   ```

6. **Grant permission** when macOS prompts you

7. **Try the MCP command again** – it should now work and Claude.app will appear in the Automation list

**Note:** A simple toggle reset or targeted `tccutil` command often doesn't work – the full AppleEvents reset plus restart is usually required.

**Bundle ID Reference:** Claude Desktop uses `com.anthropic.claudefordesktop`

---

### macOS Accessibility Permission Issues

The MCP binary requires **Accessibility** permission to send commands to your terminal. Without it, all command execution will fail. If you skipped step 3 during installation, do it now.

**Symptoms:**
- Error message: `osascript is not allowed assistive access. (-1719)`
- Multi-terminal tools fail while other tools (clipboard, SSH, environment context) work fine

**Solution:**

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button and navigate to your `claude-command-runner` binary:
   ```
   /path/to/claude-command-runner/.build/arm64-apple-macosx/release/claude-command-runner
   ```
3. The `.build` folder is hidden by default — press **Cmd+Shift+.** in Finder to reveal it
4. Toggle the permission **on** for the binary

**Important:** macOS tracks Accessibility permissions by binary identity. After every `swift build`, the binary changes and you must **re-add it** to the Accessibility list. This only affects the multi-terminal session tools — all other tools work without Accessibility permission.

---

### MCP Not Responding
1. Check if the server is running: `lsof -i :9876`
2. Restart Claude Desktop
3. Rebuild with `./build.sh`

### Commands Not Appearing in Terminal
1. Ensure Warp/WarpPreview is running
2. Check Claude Desktop logs for errors
3. Verify your MCP configuration path

### Streaming Not Updating
1. Check that the command is actually running (not waiting for input)
2. Increase `update_interval` if updates are too frequent
3. Check `/tmp/claude_stream_*.log` for output files

### Pipeline Steps Skipped Unexpectedly
1. Check the `on_fail` setting – `stop` will skip remaining steps
2. Verify each command works individually first
3. Check exit codes in the pipeline summary

### Templates Not Saving
1. Ensure `~/.claude-command-runner/` directory exists
2. Check write permissions on templates.json
3. Verify JSON syntax in template definition

### Auto-Retrieve Not Working
1. Ensure you're using `execute_with_auto_retrieve` (not `execute_command`)
2. Check if command output file exists: `ls /tmp/claude_output_*.json`
3. For long commands, use `execute_with_streaming` instead

### Database Issues
If commands execute but aren't saved to the database:

1. **Check database integrity**:
   ```bash
   sqlite3 ~/.claude-command-runner/claude_commands.db "PRAGMA integrity_check;"
   ```
   
2. **If corrupted**, backup and remove:
   ```bash
   mv ~/.claude-command-runner/claude_commands.db ~/.claude-command-runner/claude_commands.db.backup
   # Restart Claude Desktop - a new database will be created automatically
   ```

## Architecture

```
┌─────────────────┐         ┌──────────────────┐         ┌────────────────┐
│ Claude Desktop  │ ←────→  │ Command Runner   │ ←────→  │ Warp Terminal  │
│                 │  MCP    │ MCP Server v5.0  │ Script  │                │
│ • 30 Tools      │         │ • Port 9876      │         │ • Execute      │
│ • Pipelines     │         │ • Templates      │         │ • Capture      │
│ • Streaming     │         │ • SQLite DB      │         │ • Stream       │
│ • Profiles      │         │ • File Watchers  │         │ • Multi-tab    │
│ • Clipboard     │         │ • SSH Profiles   │         │ • Return       │
└─────────────────┘         └──────────────────┘         └────────────────┘
                                     │
                            ┌────────┴────────┐
                            │  Remote Hosts   │
                            │  (via SSH)      │
                            └─────────────────┘
```

## Contributing

We love contributions! Here's how:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Setup
```bash
git clone https://github.com/yourusername/claude-command-runner.git
cd claude-command-runner
swift package resolve
swift build
```

## 💖 Support This Project

If Claude Command Runner has helped enhance your development workflow or saved you time with intelligent command execution, consider supporting its development:

<a href="https://www.buymeacoffee.com/mpineapple" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

Your support helps me:
* Maintain and improve Claude Command Runner with new features
* Keep the project open-source and free for everyone
* Dedicate more time to addressing user requests and bug fixes
* Explore new terminal integrations and command intelligence

Thank you for considering supporting my work! 🙏

## License

MIT License – see [LICENSE](LICENSE) file for details

---

**Built with ❤️ by 🍍**

*If you find this project helpful, give it a ⭐ and try [Warp Terminal](https://app.warp.dev/referral/G9W3EY)!*