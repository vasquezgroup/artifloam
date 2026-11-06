import Foundation

struct CommandResult { let code: Int32; let output: String; let error: String }
func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> CommandResult {
    if Task.isCancelled { return CommandResult(code: 130, output: "", error: String(localized: "Operation cancelled")) }
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    // A fixed environment: DEVELOPER_DIR, GIT_*, PATH and friends can be set for every app with `launchctl setenv`
    // and would otherwise choose which binaries run here, with whatever access this app holds.
    let inherited = ProcessInfo.processInfo.environment
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "LC_ALL": "C"]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { environment[key] = inherited[key] }
    process.environment = environment
    // Files avoid pipe backpressure when lsof/git return more than a pipe buffer.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-steward-command-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stdout = folder.appendingPathComponent("out"), stderr = folder.appendingPathComponent("err")
        FileManager.default.createFile(atPath: stdout.path, contents: nil); FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close(); try? FileManager.default.removeItem(at: folder) }
        // Woken by the exit itself rather than polling: a scan runs thousands of short git commands.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.standardOutput = out; process.standardError = err; try process.run()
        let end = Date().addingTimeInterval(timeout)
        while exited.wait(timeout: .now() + 0.05) == .timedOut && Date() < end && !Task.isCancelled {}
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.1); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); return CommandResult(code: Task.isCancelled ? 130 : 124, output: "", error: Task.isCancelled ? String(localized: "Operation cancelled") : String(localized: "Command timed out")) }
        process.waitUntilExit()
        return CommandResult(code: process.terminationStatus, output: (try? String(contentsOf: stdout, encoding: .utf8)) ?? "", error: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
    } catch { try? FileManager.default.removeItem(at: folder); return CommandResult(code: 125, output: "", error: error.localizedDescription) }
}
public enum DeveloperTools {
    public static let gitExecutable: String? = {
        // Avoid triggering Apple's install dialog from a background scan.
        let developer = run("/usr/bin/xcode-select", ["-p"], timeout: 3)
        if developer.code == 0 {
            // The /usr/bin/git shim looks up this same folder on every call (about 8 ms each); ask once.
            let direct = developer.output.trimmingCharacters(in: .whitespacesAndNewlines) + "/usr/bin/git"
            return FileManager.default.isExecutableFile(atPath: direct) ? direct : "/usr/bin/git"
        }
        // Homebrew's Git is deliberately not used: any process of this user can replace it. Git checks then fail closed.
        return nil
    }()
    /// Shows Apple's own installer for Command Line Tools, which include Git.
    public static func installCommandLineTools() { _ = run("/usr/bin/xcode-select", ["--install"], timeout: 15) }
    /// A repository's own config can name commands for Git to run (fsmonitor, filters, hooks, gpg.program…), and scanned
    /// folders are untrusted. Listing those settings can't be complete, so only Git's own binaries may execute.
    /// A denied command makes Git fail or report a change, and every caller treats that as "keep".
    /// sandbox-exec is deprecated but still ships; if Apple removes it, Git checks fail closed and need a replacement.
    static let gitSandboxProfile: String? = gitExecutable.flatMap { git in
        let execPath = run(git, ["--exec-path"], timeout: 5).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let binary = realPath(git), let core = realPath(execPath) else { return nil }
        return "(version 1)(allow default)(deny process-exec*)(allow process-exec (literal \"\(sandboxEscaped(binary))\") (subpath \"\(sandboxEscaped(core))\"))"
    }
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private static func sandboxEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
func git(_ directory: URL, _ args: [String]) -> CommandResult {
    guard let executable = DeveloperTools.gitExecutable, let profile = DeveloperTools.gitSandboxProfile else { return CommandResult(code: 127, output: "", error: String(localized: "Git is unavailable. Install Git or Apple's Command Line Tools for project/worktree verification.")) }
    return run("/usr/bin/sandbox-exec", ["-p", profile, executable, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", directory.path] + args)
}
public struct ActivitySnapshot: Sendable {
    public let openPaths: [String]
    public var commands: String { didSet { commandBytes = Array(commands.utf8); lowercasedCommandBytes = Array(commands.lowercased().utf8) } }
    /// Command lines run to a few hundred KB (Electron apps), and every check searches them: a byte search,
    /// prepared once, finds the same matches about 50 times faster than String.contains.
    private var commandBytes: [UInt8], lowercasedCommandBytes: [UInt8]
    public var reliable: Bool
    /// Every open file and each folder above it, so `isActive` is one lookup instead of a scan of all open files.
    let openFolders: Set<String>
    public init(openPaths: [String] = [], commands: String = "", reliable: Bool = true) {
        self.openPaths = openPaths; self.commands = commands; self.reliable = reliable
        commandBytes = Array(commands.utf8); lowercasedCommandBytes = Array(commands.lowercased().utf8)
        var folders = Set<String>()
        for path in openPaths {
            var current = Substring(path)
            while !current.isEmpty, folders.insert(String(current)).inserted, let slash = current.lastIndex(of: "/") { current = current[..<slash] }
        }
        openFolders = folders
    }
    public static func capture() -> ActivitySnapshot {
        let files = run("/usr/sbin/lsof", ["-n", "-P", "-Fn"], timeout: 45)
        let processes = run("/bin/ps", ["-axo", "command"])
        return ActivitySnapshot(openPaths: openPaths(lsof: files.output, leaving: getpid()), commands: processes.output, reliable: files.code == 0 && processes.code == 0 && files.error.isEmpty)
    }
    /// Open file names from `lsof -F` output. lsof starts each process with a "p<pid>" line. The files of `pid` (this
    /// process) are left out: they are the folders the scan itself is reading, not another app using them. Child
    /// processes such as git have their own pids and are kept.
    static func openPaths(lsof output: String, leaving pid: pid_t) -> [String] {
        let own = "p\(pid)"
        var paths = [String](), mine = false
        for line in output.split(separator: "\n") {
            if line.first == "p" { mine = line == own } else if line.first == "n", !mine { paths.append(String(line.dropFirst())) }
        }
        return paths
    }
    public func isActive(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var variants = [path]
        for prefix in ["/var/", "/tmp/"] {
            if path.hasPrefix(prefix) { variants.append("/private" + path) }
            if path.hasPrefix("/private" + prefix) { variants.append(String(path.dropFirst(8))) }
        }
        return variants.contains { value in openFolders.contains(value) || commandsContain(value) }
    }
    /// Whether any running command line contains `text`; `ignoringCase` compares against the lowercased lines.
    func commandsContain(_ text: String, ignoringCase: Bool = false) -> Bool {
        let needle = Array(text.utf8)
        guard !needle.isEmpty else { return true }
        return (ignoringCase ? lowercasedCommandBytes : commandBytes).withUnsafeBytes { haystack in
            needle.withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
        }
    }
}
