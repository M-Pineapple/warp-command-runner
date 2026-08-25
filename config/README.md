# MCP host config snippets

Copy one of these, fix the `command` path if you have not installed the bundle in `/Applications/`, and merge it into the host's MCP config.

| File | Host | Config location |
|---|---|---|
| [`warp-agent-mcp.json`](warp-agent-mcp.json) | [Warp Agent](https://app.warp.dev/referral/G9W3EY) | `~/.warp/.mcp.json` |
| [`claude-desktop.json`](claude-desktop.json) | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| [`chatgpt-mcp.json`](chatgpt-mcp.json) | ChatGPT desktop (Connectors / Developer Mode) | host MCP settings |
| [`cursor-mcp.json`](cursor-mcp.json) | Cursor | `~/.cursor/mcp.json` — **do not** use the `/Applications/Warp Command Runner.app` path; Cursor splits `command` on spaces. Run `helper/install-cursor-wrapper.sh` and point at `~/.local/bin/warp-command-runner`. Warp/Claude keep the `.app` path. |
| [`vscode-mcp.json`](vscode-mcp.json) | VS Code Copilot | `.vscode/mcp.json` (`servers`, not `mcpServers`) |
| [`generic-stdio.json`](generic-stdio.json) | Continue, Cline, Windsurf, Gemini CLI, Claude Code, … | whatever that host documents |

All of these launch the **same stdio binary**. The model (Grok, GPT, Claude, Gemini) is chosen by the host, not by this server.

Browser chats cannot use these files. See [`docs/COMPATIBILITY.md`](../docs/COMPATIBILITY.md).
