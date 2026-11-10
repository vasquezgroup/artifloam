import Foundation
import Darwin
import AppKit

/// A review captures identity and metadata; deleting revalidates them immediately before removing
/// the item for good. Nothing goes to the Trash. Never escalates privileges.
public struct TrashCandidate: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public let cloud: StorageCloudStatus
    fileprivate let identity: String
}
public struct TrashOutcome: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let trashPath: String?
    public let error: String?
}
public enum ReviewedTrash {
    private static func fingerprint(_ url: URL) throws -> (String, Bool) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw StewardError.blocked(String(localized: "This item is no longer accessible. Refresh and review again.")) }
        guard value.st_mode & S_IFMT != S_IFLNK else { throw StewardError.blocked(String(localized: "Symbolic links cannot be removed here. Reveal the item in Finder.")) }
        let kind = value.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else { throw StewardError.blocked(String(localized: "Only ordinary files and folders can be deleted here.")) }
        return ("\(value.st_dev):\(value.st_ino):\(value.st_gen):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)", kind == S_IFDIR)
    }
    static let credentialFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".password-store", ".gcloud", ".trash"]
    static func allowed(_ url: URL, home: URL, allowApplication: Bool, allowLeftover: Bool = false) -> Bool {
        var path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        // A selected symlink ancestor must not redirect the reviewed operation.
        guard url.deletingLastPathComponent().standardizedFileURL.path == url.deletingLastPathComponent().resolvingSymlinksInPath().path else { return false }
        let appRoots = ["/Applications/", homePath + "/Applications/"]
        if allowApplication && appRoots.contains(where: { path.hasPrefix($0) }) && url.pathExtension.lowercased() == "app" && !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            // The bundle identifier is only a claim: an app naming itself com.apple.x is not protected by that.
            guard let identifier = Bundle(url: url)?.bundleIdentifier, !AppleCode.isProtectedApp(url, identifier: identifier) else { return false }
            return true
        }
        // App leftovers: only a reverse-DNS entry directly inside the Library folders AppLeftovers searches. Checked first, since com.vendor.app ends in ".app".
        if allowLeftover, AppLeftovers.bundleID(url.lastPathComponent) != nil, AppLeftovers.locations.contains(where: { url.deletingLastPathComponent().standardizedFileURL.path == homePath + "/" + $0.0 }) { return true }
        guard !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { return false }
        // Inside a Photos library, a virtual machine or a disk image, one file removed damages the whole.
        var ancestor = url.deletingLastPathComponent()
        while ancestor.pathComponents.count > 1 {
            if (try? ancestor.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return false }
            ancestor.deleteLastPathComponent()
        }
        // macOS volumes are usually case-insensitive: ~/library and ~/.SSH are the same protected folders.
        path = path.lowercased(); homePath = homePath.lowercased()
        let fixed = [homePath, homePath + "/desktop", homePath + "/documents", homePath + "/downloads", homePath + "/pictures", homePath + "/music", homePath + "/movies", homePath + "/applications"]
        guard !fixed.contains(path), !path.hasPrefix(homePath + "/.trash/"), path != homePath + "/.trash" else { return false }
        guard path != homePath + "/library", !path.hasPrefix(homePath + "/library/") || path.hasPrefix(homePath + "/library/cloudstorage/") || path.hasPrefix(homePath + "/library/mobile documents/") else { return false }
        if path.hasPrefix(homePath + "/") {
            let relative = String(path.dropFirst(homePath.count + 1))
            if let top = relative.split(separator: "/").first, top.hasPrefix(".") {
                // One file deep inside a tool's hidden folder (an emulator disk, a cache database) may go to Trash.
                // Hidden folders themselves, and credential stores, stay protected.
                guard relative.contains("/"), !credentialFolders.contains(String(top)),
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false else { return false }
            }
            // Cloud-provider roots are navigation containers, never removal targets.
            let parent = (path as NSString).deletingLastPathComponent
            for root in [homePath + "/library/cloudstorage", homePath + "/library/mobile documents"] where path == root || parent == root { return false }
            return true
        }
        if path.hasPrefix("/volumes/") { return path.split(separator: "/").count > 2 && !path.contains("/.trashes/") }
        return false
    }
    public static func review(_ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser, allowApplications: Bool = false, allowLeftovers: Bool = false) throws -> [TrashCandidate] {
        let unique = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        guard !unique.isEmpty else { throw StewardError.blocked(String(localized: "Select an item first.")) }
        var result = [TrashCandidate]()
        for url in unique {
            guard allowed(url, home: home, allowApplication: allowApplications, allowLeftover: allowLeftovers) else { throw StewardError.blocked(String(localized: "\(url.lastPathComponent) is a protected location. Use Finder or the app’s own management tools.")) }
            if result.contains(where: { url.path.hasPrefix($0.url.path + "/") }) { continue }
            let (identity, directory) = try fingerprint(url)
            result.append(TrashCandidate(url: url, isDirectory: directory, cloud: StorageMapper.cloudStatus(url, flags: 0, home: home), identity: identity))
        }
        return result
    }
    /// For a run with no per-file review: one bad item only keeps that item, and cloud files always wait for a person,
    /// because deleting them can also delete them from the cloud.
    public static func reviewUnattended(_ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser, allowLeftovers: Bool = false) -> (ready: [TrashCandidate], kept: Int) {
        let ready = urls.compactMap { try? review([$0], home: home, allowLeftovers: allowLeftovers).first }.filter { $0.cloud == .local }
        return (ready, urls.count - ready.count)
    }
    /// `progress` gets (items done, bytes moved so far, current item) after each item; `shouldStop` is asked before each one.
    /// Stopping returns the outcomes so far; items not reached stay where they are.
    public static func move(_ candidates: [TrashCandidate], home: URL = FileManager.default.homeDirectoryForCurrentUser, allowApplications: Bool = false, allowLeftovers: Bool = false, duplicateGroups: [DuplicateGroup] = [],
                            progress: (@Sendable (Int, UInt64, String) -> Void)? = nil, shouldStop: @Sendable () -> Bool = { false }) -> [TrashOutcome] {
        let results = move(candidates, home: home, allowApplications: allowApplications, allowLeftovers: allowLeftovers, duplicateGroups: duplicateGroups, progress: progress, shouldStop: shouldStop) { url in
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
            guard !running.contains(where: { $0.path == url.path || $0.path.hasPrefix(url.path + "/") || url.path.hasPrefix($0.path + "/") }) else { throw StewardError.blocked(String(localized: "A selected item is used by a running app. Quit it yourself and review again.")) }
            try FileManager.default.removeItem(at: url)
            return nil
        }
        let folder = home.appendingPathComponent("Library/Application Support/MacSteward/TrashReceipts")
        pruneReceipts(in: folder)
        if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil {
            let record: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "items": results.map { ["path": $0.path, "trashPath": $0.trashPath ?? "", "error": $0.error ?? ""] }]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic) }
        }
        return results
    }
    /// These receipts name personal files that were deleted, so after 90 days they are deleted too.
    /// Cleanup receipts (caches) stay: Activity adds them up into the space freed over time.
    static func pruneReceipts(in folder: URL, olderThanDays days: Double = 90, now: Date = Date()) {
        for file in children(folder) where file.pathExtension == "json" {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, now.timeIntervalSince(date) > days * 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    static func move(_ candidates: [TrashCandidate], home: URL, allowApplications: Bool = false, allowLeftovers: Bool = false, duplicateGroups: [DuplicateGroup] = [],
                     progress: ((Int, UInt64, String) -> Void)? = nil, shouldStop: () -> Bool = { false }, operation: (URL) throws -> String?) -> [TrashOutcome] {
        var outcomes = [TrashOutcome](), moved: UInt64 = 0
        for candidate in candidates {
            if shouldStop() { break }
            // Folders count as 0 bytes here: walking them for a size would slow the move down.
            let size = candidate.isDirectory ? 0 : UInt64((try? candidate.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            do {
                // Review can stay open while a kept copy changes. Recheck immediately before every move,
                // excluding every chosen path from the copies we rely on keeping.
                if !duplicateGroups.isEmpty {
                    let groups = duplicateGroups.filter { $0.files.contains(candidate.url.path) }
                    let safe = try DuplicateFinder.stillSafeToTrash(candidates.map { $0.url.path }, in: groups)
                    guard safe.paths.contains(candidate.url.path) else { throw StewardError.blocked(String(localized: "The duplicate or the copy being kept changed. Scan again.")) }
                }
                guard allowed(candidate.url, home: home, allowApplication: allowApplications, allowLeftover: allowLeftovers), try fingerprint(candidate.url).0 == candidate.identity else { throw StewardError.blocked(String(localized: "Item changed since review. Refresh and review again.")) }
                let destination = try operation(candidate.url)
                moved += size
                outcomes.append(TrashOutcome(path: candidate.url.path, trashPath: destination, error: nil))
            } catch { outcomes.append(TrashOutcome(path: candidate.url.path, trashPath: nil, error: error.localizedDescription)) }
            progress?(outcomes.count, moved, candidate.url.lastPathComponent)
        }
        return outcomes
    }
}
