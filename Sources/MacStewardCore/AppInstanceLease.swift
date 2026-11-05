import Foundation
import Darwin

/// The process holds this descriptor for its lifetime. A second launch cannot
/// race the first into opening another main window; the OS releases it on exit.
public final class AppInstanceLease {
    private let descriptor: Int32
    public init?(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
