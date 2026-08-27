import Foundation
import Logging

enum TunnelDoctor {
    struct Report: Equatable {
        var cloudflared: Bool
        var tailscale: Bool
        var publicBaseURL: String?
        var listenPort: Int
        var lines: [String]
    }

    static func run(config: Configuration) -> Report {
        let cloudflared = which("cloudflared")
        let tailscale = which("tailscale")
        let port = config.remote.listenPort
        let url = config.remote.publicBaseURL
        var lines: [String] = []
        lines.append("Loopback MCP: http://127.0.0.1:\(port)/mcp (this process never binds the public internet).")
        if let url, !url.isEmpty {
            lines.append("Configured public URL: \(url)/mcp")
            lines.append("Paste that URL into Grok, ChatGPT, or Claude as a custom MCP connector.")
        } else {
            lines.append("remote.publicBaseURL is unset. Cloud hosts cannot reach 127.0.0.1.")
            lines.append("Create a tunnel with YOUR Cloudflare or Tailscale account, then set publicBaseURL to that https origin (no trailing slash).")
        }
        if cloudflared {
            lines.append("cloudflared is on PATH. Named tunnel example (your account, your hostname):")
            lines.append("  cloudflared tunnel --url http://127.0.0.1:\(port)")
            lines.append("A quick tunnel hostname changes every start. Prefer a named tunnel you create in your Cloudflare dashboard.")
        } else {
            lines.append("cloudflared not found. Install it from Cloudflare's docs if you want a Cloudflare tunnel.")
        }
        if tailscale {
            lines.append("tailscale is on PATH. Funnel example (your tailnet):")
            lines.append("  tailscale funnel \(port)")
        } else {
            lines.append("tailscale not found. Install Tailscale if you want Funnel instead of Cloudflare.")
        }
        lines.append("This project does not host a relay and does not use a shared tunnel account.")
        return Report(
            cloudflared: cloudflared,
            tailscale: tailscale,
            publicBaseURL: url,
            listenPort: port,
            lines: lines
        )
    }

    static func which(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
