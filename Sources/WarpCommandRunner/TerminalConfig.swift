import Foundation
import AppKit

/// Terminal configuration and detection
public struct TerminalConfig {
    public enum TerminalType: String, CaseIterable {
        case warp = "Warp"
        case warpPreview = "WarpPreview"
        case iterm2 = "iTerm"
        case terminal = "Terminal"
        case alacritty = "Alacritty"
    }
    
    /// Detect which terminals are installed
    public static func detectInstalledTerminals() -> [TerminalType] {
        var installed: [TerminalType] = []
        let workspace = NSWorkspace.shared
        
        for terminal in TerminalType.allCases {
            let bundleIds = getBundleIdentifiers(for: terminal)
            if bundleIds.contains(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }) {
                installed.append(terminal)
            }
        }
        
        return installed
    }
    
    /// Get the preferred terminal from config or auto-detect
    public static func getPreferredTerminal() -> TerminalType {
        // 1. Honour an explicit preference from config.json (terminal.preferred).
        //    Loaded quietly (logger nil) so this stays cheap to call.
        let config = ConfigurationManager.load()
        if let preferred = config.getPreferredTerminal() {
            return preferred
        }

        // 2. Auto-detect, honouring the configured fallback order when present,
        //    otherwise a sensible default order.
        let installed = detectInstalledTerminals()
        let configuredOrder: [TerminalType] = config.terminal.fallbackOrder.compactMap { raw in
            TerminalType.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        }
        let preferences = configuredOrder.isEmpty
            ? [.warp, .warpPreview, .iterm2, .terminal]
            : configuredOrder

        for preference in preferences {
            if installed.contains(preference) {
                return preference
            }
        }

        // Fallback to Terminal.app
        return .terminal
    }
    
    /// Get possible bundle identifiers for terminal type (Warp has multiple distribution variants)
    public static func getBundleIdentifiers(for terminal: TerminalType) -> [String] {
        switch terminal {
        case .warp:
            return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .warpPreview:
            return ["dev.warp.Warp-Preview"]
        case .iterm2:
            return ["com.googlecode.iterm2"]
        case .terminal:
            return ["com.apple.Terminal"]
        case .alacritty:
            return ["org.alacritty"]
        }
    }

    /// Get primary bundle identifier for terminal type
    public static func getBundleIdentifier(for terminal: TerminalType) -> String {
        return getBundleIdentifiers(for: terminal).first!
    }
    
    /// Get database path for Warp terminals
    public static func getWarpDatabasePath(for terminal: TerminalType) -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        
        switch terminal {
        case .warp:
            // Check Stable variant first (more common), then standard
            let stablePath = "\(homeDir)/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
            let standardPath = "\(homeDir)/Library/Application Support/dev.warp.Warp/warp.sqlite"
            return FileManager.default.fileExists(atPath: stablePath) ? stablePath : standardPath
        case .warpPreview:
            return "\(homeDir)/Library/Application Support/dev.warp.Warp-Preview/warp.sqlite"
        default:
            return nil
        }
    }
    
    /// Check if terminal supports database integration
    public static func supportsDatabaseIntegration(_ terminal: TerminalType) -> Bool {
        switch terminal {
        case .warp, .warpPreview:
            return true
        default:
            return false
        }
    }
}
