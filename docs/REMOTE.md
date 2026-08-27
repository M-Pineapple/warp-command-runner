# Remote MCP (phone and cloud chats)

Opt-in Streamable HTTP so Grok, ChatGPT, and Claude can call this Mac from a phone or a website. Local stdio is unchanged. Warp, Claude Desktop, and Cursor still spawn the binary as a child process.

The phone never opens a socket to your Mac. The vendor's cloud POSTs to a **public HTTPS URL that you create**. This project does not host that URL and does not use a shared tunnel account.

## What you run on the Mac

1. Keep using stdio for Warp / Claude Desktop if you already do.
2. Start a second process that listens on loopback only:

```bash
warp-command-runner --http
```

That binds `127.0.0.1` (default port `8741`). It never listens on `0.0.0.0`.

3. Point **your** tunnel or reverse proxy at that port. Examples (your accounts, your hostnames):

```bash
# Cloudflare named tunnel you created in your Cloudflare dashboard
cloudflared tunnel --url http://127.0.0.1:8741

# or Tailscale Funnel on your tailnet
tailscale funnel 8741
```

A Cloudflare *quick* tunnel hostname changes every start and will break saved connectors. Prefer a named tunnel.

4. Put the public origin in `~/.warp-command-runner/config.json` (no trailing slash):

```json
{
  "remote": {
    "listenPort": 8741,
    "publicBaseURL": "https://mcp.example.com",
    "allowKeystrokeTools": false,
    "requireMacApproval": false
  }
}
```

`https://mcp.example.com` is a placeholder. Use the hostname you created.

5. Run `warp-command-runner --remote-doctor` and fix anything it flags.

6. Keep the Mac awake. If this process is not running, the phone cannot call it.

### Start at login

```bash
warp-command-runner --install-agent
```

That writes a LaunchAgent in your home `Library/LaunchAgents` folder pointing at `/Applications/Warp Command Runner.app` when that bundle exists. Remove it with `--uninstall-agent`.

## Paste the URL into each host

Use `https://mcp.example.com/mcp` (your hostname) as the MCP server URL.

### Grok (web, iOS, Android)

Settings → Connectors → custom / Bring Your Own MCP. Paste the URL. Complete the browser Allow page. That page is served by this Mac through your tunnel.

### ChatGPT

On chatgpt.com (paid plan): Settings → Apps / Connectors → enable Developer mode → create a custom connector with the same URL. ChatGPT requires OAuth. This server implements OAuth 2.1 with PKCE and Dynamic Client Registration. Write tools need Developer mode. Whether the iOS app can invoke those writes is a ChatGPT limit; if iOS cannot, use Grok on the phone or ChatGPT on the web.

### Claude

claude.ai custom connector. Same URL. Same OAuth Allow page.

## What remote sessions may call

By default the five Warp-routing tools that type into the front tab are **refused** (`execute_command`, `execute_with_auto_retrieve`, `execute_with_streaming`, `run_template`, `send_to_session`). Use `execute_pipeline` from the phone.

Set `remote.allowKeystrokeTools` to `true` only if you understand that a cloud model will type into whatever Warp tab is focused on the desk.

## Security

- Bind is loopback. The public hole is whatever you created.
- Tokens live in `~/.warp-command-runner/oauth-store.json` with mode `0600`.
- Remote tool calls append to `~/.warp-command-runner/remote-audit.log`.
- Do not check tunnel tokens, certificates, or real hostnames into git.
- Treat any connector you add as fully trusted. This MCP can run shell commands as you, including `execute_pipeline` and `ssh_execute`. The five Warp-routing tools are the only ones refused by default.
- The OAuth `resource` parameter is stored on the authorisation code and is not yet checked at token exchange. A token from this server is valid for `POST /mcp` on this process.
- `requireMacApproval` in config is reserved. Setting it does not yet prompt on the Mac.

## Flags

| Flag | Meaning |
|---|---|
| `--http` | Streamable HTTP on 127.0.0.1 |
| `--http-port N` | Override `remote.listenPort` |
| `--remote-doctor` | Print tunnel / URL checks |
| `--install-agent` | User LaunchAgent for `--http` |
| `--uninstall-agent` | Remove that LaunchAgent |
