import Foundation
import MCP
import Logging

// MARK: - v5.0.0: Environment & Context Awareness

/// Handle get_environment_context tool — captures current terminal/project state
func handleGetEnvironmentContext(params: CallTool.Parameters, logger: Logger, config: Configuration) async -> CallTool.Result {
    var workingDirectory: String?
    if let arguments = params.arguments,
       let dir = arguments["working_directory"],
       case .string(let dirString) = dir {
        workingDirectory = dirString
    }

    let probeScript = buildEnvironmentProbeScript(workingDirectory: workingDirectory)

    logger.info("Probing environment context...")

    // Execute the probe script directly (no terminal needed)
    do {
        let result = try await runProcess(
            executablePath: "/bin/bash",
            arguments: ["-c", probeScript],
            timeout: 60
        )
        let output = result.stdout

        let context = parseEnvironmentOutput(output, logger: logger)

        logger.info("Environment context captured successfully")

        return CallTool.Result(
            content: [.text(context)],
            isError: false
        )
    } catch {
        logger.error("Failed to probe environment: \(error)")
        return CallTool.Result(
            content: [.text("❌ Failed to probe environment: \(error.localizedDescription)")],
            isError: true
        )
    }
}

// MARK: - Helper Functions

private func buildEnvironmentProbeScript(workingDirectory: String?) -> String {
    var script = "#!/bin/bash\n"

    if let dir = workingDirectory {
        script += "cd \"\(escapeForDoubleQuotedShell(dir))\" 2>/dev/null || true\n"
    }

    script += """
    echo "CCR_CWD=$(pwd)"
    echo "CCR_USER=$(whoami)"
    echo "CCR_HOSTNAME=$(hostname -s 2>/dev/null || echo 'unknown')"
    echo "CCR_SHELL=$SHELL"
    echo "CCR_GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo 'none')"
    echo "CCR_GIT_STATUS=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "CCR_GIT_REMOTE=$(git remote get-url origin 2>/dev/null || echo 'none')"
    echo "CCR_GIT_DIRTY=$(git diff --quiet 2>/dev/null && echo 'clean' || echo 'dirty')"
    echo "CCR_PYTHON_VENV=${VIRTUAL_ENV:-none}"
    echo "CCR_CONDA_ENV=${CONDA_DEFAULT_ENV:-none}"
    echo "CCR_NODE_VERSION=$(node -v 2>/dev/null || echo 'none')"
    echo "CCR_NPM_VERSION=$(npm -v 2>/dev/null || echo 'none')"
    echo "CCR_SWIFT_VERSION=$(swift --version 2>/dev/null | head -1 || echo 'none')"
    echo "CCR_PYTHON_VERSION=$(python3 --version 2>/dev/null || echo 'none')"
    echo "CCR_DOCKER_RUNNING=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
    echo "CCR_RUBY_VERSION=$(ruby -v 2>/dev/null | head -1 || echo 'none')"
    echo "CCR_GO_VERSION=$(go version 2>/dev/null || echo 'none')"
    echo "CCR_RUST_VERSION=$(rustc --version 2>/dev/null || echo 'none')"
    echo "CCR_XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 || echo 'none')"
    echo "CCR_HAS_MAKEFILE=$([ -f Makefile ] && echo 'yes' || echo 'no')"
    echo "CCR_HAS_PACKAGE_JSON=$([ -f package.json ] && echo 'yes' || echo 'no')"
    echo "CCR_HAS_PACKAGE_SWIFT=$([ -f Package.swift ] && echo 'yes' || echo 'no')"
    echo "CCR_HAS_CARGO_TOML=$([ -f Cargo.toml ] && echo 'yes' || echo 'no')"
    echo "CCR_HAS_REQUIREMENTS_TXT=$([ -f requirements.txt ] && echo 'yes' || echo 'no')"
    echo "CCR_HAS_DOCKERFILE=$([ -f Dockerfile ] && echo 'yes' || echo 'no')"
    echo "CCR_DISK_FREE=$(df -h . 2>/dev/null | tail -1 | awk '{print $4}')"
    """

    return script
}

