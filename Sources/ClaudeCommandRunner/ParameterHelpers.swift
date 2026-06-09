import Foundation
import MCP

// MARK: - Tool parameter extraction helpers
//
// Several tool schemas declare numeric parameters ("integer"/"number") but the
// handlers only matched `case .string`, so a client sending a JSON number per
// the published schema silently got the default value. These helpers accept
// both representations everywhere.

/// Extract an Int from a tool argument, accepting JSON numbers and strings.
func intArgument(_ value: Value?) -> Int? {
    guard let value = value else { return nil }
    switch value {
    case .int(let i): return i
    case .double(let d): return Int(d)
    case .string(let s): return Int(s)
    default: return nil
    }
}

/// Extract a Double from a tool argument, accepting JSON numbers and strings.
func doubleArgument(_ value: Value?) -> Double? {
    guard let value = value else { return nil }
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d
    case .string(let s): return Double(s)
    default: return nil
    }
}
