import Foundation
import CryptoKit

public struct DuplicateGroup: Identifiable, Codable, Sendable {
    public let id: String
    public let files: [String]
    public let size: UInt64
    /// Copies inside a Git checkout. Untracked, but a project may still need them, so only a person ticks these.
    public var projectFiles: [String] = []
    public var extraCount: Int {
        let outside = files.filter { !projectFiles.contains($0) }.count
        return projectFiles.isEmpty ? max(0, files.count - 1) : outside
    }
    public var potentialBytes: UInt64 { size * UInt64(extraCount) }
    public init(id: String, files: [String], size: UInt64, projectFiles: [String] = []) { self.id = id; self.files = files; self.size = size; self.projectFiles = projectFiles }
    /// The copy each group keeps: the oldest by creation date. Reads each file's date once; call it off the main thread.
    public static func oldestCopies(_ groups: [DuplicateGroup]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: groups.map { group in
            // A project keeps its copy; a spare outside it is what goes.
            let dated = (group.projectFiles.isEmpty ? group.files : group.projectFiles).map { ($0, (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture) }
            return (group.id, dated.min { $0.1 < $1.1 }?.0 ?? group.files[0])
        })
    }
    /// Every copy except the kept one, without touching the disk.
    public static func extras(_ groups: [DuplicateGroup], keeping kept: [String: String]) -> Set<String> {
        Set(groups.flatMap { group in
            let keep = kept[group.id].flatMap { group.files.contains($0) ? $0 : nil } ?? group.files[0]
            return group.files.filter { $0 != keep && !group.projectFiles.contains($0) }
        })
    }
    /// The chosen paths, minus one copy per group if a group would otherwise lose every copy.
    public static func trashable(_ chosen: Set<String>, in groups: [DuplicateGroup]) -> [String] {
        groups.flatMap { group -> [String] in
            let picked = group.files.filter { chosen.contains($0) }
            return picked.count == group.files.count ? Array(picked.dropFirst()) : picked
        }
    }
}
public enum DuplicateFinder {
    private static func canonical(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    /// Includes the selected directory's ancestors: a chosen subfolder can already be inside a checkout.
    static func enclosingRepository(_ url: URL) -> URL? {
        var directory = canonical(url)
        while directory.pathComponents.count > 1 {
            var info = stat()
            if lstat(directory.appendingPathComponent(".git").path, &info) == 0 { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    static func isUntrackedOrOutsideRepository(_ path: String) -> Bool {
        let file = canonical(URL(fileURLWithPath: path))
        guard let repository = enclosingRepository(file.deletingLastPathComponent()) else { return true }
        let relative = String(file.path.dropFirst(repository.path.count + 1))
        let tracked = git(repository, ["--literal-pathspecs", "ls-files", "-z", "--", relative])
        return tracked.code == 0 && tracked.output.isEmpty
    }
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [DuplicateGroup] {
        try scan(folder: home.appendingPathComponent("Downloads"))
    }
    /// A file's content hash, read through one descriptor, so the checks below describe the bytes actually hashed.
    /// nil for anything but a regular file, or one that changed while being read.
    struct Hashed: Equatable { let hash: String; let size: UInt64; let device: dev_t; let inode: ino_t }
    static func hashed(_ path: String) throws -> Hashed? {
        // O_NONBLOCK: opening a FIFO planted here must not wait for a writer.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return nil }
        var digest = SHA256()
        do { while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data); try Task.checkCancellation() } }
        catch is CancellationError { throw CancellationError() } catch { return nil }
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        return Hashed(hash: digest.finalize().map { String(format: "%02x", $0) }.joined(), size: UInt64(max(0, before.st_size)), device: before.st_dev, inode: before.st_ino)
    }
    public static func scan(folder: URL) throws -> [DuplicateGroup] {
        let folder = canonical(folder)
        // iCloud status is slow to read (most of the walk), so it is asked only for files that share a size.
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path) // surface permission errors
        // Apps, libraries, environments and build output hold intentional copies; removing one breaks whatever needs it.
        let skipped: Set<String> = ["node_modules", ".git", "pods", "deriveddata", ".build", "library", "venv", "site-packages", "vendor", "target", "dist"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var bySize = [Int: [URL]](), repositories = enclosingRepository(folder).map { [$0.path] } ?? []
        for case let url as URL in walker {
            try Task.checkCancellation()
            // An unreadable file is skipped: one locked file must not end the whole search.
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                if skipped.contains(url.lastPathComponent.lowercased()) { walker.skipDescendants() }
                else if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { repositories.append(url.path) }
                continue
            }
            guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size >= 1_000_000 else { continue }
            bySize[size, default: []].append(url)
        }
        // Asked once per checkout, and only if one holds a candidate. Files Git tracks are never offered; if Git can't answer, the whole checkout stays out.
        var tracked = [String: Set<String>?]()
        func trackedFiles(in root: String) -> Set<String>? {
            if let known = tracked[root] { return known }
            let result = git(URL(fileURLWithPath: root), ["ls-files", "-z"])
            let files = result.code == 0 ? Set(result.output.split(separator: "\0").map { (root + "/" + $0).precomposedStringWithCanonicalMapping }) : nil
            tracked[root] = .some(files)
            return files
        }
        /// The innermost checkout holding this file, if any.
        func repository(of path: String) -> String? { repositories.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count } }
        var results = [DuplicateGroup]()
        for (size, sameSize) in bySize where sameSize.count > 1 {
            let files = sameSize.filter { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) != true }
            guard files.count > 1 else { continue }
            var hashes = [String: [String]](), seen = Set<String>(), inProject = Set<String>()
            for file in files {
                try Task.checkCancellation()
                if let root = repository(of: file.path) {
                    guard let known = trackedFiles(in: root), !known.contains(file.path.precomposedStringWithCanonicalMapping) else { continue }
                    inProject.insert(file.path)
                }
                guard let found = try hashed(file.path) else { continue }
                // Hard links are one file under two names: removing one frees nothing.
                guard seen.insert("\(found.device):\(found.inode)").inserted else { continue }
                hashes[found.hash, default: []].append(file.path)
            }
            for (hash, paths) in hashes where paths.count > 1 { results.append(DuplicateGroup(id: hash, files: paths.sorted(), size: UInt64(size), projectFiles: paths.filter(inProject.contains).sorted())) }
        }
        return results.sorted { $0.potentialBytes > $1.potentialBytes }
    }
    /// The scan may be old by now. Keeps only paths that still match their group, while a separate copy of the same
    /// content still exists outside the chosen paths, so "one copy always stays" holds at the moment of removal.
    public static func stillSafeToTrash(_ paths: [String], in groups: [DuplicateGroup]) throws -> (paths: [String], dropped: Int) {
        let chosen = Set(paths)
        var safe = [String]()
        for group in groups {
            let picked = group.files.filter { chosen.contains($0) }
            guard !picked.isEmpty else { continue }
            let kept = try group.files.filter { !chosen.contains($0) }.lazy.compactMap { try hashed($0) }.first { $0.hash == group.id }
            guard let kept else { continue }
            for path in picked {
                if isUntrackedOrOutsideRepository(path), let file = try hashed(path), file.hash == group.id, file.device != kept.device || file.inode != kept.inode { safe.append(path) }
            }
        }
        return (safe, chosen.count - safe.count)
    }
}
public enum Scheduler {
    public static let label = StewardPreferences.domain + ".safe-cleanup"
    /// The label up to version 0.18.
    static let legacyLabel = "local.macsteward.safe-cleanup"
    public static var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private static var legacyAgentURL: URL { agentURL.deletingLastPathComponent().appendingPathComponent(legacyLabel + ".plist") }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }
    /// Stops and removes a schedule from an older version. True if there was one, so the app can turn it on again under the new label.
    @discardableResult public static func retireLegacy() -> Bool {
        guard FileManager.default.fileExists(atPath: legacyAgentURL.path) else { return false }
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyLabel)"])
        try? FileManager.default.removeItem(at: legacyAgentURL)
        return true
    }
    public static func enable(helper: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path), ["Mac Steward.app", "Artifloam.app"].contains(where: { helper.standardizedFileURL.path == "/Applications/\($0)/Contents/Helpers/stewardctl" }) else { throw StewardError.blocked("Install Artifloam in Applications before enabling the schedule") }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSteward")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Run only as the signed-in user. No privilege helper, no RunAtLoad, no worktree deletion.
        let job: [String: Any] = ["Label": label, "ProgramArguments": [helper.path, "clean-safe", "--days", "7", "--scheduled"], "StartCalendarInterval": ["Hour": 12, "Minute": 15], "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10, "StandardOutPath": directory.appendingPathComponent("schedule.log").path, "StandardErrorPath": directory.appendingPathComponent("schedule-error.log").path]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        if isInstalled { _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"]) }
        try data.write(to: agentURL, options: [.atomic])
        let result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentURL.path])
        guard result.code == 0 else { try? FileManager.default.removeItem(at: agentURL); throw StewardError.blocked("Could not enable schedule: \(result.error)") }
    }
    public static func disable() throws {
        retireLegacy()
        let result = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        // A missing/unloaded job can still have a configuration that should be removed.
        if result.code != 0 && result.error.lowercased().contains("not permitted") { throw StewardError.blocked(result.error) }
        if isInstalled { try FileManager.default.removeItem(at: agentURL) }
    }
}