private func parseEnvironmentOutput(_ output: String, logger: Logger) -> String {
    var values: [String: String] = [:]

    for line in output.components(separatedBy: "\n") {
        if line.hasPrefix("CCR_") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).replacingOccurrences(of: "CCR_", with: "")
                values[key] = String(parts[1])
            }
        }
    }

    // Build structured output
    var sections: [String] = []

    // System
    sections.append("🖥️  System:")
    sections.append("   User: \(values["USER"] ?? "unknown")")
    sections.append("   Host: \(values["HOSTNAME"] ?? "unknown")")
    sections.append("   Shell: \(values["SHELL"] ?? "unknown")")
    sections.append("   Disk Free: \(values["DISK_FREE"] ?? "unknown")")

    // Working Directory
    sections.append("")
    sections.append("📂 Working Directory: \(values["CWD"] ?? "unknown")")

    // Git
    let gitBranch = values["GIT_BRANCH"] ?? "none"
    if gitBranch != "none" {
        sections.append("")
        sections.append("🔀 Git:")
        sections.append("   Branch: \(gitBranch)")
        sections.append("   Status: \(values["GIT_DIRTY"] ?? "unknown") (\(values["GIT_STATUS"] ?? "0") changes)")
        sections.append("   Remote: \(values["GIT_REMOTE"] ?? "none")")
    }

    // Language Runtimes (only show detected ones)
    var runtimes: [String] = []
    if let v = values["SWIFT_VERSION"], v != "none" { runtimes.append("   Swift: \(v)") }
    if let v = values["NODE_VERSION"], v != "none" { runtimes.append("   Node: \(v) (npm \(values["NPM_VERSION"] ?? "?"))") }
    if let v = values["PYTHON_VERSION"], v != "none" { runtimes.append("   Python: \(v)") }
    if let v = values["RUBY_VERSION"], v != "none" { runtimes.append("   Ruby: \(v)") }
    if let v = values["GO_VERSION"], v != "none" { runtimes.append("   Go: \(v)") }
    if let v = values["RUST_VERSION"], v != "none" { runtimes.append("   Rust: \(v)") }
    if let v = values["XCODE_VERSION"], v != "none" { runtimes.append("   Xcode: \(v)") }

    if !runtimes.isEmpty {
        sections.append("")
        sections.append("🔧 Runtimes:")
        sections.append(contentsOf: runtimes)
    }

    // Virtual Environments
    let venv = values["PYTHON_VENV"] ?? "none"
    let conda = values["CONDA_ENV"] ?? "none"
    if venv != "none" || conda != "none" {
        sections.append("")
        sections.append("🐍 Virtual Environments:")
        if venv != "none" { sections.append("   Python venv: \(venv)") }
        if conda != "none" { sections.append("   Conda: \(conda)") }
    }

    // Docker
    let dockerCount = values["DOCKER_RUNNING"] ?? "0"
    if dockerCount != "0" {
        sections.append("")
        sections.append("🐳 Docker: \(dockerCount) container(s) running")
    }

    // Project Files
    var projectFiles: [String] = []
    if values["HAS_MAKEFILE"] == "yes" { projectFiles.append("Makefile") }
    if values["HAS_PACKAGE_JSON"] == "yes" { projectFiles.append("package.json") }
    if values["HAS_PACKAGE_SWIFT"] == "yes" { projectFiles.append("Package.swift") }
    if values["HAS_CARGO_TOML"] == "yes" { projectFiles.append("Cargo.toml") }
    if values["HAS_REQUIREMENTS_TXT"] == "yes" { projectFiles.append("requirements.txt") }
    if values["HAS_DOCKERFILE"] == "yes" { projectFiles.append("Dockerfile") }

    if !projectFiles.isEmpty {
        sections.append("")
        sections.append("📦 Project Files: \(projectFiles.joined(separator: ", "))")
    }

    return sections.joined(separator: "\n")
}
