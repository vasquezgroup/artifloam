import Foundation
import Darwin
import Darwin

/// For files in folders someone else can write to. A FIFO blocks forever and a device never ends, so only
/// regular files of a sane size are read. `Data(contentsOf:)` and `FileHandle` alone would hang a scan on either.
enum BoundedFile {
    static func isRegular(_ url: URL, limit: Int64 = .max) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size <= limit
    }
    static func read(_ url: URL, limit: Int64 = 4 << 20) -> Data? {
        guard limit >= 0 else { return nil }
        let parent = SecureRemoval.openWithoutFollowing(url.deletingLastPathComponent())
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= limit else { return nil }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if Task.isCancelled { return nil }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return nil }
            guard Int64(result.count) <= limit - Int64(count) else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, Int64(result.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return result
    }
}
