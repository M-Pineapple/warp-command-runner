import Foundation

#if os(Linux)
/// Linux has no `O_EVTONLY`. Opening read-only keeps a descriptor the macOS
/// watcher would have held. swift-corelibs-dispatch has the event mask type
/// but no file-system object source, so watches do not fire on Linux.
let O_EVTONLY: Int32 = O_RDONLY

final class LinuxDispatchFileSystemSource {
    func setEventHandler(_ handler: @escaping () -> Void) {}
    func setCancelHandler(_ handler: @escaping () -> Void) {}
    func resume() {}
    func suspend() {}
    func cancel() {}
}

typealias DispatchSourceFileSystemObject = LinuxDispatchFileSystemSource

extension DispatchSource {
    static func makeFileSystemObjectSource(
        fileDescriptor: Int32,
        eventMask: DispatchSource.FileSystemEvent,
        queue: DispatchQueue? = nil
    ) -> DispatchSourceFileSystemObject {
        LinuxDispatchFileSystemSource()
    }
}
#endif
