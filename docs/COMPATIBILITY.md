# Can any AI use Warp Command Runner?

**Short answer:** any app that is a **local MCP host** can spawn this binary over **stdio**. Phone apps and websites cannot spawn a process on your Mac. They can call it only if you opt into **remote MCP**: a loopback HTTP server plus a public HTTPS URL **you** create (your Cloudflare tunnel, your Tailscale Funnel, or your reverse proxy). This project does not host that URL.

**Short caveat:** exposing a terminal MCP on the public internet is dangerous. Remote mode is opt-in, binds `127.0.0.1` only, uses OAuth 2.1, and refuses Warp-routing (keystroke) tools unless you turn that on. Setup: [`docs/REMOTE.md`](REMOTE.md).

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

### Browser / phone chats without a tunnel

MCP stdio means “the chat app starts a child process on this computer.” A website or phone app cannot do that. Those hosts speak **remote MCP** (HTTPS) from the vendor's cloud.

v8 can serve that protocol on loopback (`warp-command-runner --http`) if **you** publish HTTPS with your own Cloudflare tunnel, Tailscale Funnel, or reverse proxy. This repo does not provide a hosted endpoint. Full steps: [`docs/REMOTE.md`](REMOTE.md).

Do not point a connector at a URL you do not control.

### Stdio-only path (still the default)

If you never enable `--http`, cloud chats still cannot see this Mac. That remains the safe default.

**The practical Grok-on-the-desk path:** install [Warp](https://app.warp.dev/referral/G9W3EY), set Warp's AI model to Grok, register this MCP in `~/.warp/.mcp.json`.

**The practical Grok-on-the-phone path:** `--http` plus your tunnel, then Grok → Connectors → custom MCP. See [`docs/REMOTE.md`](REMOTE.md).

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

This MCP can run shell commands, read files, touch the clipboard, and SSH. Treat the host you attach it to as **fully trusted**. Block dangerous patterns in `~/.warp-command-runner/config.json`. Remote MCP adds a public URL that **you** create. Anyone who can complete OAuth against that URL can run commands as you.
