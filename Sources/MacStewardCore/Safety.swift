import Foundation
import CryptoKit
import Darwin

public enum StewardError: Error, LocalizedError {
    case blocked(String)
    public var errorDescription: String? { if case .blocked(let message) = self { return message }; return nil }
}
struct Node: Sendable {
    let relative: String
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let mtime: timespec
    let ctime: timespec
    var signature: String { "\(relative)|\(device)|\(inode)|\(mode)|\(size)|\(mtime.tv_sec):\(mtime.tv_nsec)|\(ctime.tv_sec):\(ctime.tv_nsec)" }
}
struct TreeInventory {
    let nodes: [String: Node]
    let bytes: UInt64
    let newest: Date
    let lastAccessed: Date
    let fingerprint: String
    static let forbiddenNames: Set<String> = [".git", ".env", ".env.local", "auth.json", "credentials.json", "cookies", "login data", "history", "wallet.dat", ".npmrc", ".netrc", ".pypirc", "gradle.properties"]
    static let forbiddenExtensions: Set<String> = ["sqlite", "sqlite3", "db", "key", "pem", "p12", "pfx", "jks", "keystore", "mobileprovision", "xcarchive"]
    /// macOS volumes are usually case-insensitive, so `.ENV` and `Credentials.JSON` are the same protected files.
    static func isForbidden(name: String) -> Bool {
        let lower = name.lowercased()
        return forbiddenNames.contains(lower) || lower.hasPrefix(".env.") || forbiddenExtensions.contains((lower as NSString).pathExtension)
    }
    /// `dependencies` is for installed packages (node_modules…): symlinks are recorded, never followed, and registry files
    /// such as test certificates are allowed. Secure removal unlinks a symlink itself, not its target.
    /// Rules whose targets are rebuilt by their owner, so URL-cache databases and symlinks inside are expected.
    static let regenerableRules: Set<String> = ["inactive-dependencies", "app-cache", "xdg-cache", "simulator-cache", "homebrew-cache"]
    static func read(_ root: URL, dependencies: Bool = false) throws -> TreeInventory {
        var nodes = [String: Node](); var bytes: UInt64 = 0; var newest = Date.distantPast; var lastAccessed = Date.distantPast
        func record(_ url: URL, _ relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw StewardError.blocked(String(localized: "Cannot inspect \(url.lastPathComponent)")) }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT != S_IFLNK || (dependencies && !relative.isEmpty) else { throw StewardError.blocked(String(localized: "Symlink or another user's file: \(url.lastPathComponent)")) }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG || (dependencies && type == S_IFLNK) else { throw StewardError.blocked(String(localized: "Special filesystem object")) }
            guard dependencies || !isForbidden(name: url.lastPathComponent) else { throw StewardError.blocked(String(localized: "Protected data inside candidate: \(url.lastPathComponent)")) }
            if let parent = nodes[""], parent.device != info.st_dev { throw StewardError.blocked(String(localized: "Candidate crosses a filesystem boundary")) }
            nodes[relative] = Node(relative: relative, device: info.st_dev, inode: info.st_ino, mode: info.st_mode, size: info.st_size, mtime: info.st_mtimespec, ctime: info.st_ctimespec)
            if type == S_IFREG {
                bytes += UInt64(max(0, info.st_blocks)) * 512
                lastAccessed = max(lastAccessed, Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec)))
            }
            newest = max(newest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec)/1e9))
        }
        try record(root, "")
        if nodes[""]!.mode & S_IFMT == S_IFDIR {
            // The same physical walk as TreeSummary: symlinks are reported, never followed, and every entry is seen.
            // FileManager's enumerator hides AppleDouble "._" files, so the counts never matched the scan.
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(root.path), nil]
            defer { free(paths[0]) }
            let rootLength = strlen(paths[0]!)
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { throw StewardError.blocked(String(localized: "Cannot enumerate candidate")) }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                try Task.checkCancellation()
                let item = entry.pointee
                switch Int32(item.fts_info) {
                case FTS_DP: continue
                case FTS_DNR, FTS_ERR, FTS_NS: throw StewardError.blocked(String(localized: "Cannot inspect part of \(root.lastPathComponent)"))
                default: break
                }
                guard item.fts_level > 0 else { continue }
                let path = String(cString: item.fts_path)
                try record(URL(fileURLWithPath: path), String(cString: item.fts_path + rootLength + 1))
            }
        }
        // Same fingerprint as TreeSummary, so a lean scan can be compared with the full check at clean time.
        return TreeInventory(nodes: nodes, bytes: bytes, newest: newest, lastAccessed: lastAccessed, fingerprint: TreeSummary.fingerprint(count: nodes.count, bytes: bytes, newest: newest))
    }
}
public struct SafetyPolicy {
    public let configuration: Configuration
    /// Shared across one scan or cleanup, so each repository is asked for its root and tracked files once.
    let gitCache = GitCache()
    public init(configuration: Configuration) { self.configuration = configuration }
    func inside(_ path: URL, _ root: URL) -> Bool { path.path.hasPrefix(root.path + "/") }
    func validatePath(_ url: URL, rule: String) throws {
        let p = url.standardizedFileURL
        guard p.path == url.path, p.resolvingSymlinksInPath().path == p.path else { throw StewardError.blocked(String(localized: "Non-canonical or symlinked path")) }
        let home = configuration.home.standardizedFileURL
        guard !configuration.ignoredPaths.contains(where: { p.path == $0 || p.path.hasPrefix($0 + "/") }) else { throw StewardError.blocked(String(localized: "Path is on the ignore list")) }
        let relative = inside(p, home) ? String(p.path.dropFirst(home.path.count + 1)) : ""
        let safe: Bool
        switch rule {
        case "agent-xcode-intermediates":
            let container = p.lastPathComponent == "Intermediates.noindex" ? p.deletingLastPathComponent().deletingLastPathComponent() : p.deletingLastPathComponent()
            let plist = BoundedFile.read(container.appendingPathComponent("info.plist")).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
            safe = inside(p, configuration.agentTemp) && p.pathComponents.contains("scratchpad") && ["Intermediates.noindex", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"].contains(p.lastPathComponent) && plist?["WorkspacePath"] is String && FileManager.default.fileExists(atPath: container.appendingPathComponent("Build").path)
        case "xcode-intermediates":
            safe = relative.hasPrefix("Library/Developer/Xcode/DerivedData/") && relative.split(separator: "/").count == 7 && p.lastPathComponent == "Intermediates.noindex" && p.deletingLastPathComponent().lastPathComponent == "Build"
        case "nx-task-cache":
            safe = configuration.projectRoots.contains(where: { inside(p, $0) }) && p.deletingLastPathComponent().path.hasSuffix("/.nx/cache") && p.lastPathComponent.allSatisfy(\.isNumber) && !p.lastPathComponent.isEmpty
        case "framework-cache":
            safe = configuration.projectRoots.contains(where: { inside(p, $0) }) && ["/.next/cache", "/.angular/cache", "/.nx/cache"].contains(where: { p.path.hasSuffix($0) }) && !p.path.hasSuffix("/.nx/cache")
        case "python-bytecode": safe = configuration.projectRoots.contains(where: { inside(p, $0) }) && p.lastPathComponent == "__pycache__"
        case "project-test-cache": safe = configuration.projectRoots.contains(where: { inside(p, $0) }) && [".pytest_cache", ".mypy_cache", ".ruff_cache"].contains(p.lastPathComponent)
        case "application-web-cache":
            safe = configuration.includeApplicationCaches && ApplicationWebCaches.valid(p, home: home)
        case "gradle-generated-cache": safe = configuration.includeDeveloperCaches && DeveloperJunk.hasGradleMarker(home: home) && DeveloperJunk.validGradlePath(p, home: home)
        case "xcode-module-cache":
            safe = configuration.includeDeveloperCaches && p.deletingLastPathComponent().path == home.appendingPathComponent("Library/Developer/Xcode/DerivedData/ModuleCache.noindex").path && (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && (10...64).contains(p.lastPathComponent.count) && p.lastPathComponent.contains(where: \.isNumber) && p.lastPathComponent.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        case "homebrew-cache": safe = configuration.includeDeveloperCaches && relative == "Library/Caches/Homebrew"
        case "npm-cache": safe = configuration.includeDeveloperCaches && relative == ".npm/_cacache"
        case "old-user-log": safe = DeveloperJunk.validLog(relative: relative) && (relative.hasPrefix("Library/Logs/CoreSimulator/") || configuration.includeAdditionalLogs)
        case "app-cache": safe = p.deletingLastPathComponent().path == home.appendingPathComponent("Library/Caches").path && BroadCaches.allowedAppCache(p.lastPathComponent)
        case "xdg-cache": safe = p.deletingLastPathComponent().path == home.appendingPathComponent(".cache").path && BroadCaches.xdgCandidates(home: home).contains { $0.standardizedFileURL.path == p.path }
        case "simulator-cache": safe = BroadCaches.validSimulatorPath(p, home: home)
        case "old-agent-version":
            safe = DeveloperJunk.agentVersionRoots(home: home).contains { DeveloperJunk.oldAgentVersions(in: $0).map(\.standardizedFileURL.path).contains(p.path) }
        case "inactive-dependencies":
            safe = configuration.projectRoots.contains(where: { inside(p, $0) }) && ProjectActivity.dependencyFolder(p)
        default: safe = false
        }
        guard safe else { throw StewardError.blocked(String(localized: "No allowlisted cleanup rule for this exact path")) }
        let forbiddenParts: Set<String> = [".git", "archives", "mobilesync", "sourcepackages", "node_modules", ".venv", "venv", "vendor", ".codex", "projects-history"]
        // The dependency rule targets node_modules itself, but never one nested inside another protected folder.
        let checkedParts = rule == "inactive-dependencies" ? p.deletingLastPathComponent().pathComponents : p.pathComponents
        guard Set(checkedParts.map { $0.lowercased() }).isDisjoint(with: forbiddenParts), !p.pathComponents.contains(where: { $0.lowercased().hasSuffix(".xcarchive") }) else { throw StewardError.blocked(String(localized: "Protected storage location")) }
        let selectedProject = configuration.projectRoots.contains(where: { inside(p, $0) })
        let globalDeveloperCache = ["gradle-generated-cache", "xcode-module-cache"].contains(rule)
        if selectedProject || globalDeveloperCache {
            let directory = (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? p : p.deletingLastPathComponent()
            let rootResult = gitCache.root(of: directory)
            if rootResult.code == 0 {
                let root = URL(fileURLWithPath: rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL
                guard inside(p, root) else { throw StewardError.blocked(String(localized: "Repository root cannot be a cleanup target")) }
                let rel = String(p.path.dropFirst(root.path.count + 1))
                let ignored = git(root, ["check-ignore", "--", rel])
                guard let tracked = gitCache.tracks(rel, in: root), !tracked, ignored.code == 0 else { throw StewardError.blocked(String(localized: "Tracked or non-ignored files are protected")) }
            } else {
                // A verified producer-owned global cache may be outside Git, but
                // a missing Git executable or an ambiguous failure is not proof.
                guard !selectedProject, globalDeveloperCache, rootResult.code == 128,
                      rootResult.error.contains("not a git repository") else {
                    throw StewardError.blocked(String(localized: "Cannot verify Git protection for this cache"))
                }
            }
        }
    }
    /// `approved`: the user chose this held item. It then skips only the age and unchanged-since-scan checks
    /// (a recent cache keeps changing); every path, activity and running-app check still applies.
    func validate(_ finding: Finding, activity: ActivitySnapshot, approved: Bool = false) throws -> TreeInventory {
        let held = approved && finding.safety != .automatic && finding.userCleanable
        guard finding.safety == .automatic || held else { throw StewardError.blocked(String(localized: "Review-only item cannot be automatically cleaned")) }
        guard activity.reliable else { throw StewardError.blocked(String(localized: "Cannot verify running processes and open files")) }
        let url = URL(fileURLWithPath: finding.path, isDirectory: FileManager.default.fileExists(atPath: finding.path))
        try validatePath(url, rule: finding.rule)
        guard !activity.isActive(url), !DeveloperJunk.producerActive(rule: finding.rule, path: finding.path, activity: activity), !(finding.rule == "application-web-cache" && ApplicationWebCaches.producerActive(url, home: configuration.home, activity: activity)) else { throw StewardError.blocked(String(localized: "A running process uses this path")) }
        if finding.rule == "inactive-dependencies", let reason = ProjectActivity.busyReason(url.deletingLastPathComponent(), activity: activity, sessions: .load(claudeHome: configuration.claudeHome, codexHome: configuration.codexHome)) { throw StewardError.blocked(String(localized: "Project is in use: \(reason)")) }
        if finding.rule == "app-cache", BroadCaches.ownerRunning(url.lastPathComponent, running: BroadCaches.runningApps()) { throw StewardError.blocked(String(localized: "Its app is running")) }
        if finding.rule == "simulator-cache", BroadCaches.simulatorRunning(activity) { throw StewardError.blocked(String(localized: "A simulator is running")) }
        let tree = try TreeInventory.read(url, dependencies: TreeInventory.regenerableRules.contains(finding.rule))
        let days = DeveloperJunk.minimumAge(rule: finding.rule, configured: configuration.minimumAgeDays)
        let lastUse = ["gradle-generated-cache", "xcode-module-cache"].contains(finding.rule) ? max(tree.newest, tree.lastAccessed) : tree.newest
        guard held || lastUse < Date().addingTimeInterval(-Double(days)*86400) else { throw StewardError.blocked(String(localized: "Files were used too recently")) }
        guard held || tree.fingerprint == finding.fingerprint else { throw StewardError.blocked(String(localized: "Files changed after the scan; scan again")) }
        return tree
    }
}

/// Scan-time measurement: one fts pass with the same refusals as TreeInventory, keeping only totals.
/// Memory stays flat however many files a cache holds; TreeInventory still runs right before removal.
struct TreeSummary {
    let bytes: UInt64
    let newest: Date
    let lastAccessed: Date
    let fingerprint: String
    static func fingerprint(count: Int, bytes: UInt64, newest: Date) -> String {
        "\(count):\(bytes):\(Int64((newest.timeIntervalSince1970 * 1e6).rounded()))"
    }
    static func read(_ root: URL, dependencies: Bool = false) throws -> TreeSummary {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw StewardError.blocked(String(localized: "Cannot inspect \(root.lastPathComponent)")) }
        guard rootInfo.st_mode & S_IFMT != S_IFLNK, rootInfo.st_uid == getuid() else { throw StewardError.blocked(String(localized: "Symlink or another user's file: \(root.lastPathComponent)")) }
        var count = 0, bytes: UInt64 = 0, newest = 0.0, accessed = 0.0
        func record(_ info: stat, name: String, top: Bool) throws {
            let type = info.st_mode & S_IFMT
            guard info.st_uid == getuid(), type != S_IFLNK || (dependencies && !top) else { throw StewardError.blocked(String(localized: "Symlink or another user's file: \(name)")) }
            guard type == S_IFDIR || type == S_IFREG || (dependencies && type == S_IFLNK) else { throw StewardError.blocked(String(localized: "Special filesystem object")) }
            guard dependencies || !TreeInventory.isForbidden(name: name) else { throw StewardError.blocked(String(localized: "Protected data inside candidate: \(name)")) }
            guard info.st_dev == rootInfo.st_dev else { throw StewardError.blocked(String(localized: "Candidate crosses a filesystem boundary")) }
            count += 1
            if type == S_IFREG { bytes += UInt64(max(0, info.st_blocks)) * 512; accessed = max(accessed, Double(info.st_atimespec.tv_sec)) }
            newest = max(newest, Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        }
        try record(rootInfo, name: root.lastPathComponent, top: true)
        if rootInfo.st_mode & S_IFMT == S_IFDIR {
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(root.path), nil]
            defer { free(paths[0]) }
            // Physical walk: symlinks are reported, never followed; other volumes are not entered.
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { throw StewardError.blocked(String(localized: "Cannot enumerate candidate")) }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                if Task.isCancelled { throw CancellationError() }
                let item = entry.pointee
                switch Int32(item.fts_info) {
                case FTS_DP: continue
                case FTS_DNR, FTS_ERR, FTS_NS: throw StewardError.blocked(String(localized: "Cannot inspect part of \(root.lastPathComponent)"))
                default: break
                }
                guard item.fts_level > 0, let info = item.fts_statp?.pointee else { continue }
                try record(info, name: (String(cString: item.fts_path) as NSString).lastPathComponent, top: false)
            }
        }
        let newestDate = Date(timeIntervalSince1970: newest)
        return TreeSummary(bytes: bytes, newest: newestDate, lastAccessed: Date(timeIntervalSince1970: accessed), fingerprint: fingerprint(count: count, bytes: bytes, newest: newestDate))
    }
}
// Descriptor-relative deletion never follows symlinks or swaps across directory boundaries.
// A changed/new node stops deletion; the remaining staged cache is restored when possible.
struct SecureRemoval {
    /// Opens a directory one component at a time, so a symlink swapped in anywhere along the path after the
    /// safety check is refused rather than followed. /var and /tmp are the system's own links into /private.
    static func openWithoutFollowing(_ directory: URL) -> Int32 {
        var parts = Array(directory.standardizedFileURL.pathComponents.dropFirst())
        if let first = parts.first, ["var", "tmp", "etc"].contains(first) { parts.insert("private", at: 0) }
        var fd = open("/", O_SEARCH)
        for part in parts where fd >= 0 {
            let next = openat(fd, part, O_SEARCH | O_NOFOLLOW)
            close(fd)
            fd = next
        }
        return fd
    }
    static func remove(_ url: URL, tree: TreeInventory) throws {
        let parent = url.deletingLastPathComponent()
        let fd = openWithoutFollowing(parent)
        guard fd >= 0 else { throw StewardError.blocked(String(localized: "Cannot open parent directory")) }
        defer { close(fd) }
        var parentInfo = stat(); guard fstat(fd, &parentInfo) == 0 else { throw StewardError.blocked(String(localized: "Cannot verify parent")) }
        var rootInfo = stat()
        guard fstatat(fd, url.lastPathComponent, &rootInfo, AT_SYMLINK_NOFOLLOW) == 0, let expected = tree.nodes[""], rootInfo.st_ino == expected.inode, rootInfo.st_dev == expected.device else { throw StewardError.blocked(String(localized: "Target changed before cleanup")) }
        let staged = ".mac-steward-cleaning-\(UUID().uuidString)"
        guard renameat(fd, url.lastPathComponent, fd, staged) == 0 else { throw StewardError.blocked(String(localized: "Cannot stage cache for cleanup")) }
        do {
            try erase(parent: fd, name: staged, relative: "", nodes: tree.nodes, stagedRoot: true)
        } catch {
            // Never replace a new original directory created by an application.
            var occupied = stat()
            if fstatat(fd, url.lastPathComponent, &occupied, AT_SYMLINK_NOFOLLOW) != 0 { _ = renameat(fd, staged, fd, url.lastPathComponent) }
            throw StewardError.blocked(String(localized: "Cleanup stopped: \(error.localizedDescription). Any remaining files are in \(parent.path)/\(staged) or the original cache path."))
        }
    }
    private static func erase(parent: Int32, name: String, relative: String, nodes: [String: Node], stagedRoot: Bool = false) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, let expected = nodes[relative], info.st_ino == expected.inode, info.st_dev == expected.device, info.st_mode == expected.mode else { throw StewardError.blocked(String(localized: "Filesystem entry changed at \(relative); expected node present: \(String(nodes[relative] != nil))")) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        if !isDirectory {
            guard info.st_size == expected.size, info.st_mtimespec.tv_sec == expected.mtime.tv_sec, info.st_mtimespec.tv_nsec == expected.mtime.tv_nsec, (stagedRoot || (info.st_ctimespec.tv_sec == expected.ctime.tv_sec && info.st_ctimespec.tv_nsec == expected.ctime.tv_nsec)) else { throw StewardError.blocked(String(localized: "File changed during cleanup")) }
            guard unlinkat(parent, name, 0) == 0 else { throw StewardError.blocked(String(localized: "Could not remove cache file")) }
            return
        }
        let childFD = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard childFD >= 0 else { throw StewardError.blocked(String(localized: "Directory replaced or unavailable")) }
        var opened = stat()
        guard fstat(childFD, &opened) == 0, opened.st_ino == expected.inode, opened.st_dev == expected.device else { close(childFD); throw StewardError.blocked(String(localized: "Directory changed while opening")) }
        guard let directory = fdopendir(childFD) else { close(childFD); throw StewardError.blocked(String(localized: "Cannot enumerate open directory")) }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            let childName = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if childName == "." || childName == ".." { continue }
            let childRelative = relative.isEmpty ? childName : relative + "/" + childName
            try erase(parent: childFD, name: childName, relative: childRelative, nodes: nodes)
        }
        // Check that the parent name still names the inode opened above.
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_ino == expected.inode, current.st_dev == expected.device else { throw StewardError.blocked(String(localized: "Directory moved during cleanup")) }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw StewardError.blocked(String(localized: "Directory acquired new data; it was not removed")) }
    }
}

