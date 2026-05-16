# Changelog

All notable changes to Claude Command Runner will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.0.3] - 2026-05-16 — .app bundle wrapper (TCC prompts actually appear now)

### Why this release exists

v6.0.2 added stable code-signing to fix cdhash drift across rebuilds. That solved one layer of the TCC problem but uncovered the next: **modern macOS (Sequoia and later) silently denies TCC permission prompts for CLI binaries that lack an embedded `Info.plist` with `NSXxxUsageDescription` strings.** No dialog appears; no error in System Settings; just silent denial. The 5 keystroke-routing tools (`execute_command`, `execute_with_auto_retrieve`, `execute_with_streaming`, `run_template`, `send_to_session`) hit this. Hours of TCC-cleanup and re-grant cycles did not resolve it — the permission prompts the user needed to grant **were never being shown** because the binary had no Info.plist to drive them.

Empirical confirmation from the live TCC log: `auth_value=1` (Unknown) on every request from `claude-command-runner` to `kTCCServiceListenEvent`, no `Prompting` entry ever appearing — the textbook silent-deny pattern for CLI binaries.

### Fixed

- **`scripts/make-app-bundle.sh`** (new) wraps the built CLI binary in a proper `.app` bundle at `.build/release/claude-command-runner.app/`. The bundle structure is minimal — `Contents/MacOS/claude-command-runner` + `Contents/Info.plist`, no Resources, no icon. The `Info.plist` declares:
    - `CFBundleIdentifier=com.m-pineapple.claude-command-runner` (stable, reverse-DNS, so TCC can target the bundle by identity rather than by cdhash)
    - `LSUIElement=true` (don't show in Dock when launched — we're a CLI, not a UI app)
    - `NSAppleEventsUsageDescription`, `NSInputMonitoringUsageDescription`, `NSAccessibilityUsageDescription` — these are what macOS shows in the permission prompt; missing them = silent denial
- **`build.sh`** now invokes `scripts/make-app-bundle.sh` after the binary is built (and code-signed if `CCR_CODESIGN_IDENTITY` is set). The bundle is signed as a unit when the env var is present.
- **`config/claude-desktop-config.json`** and **`config/warp-agent-mcp.json`** updated to point at the binary inside the bundle: `.build/release/claude-command-runner.app/Contents/MacOS/claude-command-runner`. README + `docs/WARP_AGENT.md` follow.
- **MCP `serverInfo.version` 6.0.2 → 6.0.3**.

### Changed (potentially breaking — see Migration)

- **Recommended install path moved** from `.build/release/claude-command-runner` to `.build/release/claude-command-runner.app/Contents/MacOS/claude-command-runner`. The bare-binary path still exists (we keep a copy for backwards compat) and still works for the 34 tools that don't use keystroke routing. The 5 keystroke-routing tools require the bundle path.

### Migration (existing v6.0.x users)

Edit your config files and **append `.app/Contents/MacOS/claude-command-runner`** to the existing path:

```diff
-  "command": ".../claude-command-runner/.build/release/claude-command-runner",
+  "command": ".../claude-command-runner/.build/release/claude-command-runner.app/Contents/MacOS/claude-command-runner",
```

