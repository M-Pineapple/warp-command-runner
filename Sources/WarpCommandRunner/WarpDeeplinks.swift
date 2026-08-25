import Foundation
import Logging

/// Helpers for invoking Warp Terminal via its `warp://` URL scheme.
///
/// Warp dispatches `warp://` URLs through `app/src/uri/mod.rs` (see warp source,
/// AGPL — referenced for protocol shape only, not vendored). The actions we
/// rely on for v6.0 are documented in the upstream `UriHost::Action` enum:
///
///   warp://action/new_tab?path=<dir>      Open a new tab (optionally cd'd)
///   warp://action/new_window?path=<dir>   Open a new window
///   warp://session/<uuid>                 Focus an existing pane by UUID
///
/// Limitation noted in TECH.md §4.2: `warp://action/new_tab` does **not**
/// return the new tab's UUID. We cannot bind our session registry to Warp's
/// internal session UUIDs from this side. `focusWarpSession(uuid:)` therefore
/// only works when the caller has a UUID obtained out-of-band — typically
/// from the optional shell shim's OSC 777 stream (Tier E). Documented; not
/// a v6.0 regression because v5 had no focus-by-UUID at all.
enum WarpDeeplinks {

    /// Dispatch a `warp://` URL through `open(1)`. Non-blocking; Warp is
    /// activated/focused by macOS as a side effect.
    @discardableResult
    static func dispatch(_ url: String, logger: Logger) -> (success: Bool, error: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]

        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0 {
                logger.debug("dispatched deeplink: \(url)")
                return (true, nil)
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            logger.warning("deeplink dispatch failed (\(proc.terminationStatus)): \(errStr)")
            return (false, errStr.isEmpty ? "open(1) exit \(proc.terminationStatus)" : errStr)
        } catch {
            logger.error("deeplink dispatch threw: \(error)")
            return (false, error.localizedDescription)
        }
    }

    /// Open a new Warp tab, optionally cd'd to `directory`.
    ///
    /// Replaces the v5 path that ran AppleScript `click menu item "New Tab"`.
    /// Doesn't require Accessibility permission for the open path itself
    /// (typing into the tab afterwards still does).
    @discardableResult
    static func openNewTab(directory: String? = nil, logger: Logger) -> (success: Bool, error: String?) {
        let url = buildURL(host: "action", path: "/new_tab", queryItems: queryItems(directory: directory))
        return dispatch(url, logger: logger)
    }

    /// Open a new Warp window, optionally cd'd to `directory`.
    @discardableResult
    static func openNewWindow(directory: String? = nil, logger: Logger) -> (success: Bool, error: String?) {
        let url = buildURL(host: "action", path: "/new_window", queryItems: queryItems(directory: directory))
        return dispatch(url, logger: logger)
    }

    /// Focus an existing pane by its Warp session UUID.
    ///
    /// Requires the UUID to actually be a UUID Warp knows about — see file
    /// header for limitation.
    @discardableResult
    static func focusSession(uuid: String, logger: Logger) -> (success: Bool, error: String?) {
        let url = buildURL(host: "session", path: "/\(uuid)", queryItems: [])
        return dispatch(url, logger: logger)
    }

    // MARK: - URL construction

    private static func buildURL(host: String, path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.scheme = "warp"
        components.host = host
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        // URLComponents.string is non-nil when scheme+host are set.
        return components.string ?? "warp://\(host)\(path)"
    }

    private static func queryItems(directory: String?) -> [URLQueryItem] {
        guard let directory, !directory.isEmpty else { return [] }
        // URLQueryItem handles percent-encoding for us. Expanded `~` first so
        // Warp gets an absolute path; Warp does not expand `~` itself.
        let expanded = (directory as NSString).expandingTildeInPath
        return [URLQueryItem(name: "path", value: expanded)]
    }
}