/// Decides whether a project is idle enough that its installed dependencies can be rebuilt later.
enum ProjectActivity {
    static let idleDays = 30
    /// Dependency folders directly inside a project that has the lockfile needed to reinstall them.
    static func dependencyFolder(_ url: URL) -> Bool {
        let project = url.deletingLastPathComponent(), has = { FileManager.default.fileExists(atPath: project.appendingPathComponent($0).path) }
        switch url.lastPathComponent {
        case "node_modules": return has("package.json") && ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"].contains(where: has)
        case "target": return has("Cargo.toml") && has("Cargo.lock")
        case ".build": return has("Package.swift")
        default: return false
        }
    }
    /// nil when the project is idle; otherwise why it must stay.
    static func busyReason(_ project: URL, activity: ActivitySnapshot, sessions: AgentSessionIndex, now: Date = Date()) -> String? {
        let cutoff = now.addingTimeInterval(-Double(idleDays) * 86400)
        if activity.isActive(project) { return String(localized: "open in a running app") }
        let status = git(project, ["status", "--porcelain", "--untracked-files=no"])
        guard status.code == 0 else { return String(localized: "Git status could not be verified") }
        if !status.output.isEmpty { return String(localized: "uncommitted changes") }
        if let time = TimeInterval(git(project, ["log", "-1", "--format=%ct"]).output.trimmingCharacters(in: .whitespacesAndNewlines)), Date(timeIntervalSince1970: time) > cutoff { return String(localized: "committed in the last \(idleDays) days") }
        if let used = sessions.lastUsed(project), used > cutoff { return String(localized: "used by Claude Code or Codex in the last \(idleDays) days") }
        return nil
    }
}

