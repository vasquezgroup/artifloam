import Foundation
import Darwin

/// One running process, as `ps` reports it.
public struct RunningProcess: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let uid: uid_t
    /// Percent of one core, as `ps` counts it.
    public let cpu: Double
    /// Resident memory in bytes.
    public let memory: UInt64
    /// The executable, usually a full path.
    public let path: String
    public var name: String { (path as NSString).lastPathComponent }
    public var mine: Bool { uid == getuid() }
    /// The outermost app the executable sits in: "Claude" for …/Claude.app/Contents/Helpers/disclaimer.
    public var appName: String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }
    /// The app bundle path, for its icon.
    public var appPath: String? { path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } }
    public var isSystem: Bool { appName == nil && ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"].contains { path.hasPrefix($0) } }
}

/// What runs on this Mac. Reading is free; ending a process is one confirmed process at a time, and only the person's own.
public enum ProcessList {
    public static func read() -> [RunningProcess] {
        parse(run("/bin/ps", ["-axww", "-o", "pid=,uid=,%cpu=,rss=,comm="], timeout: 10).output)
    }
    /// `ps` columns: pid, uid, %cpu, rss in KB, then the executable (which may contain spaces).
    static func parse(_ text: String) -> [RunningProcess] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let uid = UInt32(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(parts[3]) else { return nil }
            return RunningProcess(pid: pid, uid: uid, cpu: cpu, memory: rss * 1024, path: String(parts[4]).trimmingCharacters(in: .whitespaces))
        }
    }
    /// Whether this app may end the process: the person's own, never launchd or Artifloam itself.
    public static func endable(_ process: RunningProcess) -> Bool { process.mine && process.pid > 1 && process.pid != getpid() }
    /// Asks the process to quit (SIGTERM) or ends it at once (SIGKILL). The owner is checked again first:
    /// a PID can be reused by another program after the list was read.
    public static func end(_ process: RunningProcess, force: Bool) throws {
        guard endable(process) else { throw StewardError.blocked(String(localized: "This process belongs to macOS or another user, so Artifloam can't quit it.")) }
        guard let now = read().first(where: { $0.pid == process.pid }), now.path == process.path, endable(now) else {
            throw StewardError.blocked(String(localized: "This process has already ended."))
        }
        guard kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else { throw StewardError.blocked(String(cString: strerror(errno))) }
    }
}
