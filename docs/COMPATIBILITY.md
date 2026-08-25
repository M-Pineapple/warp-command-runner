# Can any AI use Warp Command Runner?

**Short answer:** any app that is a **local MCP host** can. The binary speaks the standard Model Context Protocol over **stdio**. It does not know or care whether the model on the other end is Grok, ChatGPT, Claude, Gemini, or something else.

**Short caveat:** a **cloud web chat** (grok.com, chatgpt.com, claude.ai in the browser, Gemini on the web) cannot spawn a process on your Mac. Those sites never see this MCP unless they add a *remote* HTTPS MCP connector — which this server does not expose, on purpose. Putting your live terminal on the public internet would be a serious security hole.

This is the right tool if you chat with an AI from a **desktop or CLI host** and want that chat to read files, run commands, and drive [Warp](https://app.warp.dev/referral/G9W3EY) — without installing Cursor or Claude Code.

---

## How MCP actually connects

```
You  →  MCP host (Warp Agent, Claude Desktop, ChatGPT desktop, …)
              │  launches this binary
              │  JSON-RPC over stdin/stdout  (MCP)
              ▼
     warp-command-runner
              │  tools: execute_command, read clipboard, SSH, …
              ▼
        Warp (and your files / network)
```

The official Swift MCP SDK (`modelcontextprotocol/swift-sdk`) implements the open protocol. There is **no Anthropic-only handshake**, no Claude API key, and no vendor lock in the server. The host:

1. Starts `/Applications/Warp Command Runner.app/Contents/MacOS/warp-command-runner` (or the path you configured)
2. Sends `initialize` / `tools/list` / `tools/call` as JSON-RPC on stdin
3. Reads results on stdout

Whoever that host's LLM is — Grok in Warp, GPT-5 in ChatGPT desktop, Claude in Claude Desktop, Gemini in Gemini CLI — it just calls tools.

## What works today

| Host | How to add this MCP | Uses which model | Local files + terminal |
|---|---|---|---|
| **[Warp Agent](https://app.warp.dev/referral/G9W3EY)** | `~/.warp/.mcp.json` or Settings → AI → MCP | Whatever you pick in Warp (Grok, Claude, GPT, Gemini, …) | Yes — this is the best fit |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | Claude | Yes |
| **ChatGPT desktop** (Connectors / Developer Mode, where offered) | Add a stdio MCP server pointing at the binary | GPT | Yes, on that Mac |
| **Cursor** | `~/.cursor/mcp.json` | Whatever Cursor is using | Yes — but Cursor already has a terminal; this is optional |
| **VS Code Copilot** | `.vscode/mcp.json` or user MCP settings | Copilot / the model you selected | Yes |
| **Continue** | Continue MCP config | The model Continue is using | Yes |
| **Cline / Windsurf / similar IDE agents** | Their MCP settings (stdio command + args) | Their model | Yes |
| **Gemini CLI** | Gemini CLI MCP config | Gemini | Yes |
| **Claude Code** | `~/.claude.json` | Claude | Niche — Claude Code already has Bash |
| **chatgpt.com / claude.ai / grok.com / gemini.google.com in a browser** | — | — | **No.** They cannot launch a local stdio process. |

Ready-to-edit snippets live in [`config/`](../config/).

## What does *not* work (and why)

### Browser / “cloud AI” chat pages

MCP stdio means “the chat app starts a child process on this computer.” A website in Safari or Chrome cannot do that. Some vendors are adding **remote MCP** (HTTPS). This project stays on stdio because:

- Your terminal, files, SSH keys, and clipboard stay on your machine
- There is no public URL to attack
- The same binary works with every local host

If a vendor only accepts a public HTTPS MCP URL, do **not** tunnel this server to the internet. That would let whoever hits the URL run commands as you.

### “Just paste this into Grok / ChatGPT on the web”

The model can *talk* about commands. It cannot *run* them unless the app you are chatting in is an MCP host that launched this binary.

**The practical Grok path:** install [Warp](https://app.warp.dev/referral/G9W3EY), set Warp's AI model to Grok, register this MCP in `~/.warp/.mcp.json`. You chat with Grok inside Warp; Grok calls the same 40 tools.

**The practical ChatGPT path:** use ChatGPT's desktop app (or any other local MCP host) and add the stdio server. ChatGPT in the browser cannot see your Mac.

## Same binary, many hosts

You can register the identical path in several configs at once. Each host spawns its own process. Conversations are not shared — Warp's Grok session and Claude Desktop do not see each other. That is how MCP is designed.

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

Warp, Claude Desktop, Cursor, and most others use this `mcpServers` shape. VS Code uses `servers` instead — see `config/vscode-mcp.json`.

## Security (read this)

This MCP can run shell commands, read files, touch the clipboard, and SSH. Treat the host you attach it to as **fully trusted**. Block dangerous patterns in `~/.warp-command-runner/config.json`. Do not attach it to an untrusted or public MCP endpoint.