Restart Claude Desktop / Warp. On the next `execute_command`, macOS should **finally prompt** for AppleEvents / Input Monitoring permission — grant once and it sticks (combined with v6.0.2's stable signing, the grant survives future rebuilds).

If you'd previously added the bare `claude-command-runner` binary to System Settings → Privacy & Security → Input Monitoring / Automation, those entries become orphans (different identity from the bundle). Safe to remove for hygiene; not required for functionality.

### Notes

- Tool count unchanged: 39.
- No source code changes beyond the version-string bump.
- `scripts/make-app-bundle.sh` is idempotent — re-runs overwrite the bundle cleanly.

## [6.0.2] - 2026-05-16 — stable code signing opt-in

### Why this release exists

Live diagnosis on a user's machine revealed that the persistent "osascript is not allowed to send keystrokes (1002)" issue affecting the 5 AppleScript-routed tools is **not** a configuration problem — it's a structural one. Empirical evidence captured via `log show --predicate 'process == "tccd"'`:

1. The TCC service being denied is `kTCCServiceAppleEvents`, NOT `kTCCServiceAccessibility`. The error message's "keystrokes" wording is misleading; the actual gate failing is the AppleEvents/Automation permission.
2. The binary is **ad-hoc signed** (Swift's default for `swift build`). Every rebuild produces a new `cdhash`. macOS treats each rebuild as a separate program for TCC purposes, orphaning the previous grant.
3. The user's `System Settings → Privacy & Security → Automation` panel had **three separate `claude-command-runner` entries** — one per rebuild cycle — visually confirming the drift.
4. Claude Desktop spawns the MCP server via Apple's `responsibility_spawnattrs_setdisclaim` helper (`/Applications/Claude.app/Contents/Helpers/disclaimer`), which deliberately prevents Claude.app's TCC grants from propagating to the child. So granting Claude.app permissions doesn't help; the child binary's own identity is what TCC checks.

**Every user who ever rebuilds this project hits this.** The first install works (TCC prompts, user grants). The first `git pull && ./build.sh` silently breaks it. Until v6.0.2, the only "fix" was to re-grant after every rebuild — tedious and confusing.

### Fixed

- **build.sh now supports stable code signing via `CCR_CODESIGN_IDENTITY` env var.** When set, the binary is signed with the user's chosen certificate (typically a self-signed cert from Keychain Access). Resulting cdhash is **stable across rebuilds**. Grant TCC once, it persists indefinitely. Opt-in to preserve backwards compatibility — unset means ad-hoc behavior unchanged from v6.0.x.
- **build.sh: dropped stale `--port 9876` invocation hint** from the post-build install instructions (the TCP listener was deleted in Tier A of v6.0.0).
- **build.sh: updated install hint** to point at both Claude Desktop and Warp Agent config paths (was Warp-only and outdated).
- **MCP `serverInfo.version` 6.0.1 → 6.0.2**.

### Documentation

- **README "Stable code signing" section** added under Installation (after the optional shell shim step). Explains the cdhash-drift problem in 3 sentences, the 5-step Keychain Access cert-generation flow, the `CCR_CODESIGN_IDENTITY` env var, verification command, and the `execute_pipeline` fallback for users who'd rather not sign.
- **CHANGELOG v6.0.2 entry** (this one) captures the empirical TCC log evidence so future readers don't have to re-do the investigation.

### Migration

For existing users hitting the TCC stuckness:

1. Generate a self-signed code-signing cert in Keychain Access (5 steps, see README)
2. `export CCR_CODESIGN_IDENTITY="claude-command-runner"` (or whatever you named the cert)
3. `./build.sh`
4. Remove all stale `claude-command-runner` entries from `System Settings → Privacy & Security → Automation`
5. Restart Claude Desktop
6. Trigger an `execute_command` → TCC prompts fresh → grant → done. Permanent until you replace the cert.

### Notes

- No behavior change for users who don't set `CCR_CODESIGN_IDENTITY` — backwards-compatible.
- Tool count unchanged: 39.
- No API changes.

## [6.0.1] - 2026-05-07 — patch follow-up to v6.0.0

Three real findings surfaced from the v6.0.0 live verification, plus one already-staged fix that was waiting for a tag.

### Fixed

- **`execute_and_parse` git_status parser** garbled output for human-readable input. The parser was hardcoded for `git status --porcelain` (2-char status code at line start) and would treat the first character of every prose line as a status code — producing nonsense like `Staged: 3 file(s) • O branch main` for actual `git status` output. v6.0.1 now detects format (presence of "On branch", "HEAD detached", "Changes to be committed", etc.) and dispatches to a human-format parser or the existing porcelain parser. Output for both formats is now correct.
- **`Configuration` decoder** failed loudly with `keyNotFound` errors when an existing on-disk `~/.claude-command-runner/config.json` predated one or more top-level schema fields (e.g. `security`). Swift's auto-synthesized `Codable` init uses `decode` (not `decodeIfPresent`) and ignores property defaults. v6.0.1 adds a custom `init(from:)` to `Configuration` that uses `decodeIfPresent ?? <default>` for every top-level field. Old configs continue to load without error logs; new fields silently fall back to defaults.
- **MCP `serverInfo.version`** was hardcoded to `"5.0.0"`. v6.0.1 reports `"6.0.1"`. (Already fixed on `main` between v6.0.0 and v6.0.1; rolled into this tag.)

### Documentation

- **README troubleshooting** for "Error 1002 / osascript not allowed to send keystrokes" rewritten with a "Why this is so painful" section explaining macOS responsible-process attribution. Step 5 (manual `osascript -e 'tell application "System Events" to keystroke "x"'` from a real shell) is now flagged as **mandatory, not optional** — that's the step that actually causes macOS to re-prompt and unstick the chain. Empirically validated during v6.0.0 install: every System Settings toggle was correct, full Mac restart performed, but the chain only unstuck after step 5. Also adds a workaround note: `execute_pipeline` is a fully-functional substitute for `execute_command` while TCC is being figured out — no Apple Events involved.

### Notes

- Tool count unchanged: still 39.
- No API breaking changes.
- AGPL hygiene unchanged (no new vendoring).

## [6.0.0] - 2026-05-07 — Warp re-pivot

This release is a **re-pivot back to Warp Terminal**, triggered by Warp going open source under AGPL-3.0 ([github.com/warpdotdev/warp](https://github.com/warpdotdev/warp)) in early May 2026. It re-establishes Warp as the primary integration target, replaces fragile AppleScript paths with documented surfaces, and adds a new install path: **Warp's native agent panel** as a first-class consumer alongside Claude Desktop.

### Headline

`claude-command-runner` is now a **dual-consumer MCP server**: the same binary serves both Claude Desktop and Warp's built-in agent. Same code, same tools, just two consumers. See [`docs/WARP_AGENT.md`](docs/WARP_AGENT.md) for the new install path.

### Added

- **Warp Agent registration story** (Tier D). Documented `~/.warp/.mcp.json` setup so Warp's native agent panel can call our tools. Sample at `config/warp-agent-mcp.json`.
- **`focus_warp_session`** tool — dispatches `warp://session/<uuid>` to focus a previously-opened pane. Requires a UUID Warp itself recognises (typically from the optional shell shim's OSC 777 stream).
- **`emit_warp_event`** tool — builds a `printf` invocation that emits an OSC 777 `warp://cli-agent` JSON event into Warp's notification UI. Schema reimplemented from upstream `event/v1.rs`. Surfaces session_start / prompt_submit / tool_complete / stop / permission_request / idle_prompt.
- **`shell_shim_status`** tool — reports the optional shell shim's listening state and recent events.
- **Optional shell shim** (Tier E, opt-in beta, `helper/install-shim.sh`). Adds zsh/bash hooks that emit preexec/command_finished events to a per-uid Unix domain socket the MCP listens on. Auto-disables outside Warp panes (gated on `$WARP_SESSION_ID`). Observability surface in v6.0; `execute_command` auto-routing through shim events is deferred to v6.0.x.
- **Workspace profiles → Warp launch configs** (Tier C). `save_workspace_profile` accepts `include_warp_launch_config: true`; when set, also writes a YAML to `~/.warp/launch_configurations/<name>.yaml` so the profile appears in Warp's launch UI. Schema reimplemented from upstream `LaunchConfig` / `TabTemplate` / `PaneTemplateType` / `CommandTemplate`. Env vars are not emitted into the YAML (Warp's schema does not have a top-level env map); they remain in the private CCR JSON.
- **Session UUID tracking** — `TerminalSession` now carries a locally-minted UUID (returned by `open_terminal_tab`). Used by our registry; not bound to Warp's internal session UUID.
- **`PRODUCT.md` and `TECH.md`** — checked-in product/tech specs for v6.0.

### Changed

- **`open_terminal_tab` (Warp path)** uses `warp://action/new_tab?path=...` instead of clicking `menu item "New Tab"` via System Events. The open path no longer requires Accessibility permission. Directory is baked into the URL — no follow-up `cd` keystroke. AppleScript path remains for iTerm2 / Terminal / Alacritty (unchanged).
- **`README.md`** — rewritten for the dual-consumer story. Tool count corrected from 30 to 39 (was previously under-counted; v6.0 adds 3 new).
- **swift-sdk pinned to `0.10.x`** with a reproducible patch script (`scripts/patch-swift-sdk.sh`). Previous loose `from: "0.1.0"` resolved 0.9.0 and failed under current Swift toolchains. The patch applies `nonisolated(unsafe)` to two `Bool` decls in `NetworkTransport.swift`. Build is reproducible from a fresh clone via `./build.sh`.
- **`config/`** — dropped `--port 9876` and `--verbose` from the example `claude_desktop_config.json` (port 9876 was for the now-deleted TCP listener). Removed `warp-mcp-config.json` and `warp-mcp-config-correct.json`; replaced with a single canonical `warp-agent-mcp.json`.

### Removed (dead code)

- `WarpDatabaseIntegration.swift` (260 LOC) — never reached from any registered tool. Hardcoded Warp SQLite schema; would silently break on Warp updates.
- `CommandReceiverService.swift` (201 LOC) — TCP listener on `127.0.0.1:9876` with mock-only handlers; never invoked from production. The live `MCPService` struct that was sharing the file has been extracted to its own file.
- `CommandHistoryManager.loadFromWarpDatabase` and the `warpDB` property — neither was reachable.
- The unreachable `Task`-based background monitor in `CommandHandlers.swift` — dispatch goes through `CommandHandlersStable`. The dead Task was the prior crash trigger.

### Fixed

- README claimed 30 tools; the dispatch table actually registered 36. Six previously-undocumented tools surfaced: `set_notification_preference`, `cleanup_sessions`, `list_file_watches`, `delete_workspace_profile`, `list_ssh_profiles`, `delete_ssh_profile`. With v6.0's three new tools (`focus_warp_session`, `emit_warp_event`, `shell_shim_status`), the live count is **39**.

### Tool count

| Version | Tools | Note |
|---|---|---|
| v5.0.0 advertised | 30 | README claim |
| v5.0.0 actual | 36 | dispatch table |
| **v6.0.0** | **39** | dispatch table |

### Migration

- **Existing Claude Desktop users:** edit `claude_desktop_config.json` to drop `--port 9876` from `args`. The MCP server still tolerates the flag (it's parsed and ignored), but it serves no purpose post-v6.0.
- **New Warp Agent users:** see [`docs/WARP_AGENT.md`](docs/WARP_AGENT.md).
- **Optional shim users:** `helper/install-shim.sh` adds a clearly-marked block to your `~/.zshrc` or `~/.bashrc`. `helper/uninstall-shim.sh` removes it.
- **Build:** run `./build.sh` (now invokes `scripts/patch-swift-sdk.sh` automatically). Or for manual builds: `swift package resolve && ./scripts/patch-swift-sdk.sh && swift build -c release`.

### Non-goals (deliberately out of scope)

- Bridging Claude Desktop conversations into Warp (would require server-push; reinvents Claude Code).
- Replacing Claude Code as a TUI agent in a Warp pane.
- Reading Warp's internal SQLite (~80 Diesel migrations in 5 years; schema unstable).
- Becoming a Warp plugin (no third-party plugin API exists; `CLIAgent` registry is a closed enum).
- Wave Terminal support (the prior local repurposing was incorrect; Wave is not a target).

### AGPL hygiene

Warp is AGPL-3.0. Our MCP communicates with Warp over IPC (`warp://` URLs and OSC escape sequences) and through the MCP protocol — copyleft does not propagate. **No Warp source is vendored.** All schemas (OSC 777 event JSON, launch config YAML) are reimplemented from observed shape, not copied.

## [5.0.2] - 2026-02-19

### Fixed
- **Tab proliferation (actual fix)**: `createAppleScript()` in TerminalUtilities.swift still contained `click menu item "New Tab"` for every Warp command, causing a new tab per tool call. Removed the new-tab logic so regular commands (`execute_command`, `execute_with_auto_retrieve`, `execute_pipeline`, etc.) reuse the active Warp tab. Only `open_terminal_tab` creates new tabs.
- **Double-tab on open_terminal_tab**: The initial `cd` command after opening a new tab was routed through `createAppleScript()` which opened yet another tab. Changed to use `keystrokeSendToCurrentTab()` instead.

## [5.0.1] - 2026-02-19

### Added
- **Session cleanup**: `cleanup_sessions` tool (tool #31) to remove stale terminal sessions after a configurable inactivity period and optionally close their associated Warp tabs.
- Session manager tracks `lastActivity` timestamps for stale session detection

## [5.0.0] - 2026-02-18

### Added

- **Clipboard Bridge** (`copy_to_clipboard`, `read_from_clipboard`): Read and write the macOS clipboard directly from Claude Desktop via NSPasteboard.

- **macOS Notifications** (`set_notification_preference`): Native macOS notifications when long-running commands complete. Configurable sound, success/failure filtering, and minimum duration threshold.

- **Environment Intelligence** (`get_environment_context`): Single-call probe of terminal context including current directory, git branch and status, active Python venv, Node version, Docker containers, Conda environment, and NVM version.

- **Output Parsers** (`execute_and_parse`): Structured JSON parsing for common command outputs. Supported parsers: `git status`, `git log`, `docker ps`, `npm test`/`pytest`, `ls -la`, plus generic JSON passthrough.

- **Environment Snapshots** (`capture_environment`, `diff_environment`): Capture named snapshots of all environment variables and diff any two snapshots to see additions, removals, and changes.

- **Workspace Profiles** (`save_workspace_profile`, `load_workspace_profile`, `list_workspace_profiles`, `delete_workspace_profile`): Save and restore project contexts including working directory, environment variables, default commands, and terminal preference. Stored at `~/.claude-command-runner/profiles.json`.

- **Multi-Terminal Sessions** (`open_terminal_tab`, `send_to_session`, `list_sessions`, `close_session`): Orchestrate multiple named terminal tabs. Open tabs, send commands to specific sessions, and manage the session lifecycle.

- **Interactive Command Detection**: Smart detection of interactive commands (ssh, vim, nano, python REPL, psql, etc.) with graceful handling. Instead of timing out, returns a warning and directs the user to interact directly in the terminal. Configurable via `interactiveDetection.customPatterns`.

- **File System Watchers** (`add_file_watch`, `remove_file_watch`, `list_file_watches`): Watch directories for file changes using FSEvents. Trigger commands automatically with configurable glob patterns and debounce. Max 5 concurrent watchers with auto-expiry.

- **SSH Remote Execution** (`ssh_execute`, `save_ssh_profile`, `list_ssh_profiles`, `delete_ssh_profile`): Run commands on remote hosts via SSH key authentication. Connection profiles stored at `~/.claude-command-runner/ssh_profiles.json`. Key-only auth by default for security.

### Changed
- Version bumped from 4.1.0 to 5.0.0
- Tool count expanded from 12 to 30
- Configuration extended with 5 new sections: `notifications`, `workspace`, `fileWatching`, `ssh`, `interactiveDetection`
- Security blocked-command checks now also apply to SSH remote commands

### Technical
- 8 new source files: `ClipboardBridge.swift`, `EnvironmentContext.swift`, `OutputParsers.swift`, `EnvironmentSnapshot.swift`, `WorkspaceProfiles.swift`, `TerminalSessions.swift`, `FileWatcher.swift`, `SSHExecution.swift`
- Modified: `CommandHandlers.swift` (interactive detection), `NotificationSupport.swift` (real macOS notifications), `Configuration.swift` (new config sections + validation), `ClaudeCommandRunner.swift` (tool registration)
- All new features use Foundation/AppKit — no new external dependencies
- Actor-based concurrency for thread-safe state management (EnvironmentStore, FileWatcher, SessionManager, SSHProfileStore)

## [4.1.0] - 2025-12-30

### Added
- **Command History** (`list_recent_commands`): View recent command history from SQLite database
  - Filter by status: `all`, `success`, `failed`
  - Search within command text
  - Configurable limit (1-50 commands)
  - Shows exit codes, duration, timestamps, and working directories

- **Health Check** (`self_check`): Comprehensive system diagnostics
  - Configuration validation
  - Database integrity check with statistics
  - Terminal (Warp) availability detection
  - Temp directory writability verification
  - Recent error rate analysis
  - Returns overall health status with warnings

- **Auto Temp Cleanup**: Automatic cleanup of orphaned temp files on startup
  - Removes `claude_output_*`, `claude_stream_*`, `claude_script_*` files older than 24 hours
  - Prevents `/tmp` pollution from interrupted sessions
  - Logs cleanup statistics

### Technical
- New file: `HealthAndHistory.swift` containing all v4.1 features
- Cleanup runs non-blocking on MCP server startup
- Leverages existing SQLite command history infrastructure

## [4.0.1] - 2025-12-30

### Fixed
- **Critical: Streaming Exit Code Bug** - Fixed `execute_with_streaming` incorrectly reporting exit code 0 for failed commands
  - The `$?` was capturing the `while` loop's exit code (always 0) instead of the actual command's exit code
  - Now uses `set -o pipefail` and `${PIPESTATUS[0]}` to correctly capture the original command's exit status
  - Credit: Discovered during Warp AI code audit

### Technical
- Updated bash wrapper script to use `pipefail` and `PIPESTATUS` array for proper pipeline exit code propagation

## [4.0.0] - 2025-12-01

### Added
- **Command Pipelines** (`execute_pipeline`): Chain multiple commands with conditional logic
  - `on_fail: stop` - Stop pipeline on failure (default)
  - `on_fail: continue` - Continue to next step regardless of failure
  - `on_fail: warn` - Log warning but continue
  - Named steps for clear output
  - Detailed execution summary with timing

- **Output Streaming** (`execute_with_streaming`): Real-time output for long-running commands
  - Configurable update interval (default: 2 seconds)
  - Maximum duration limit (default: 120 seconds)
  - Progressive output display
  - Ideal for builds that previously appeared to "hang"

- **Command Templates**: Save and reuse command patterns
  - `save_template` - Store templates with `{{variable}}` placeholders
  - `run_template` - Execute templates with variable substitution
  - `list_templates` - View all saved templates
  - Category organization
  - Templates stored in `~/.claude-command-runner/templates.json`

### Changed
- Version bumped to 4.0.0
- Moved disabled WarpCode integration out of Sources to fix build

### Technical
- New file: `PipelineAndStreaming.swift` containing all v4.0 features
- Fixed MCP Value type handling (uses string parsing for integers)
- Maintained backward compatibility with all v3.0 tools

## [3.0.1] - 2025-06-30

### Fixed
- Added database logging diagnostics to identify command save failures
- Enhanced error reporting for SQLite operations
- Improved database connection verification

### Known Issues
- Database command logging not functioning - investigation ongoing
- Command suggestions returning empty results

## [2.2.0] - 2025-06-29

### Added
- **Standard Warp Terminal Support**: Full compatibility with production Warp Terminal (not just Preview)
- **Terminal Auto-Detection**: Automatically detects and configures available terminals
- **Configuration System**: Comprehensive config file at `~/.claude-command-runner/config.json`
- **Config Manager Tool**: CLI utility for managing configuration

- **Installation Script**: Automated setup with `install.sh`
- **Terminal Fallback System**: Automatic fallback to available terminals
- **Warp Database Integration**: Direct access to Warp's SQLite command history
- **Pending Commands**: Check for commands completed while Claude was idle
- **Security Configuration**: Customizable blocked commands and patterns
- **Custom Terminal Support**: Add any terminal via configuration
- **Command Validation**: Pre-execution security checks

### Changed
- Refactored terminal detection to use bundle identifiers
- Improved error messages when terminal not found
- Modularized command handlers for better maintainability
- Enhanced AppleScript generation per terminal type
- Updated directory structure for better organization

### Fixed
- Terminal detection now works with standard Warp installations
- Better handling of missing terminals
- Improved error recovery in command execution

### Security
- Added configurable command blocking patterns
- Implemented maximum command length limits
- Added dangerous command confirmation requirements

## [2.1.0] - 2025-06-14

### Added
- **Auto-Retrieve Mode**: `execute_with_auto_retrieve` tool for automatic output capture
- **Two-Way Communication**: Seamless command execution and output retrieval
- **Suggest Command Tool**: AI-powered command suggestions
- **Preview Command**: Preview commands before execution
- **Verbose Logging**: Detailed debugging information

### Changed
- Improved MCP protocol implementation
- Enhanced error handling and recovery
- Better output formatting for readability

### Fixed
- Output capture timing issues
- JSON parsing errors in edge cases
- Terminal focus handling

## [2.0.0] - 2025-06-07

### Added
- Complete rewrite in Swift
- MCP server implementation
- JSON-RPC communication
- Warp Preview integration
- Security approval system

### Changed
- Migrated from Python to Swift
- New architecture for better performance
- Improved security model

### Removed
- Python dependencies
- Direct terminal control

## [1.0.0] - 2025-05-15

### Added
- Initial release
- Basic command execution
- Output capture
- Warp terminal support

---

## Versioning Guide

- **Major version (X.0.0)**: Breaking changes or complete rewrites
- **Minor version (0.X.0)**: New features, backward compatible
- **Patch version (0.0.X)**: Bug fixes and minor improvements

## Upgrade Guide

### From 4.x to 5.0.0
- No breaking changes — all existing tools work identically
- Rebuild with `swift build -c release`
- Restart Claude Desktop to load updated MCP
- New config sections are auto-populated with sensible defaults on first run
- New data files (`profiles.json`, `ssh_profiles.json`) are created on first use

### From 4.0.0 to 4.0.1
- No breaking changes - patch fix only
- Rebuild with `swift build -c release`
- Restart Claude Desktop to load updated MCP

### From 2.1 to 2.2
1. Update configuration path from Warp Preview to standard Warp
2. Run `./install.sh` to set up new configuration system
3. Review and customize `~/.claude-command-runner/config.json`
4. Update Claude Desktop configuration if needed

### From 2.0 to 2.1
- No breaking changes
- Simply rebuild and restart Claude Desktop

### From 1.x to 2.x
- Complete reinstallation required
- New Swift-based implementation
- Update Claude Desktop MCP configuration
