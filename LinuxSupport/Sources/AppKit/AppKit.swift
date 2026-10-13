import Foundation

/// In-memory stand-in for the two AppKit types this server touches.
/// Terminal detection reports nothing installed. Clipboard calls stay inside
/// this process.
public class NSWorkspace {
    public static let shared = NSWorkspace()

    public func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        nil
    }
}

public class NSPasteboard {
    public struct PasteboardType: RawRepresentable, Equatable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let string = PasteboardType(rawValue: "public.utf8-plain-text")
    }

    public static let general = NSPasteboard()

    private var text: String?

    public func clearContents() -> Int {
        let had = text == nil ? 0 : 1
        text = nil
        return had
    }

    public func setString(_ string: String, forType dataType: PasteboardType) -> Bool {
        guard dataType == .string else { return false }
        text = string
        return true
    }

    public func string(forType dataType: PasteboardType) -> String? {
        guard dataType == .string else { return nil }
        return text
    }
}
