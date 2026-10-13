#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public typealias SecRandomRef = OpaquePointer

public let kSecRandomDefault: SecRandomRef? = nil

@discardableResult
public func SecRandomCopyBytes(
    _ rnd: SecRandomRef?,
    _ count: Int,
    _ bytes: UnsafeMutableRawPointer?
) -> Int32 {
    guard count > 0, let bytes else { return -1 }
    let fd = open("/dev/urandom", O_RDONLY)
    if fd < 0 { return -1 }
    defer { close(fd) }
    var filled = 0
    let raw = bytes.bindMemory(to: UInt8.self, capacity: count)
    while filled < count {
        let n = read(fd, raw.advanced(by: filled), count - filled)
        if n <= 0 { return -1 }
        filled += n
    }
    return 0
}