/// Memoised Git answers for one scan. Thread-safe: scan checks run concurrently.
final class GitCache: @unchecked Sendable {
    private let lock = NSLock()
    private var roots = [String: CommandResult]()
    private var trackedFolders = [String: Set<String>?]()
    /// `git rev-parse --show-toplevel`, reused for folders inside a known root when no nested repository sits between.
    func root(of directory: URL) -> CommandResult {
        let path = directory.standardizedFileURL.path
        lock.lock(); let cached = roots[path]; let known = roots
        lock.unlock()
        if let cached { return cached }
        // Reuse an enclosing root unless a .git marker (nested repo or worktree) lies between.
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { break }
            let parent = current.deletingLastPathComponent()
            if let hit = known[parent.path], hit.code == 0, hit.output.trimmingCharacters(in: .whitespacesAndNewlines) == parent.path { return store(path, hit) }
            // Outside any repository stays outside while no .git appears on the way down (6,800 Gradle folders, one git call).
            if let miss = known[parent.path], miss.code == 128, miss.error.contains("not a git repository") { return store(path, miss) }
            current = parent
        }
        let result = git(directory, ["rev-parse", "--show-toplevel"])
        if result.code == 0 { _ = store(result.output.trimmingCharacters(in: .whitespacesAndNewlines), result) }
        // Git checked every parent too, unless it stopped at a filesystem boundary.
        if result.code == 128, result.error.contains("not a git repository"), !result.error.contains("boundary") {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path != "/" { _ = store(parent.path, result); parent = parent.deletingLastPathComponent() }
        }
        return store(path, result)
    }
    private func store(_ key: String, _ value: CommandResult) -> CommandResult { lock.lock(); roots[key] = value; lock.unlock(); return value }
    /// Whether `relative` is a tracked file or contains one; nil when Git cannot answer.
    func tracks(_ relative: String, in root: URL) -> Bool? {
        lock.lock(); let cached = trackedFolders[root.path]; lock.unlock()
        let folders: Set<String>?
        if let cached { folders = cached } else {
            let result = git(root, ["ls-files", "-z"])
            var set: Set<String>? = nil
            if result.code == 0 {
                var built = Set<String>()
                for file in result.output.split(separator: "\0") {
                    var current = Substring(file)
                    while !current.isEmpty, built.insert(String(current)).inserted, let slash = current.lastIndex(of: "/") { current = current[..<slash] }
                }
                set = built
            }
            lock.lock(); trackedFolders[root.path] = .some(set); lock.unlock()
            folders = set
        }
        return folders.map { $0.contains(relative) }
    }
}
