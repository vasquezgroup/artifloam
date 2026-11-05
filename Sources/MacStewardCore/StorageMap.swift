import Foundation
import Darwin

public enum StorageCloudStatus: String, Sendable { case local, cloud, onlineOnly, unknownCloud }
public struct StorageMapEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// Allocated local file blocks, never remote/account storage.
    public let bytes: UInt64
    public let logicalBytes: UInt64
    public let cloudLogicalBytes: UInt64
    public let cloudLocalBytes: UInt64
    public let cloudFileCount: Int
    public let onlineOnlyCount: Int
    public let unknownCloudCount: Int
    public let isDirectory: Bool
    public let complete: Bool
    public let fileCount: Int
}
/// Space per kind of file.
public struct StorageKind: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: UInt64
    public let files: Int
    static let extensions: [(String, Set<String>)] = [
        ("Videos", ["mov", "mp4", "m4v", "avi", "mkv", "webm", "braw", "mxf", "prproj"]),
        ("Images", ["jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "psd", "raw", "cr2", "cr3", "nef", "arw", "dng", "webp", "svg", "ai", "exr"]),
        ("Audio", ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "logicx"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "xip"]),
        ("Disk images", ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "qcow2", "pvm", "hdd"]),
        ("Documents", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf", "csv", "epub"]),
        ("Code & data", ["swift", "js", "ts", "tsx", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "json", "xml", "yml", "yaml", "sql", "sqlite", "db", "log", "map"]),
        ("Apps & libraries", ["dll", "exe", "dylib", "so", "a", "framework", "car", "nib", "node", "jar", "o"])
    ]
    public static func classify(_ path: String) -> String {
        let index = kindIndex(path)
        return index < 0 ? "Other" : extensions[Int(index)].0
    }
    /// Position in `extensions`, or -1 for Other.
    static func kindIndex(_ path: String) -> Int8 {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.firstIndex { $0.1.contains(ext) }.map(Int8.init) ?? -1
    }
}
public struct StorageMapSnapshot: Sendable {
    public let root: URL
    public let entries: [StorageMapEntry]
    public let largestFiles: [StorageMapEntry]
    public let largestLogicalFiles: [StorageMapEntry]
    public let largestCloudFiles: [StorageMapEntry]
    public let unreadableCount: Int
    public var kinds: [StorageKind] = []
    public let limited: Bool
    public let finished: Bool
    public let examinedCount: Int
    public let reusedCount: Int
    public let refreshedFolderCount: Int
    public let incremental: Bool
    public let currentPath: String
    fileprivate let nodes: [String: StorageMapNode]
    public var bytes: UInt64 { entries.reduce(0) { $0 + $1.bytes } }
    public var logicalBytes: UInt64 { entries.reduce(0) { $0 + $1.logicalBytes } }
    public var cloudLogicalBytes: UInt64 { entries.reduce(0) { $0 + $1.cloudLogicalBytes } }
    public var cloudLocalBytes: UInt64 { entries.reduce(0) { $0 + $1.cloudLocalBytes } }
    public var cloudFileCount: Int { entries.reduce(0) { $0 + $1.cloudFileCount } }
    public var onlineOnlyCount: Int { entries.reduce(0) { $0 + $1.onlineOnlyCount } }
    public var canRefreshIncrementally: Bool { finished && !limited && !nodes.isEmpty }
    /// Even a partial map's measured folders can open a subfolder without reading them again; only what is missing gets read.
    public var canOpenSubfolders: Bool { finished && !nodes.isEmpty }
    /// Everything inside this folder is already measured, so opening it needs no reading to speak of.
    public func hasMeasured(_ url: URL) -> Bool { nodes[url.path]?.complete == true }
}
fileprivate struct FileIdentity: Hashable, Sendable { let device: dev_t; let inode: UInt64 }
fileprivate struct StorageMapNode: Sendable {
    let directory: Bool
    /// Device and inode; nil for placeholders and the root.
    let identity: FileIdentity?
    let bytes: UInt64
    let logical: UInt64
    let cloud: StorageCloudStatus
    var children: [String] = []
    var complete = true
    var unreadable = 0
    var subtreeCount = 1
    var regular = false
    /// `StorageKind.kindIndex` of a regular file, read once when it is measured.
    var kind: Int8 = -1
}

/// Metadata-only mapping. Neither stat nor the cloud resource keys read file
/// contents, request a download, evict data or invoke the cleaner.
public enum StorageMapper {
    public static func scan(root: URL, maximumEntries: Int = 500_000, maximumDuration: TimeInterval = 45,
                            progress: @Sendable (StorageMapSnapshot) -> Void = { _ in }) throws -> StorageMapSnapshot {
        try run(root: root, previous: nil, changedPaths: [], maximumEntries: maximumEntries, maximumDuration: maximumDuration, cloudProbe: { cloudStatus($0, flags: $1) }, progress: progress)
    }
    /// `root` may be a folder inside `previous`: its measured subtree is reused without reading it again.
    public static func refresh(_ previous: StorageMapSnapshot, root: URL? = nil, changedPaths: [URL], forceFull: Bool = false,
                               maximumEntries: Int = 500_000, maximumDuration: TimeInterval = 45,
                               progress: @Sendable (StorageMapSnapshot) -> Void = { _ in }) throws -> StorageMapSnapshot {
        let subfolder = root.map { $0.standardizedFileURL.resolvingSymlinksInPath().path != previous.root.path } ?? false
        return try run(root: root ?? previous.root, previous: !forceFull && (previous.canRefreshIncrementally || (subfolder && previous.canOpenSubfolders)) ? previous : nil,
                changedPaths: changedPaths, maximumEntries: maximumEntries, maximumDuration: maximumDuration, cloudProbe: { cloudStatus($0, flags: $1) }, progress: progress)
    }
    static func cloudStatus(_ url: URL, flags: UInt32, home homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> StorageCloudStatus {
        let dataless = flags & UInt32(SF_DATALESS) != 0
        let home = homeURL.path
        let provider = url.path.hasPrefix(home + "/Library/CloudStorage/") || url.path.hasPrefix(home + "/Library/Mobile Documents/")
        // Desktop/Documents can be backed by iCloud without a CloudStorage path, but only while that sync is on.
        let possibleICloud = provider || ((url.path.hasPrefix(home + "/Desktop/") || url.path.hasPrefix(home + "/Documents/")) && desktopAndDocumentsMaySync(homeURL))
        guard possibleICloud || dataless else { return .local }
        if provider && dataless { return .onlineOnly }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isRegularFileKey]) else { return provider ? .unknownCloud : .local }
        if values.isRegularFile == nil { return provider ? .unknownCloud : .local }
        if values.isUbiquitousItem == true {
            if dataless || values.ubiquitousItemDownloadingStatus == .notDownloaded { return .onlineOnly }
            return values.ubiquitousItemDownloadingStatus == nil ? .unknownCloud : .cloud
        }
        return provider ? .cloud : .local
    }
    private static let syncLock = NSLock()
    nonisolated(unsafe) private static var syncAnswers = [String: (Bool, Date)]()
    /// Whether Desktop and Documents may be in iCloud. Asking per file is most of a map's time there, so this is
    /// asked once (and again after 30 s). Anything other than a clear "no" keeps the per-file check.
    static func desktopAndDocumentsMaySync(_ home: URL) -> Bool {
        syncLock.lock(); defer { syncLock.unlock() }
        if let (answer, date) = syncAnswers[home.path], Date().timeIntervalSince(date) < 30 { return answer }
        let finder = UserDefaults(suiteName: "com.apple.finder")
        let finderSync = ["FXICloudDriveDesktop", "FXICloudDriveDocuments"].contains { finder?.bool(forKey: $0) == true }
        let folderSync = ["Desktop", "Documents"].contains { name in
            let folder = home.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return false }
            // Unreadable status counts as "may sync"; a readable non-iCloud folder reports nil, as its files do.
            guard let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]) else { return true }
            return values.isUbiquitousItem == true
        }
        let answer = finderSync || folderSync
        syncAnswers[home.path] = (answer, Date())
        return answer
    }
    static func run(root requested: URL, previous: StorageMapSnapshot?, changedPaths: [URL], maximumEntries: Int, maximumDuration: TimeInterval,
                    cloudProbe: @Sendable (URL, UInt32) -> StorageCloudStatus,
                    progress: @Sendable (StorageMapSnapshot) -> Void = { _ in }) throws -> StorageMapSnapshot {
        try Task.checkCancellation()
        let root = requested.standardizedFileURL.resolvingSymlinksInPath()
        let base = previous?.root.path ?? ""
        let prior = previous.flatMap { root.path == base || root.path.hasPrefix(base == "/" ? "/" : base + "/") ? $0 : nil }
        var dirty = Set<String>()
        for changed in changedPaths {
            // Preserve the final component: a file/directory replaced by a
            // symlink must invalidate its OLD cached entry, not the link target.
            let lexical = changed.standardizedFileURL
            var path = lexical.path == "/" ? "/" : lexical.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(lexical.lastPathComponent).path
            guard path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { continue }
            while true {
                dirty.insert(path)
                if path == root.path || path == "/" { break }
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
        // Only this folder's nodes: what else the larger map holds must not use up this run's node cap.
        var nodes = prior.map { map in root.path == base ? map.nodes : map.nodes.filter { $0.key == root.path || $0.key.hasPrefix(root.path + "/") } } ?? [:]
        let start = Date()
        var count = 0, reused = 0, folders = 0, limited = false
        var currentPath = root.path
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw StewardError.blocked("Cannot read the selected folder.") }
        let initial = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            !(root.path == "/" && ["dev", "Volumes"].contains($0.lastPathComponent)) && $0.path != "/System/Volumes"
        }.map { root.appendingPathComponent($0.lastPathComponent) }.sorted { $0.path < $1.path }
        // Keep unmeasured top-level folders navigable in a bounded/partial map.
        for url in initial where nodes[url.path] == nil {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let directory = values?.isDirectory == true && values?.isSymbolicLink != true
            nodes[url.path] = StorageMapNode(directory: directory, identity: nil, bytes: 0, logical: 0, cloud: .local, complete: false)
        }
        nodes[root.path] = StorageMapNode(directory: true, identity: nil, bytes: 0, logical: 0, cloud: .local, children: initial.map(\.path))
        var lastPublished: StorageMapSnapshot?
        var lastPulse = Date.distantPast
        func snapshot(_ finished: Bool, keepCache: Bool = false) -> StorageMapSnapshot {
            struct Totals {
                var local: UInt64 = 0, logical: UInt64 = 0, cloud: UInt64 = 0, cloudLocal: UInt64 = 0
                var files = 0, cloudFiles = 0, online = 0, unknown = 0, unreadable = 0
                var complete = true
                mutating func add(_ value: Totals) { local += value.local; logical += value.logical; cloud += value.cloud; cloudLocal += value.cloudLocal; files += value.files; cloudFiles += value.cloudFiles; online += value.online; unknown += value.unknown; unreadable += value.unreadable; complete = complete && value.complete }
            }
            var kindTotals = [String: (UInt64, Int)]()
            var seen = Set<FileIdentity>(), reachable: Set<String> = [root.path], largest = [StorageMapEntry](), logicalLargest = [StorageMapEntry](), cloudLargest = [StorageMapEntry]()
            func entry(_ path: String, _ value: Totals) -> StorageMapEntry {
                StorageMapEntry(url: URL(fileURLWithPath: path), bytes: value.local, logicalBytes: value.logical, cloudLogicalBytes: value.cloud, cloudLocalBytes: value.cloudLocal, cloudFileCount: value.cloudFiles, onlineOnlyCount: value.online, unknownCloudCount: value.unknown, isDirectory: nodes[path]?.directory ?? false, complete: value.complete, fileCount: value.files)
            }
            // Only a kept cache needs the reachable set; when every node is reachable the cache is kept as it is.
            var reached = nodes[root.path] == nil ? 0 : 1
            func total(_ path: String) -> Totals {
                let found = nodes[path]
                if keepCache, reachable.insert(path).inserted, found != nil { reached += 1 }
                guard let node = found else { return Totals(complete: false) }
                var value = Totals(unreadable: node.unreadable, complete: node.complete)
                if node.regular {
                    // Global de-duplication is recomputed across cached AND changed
                    // branches, so a hard link crossing folders is still counted once.
                    if let identity = node.identity { guard seen.insert(identity).inserted else { return value } }
                    value.local = node.bytes; value.logical = node.logical; value.files = 1
                    let kind = node.kind < 0 ? "Other" : StorageKind.extensions[Int(node.kind)].0, sum = kindTotals[kind] ?? (0, 0)
                    kindTotals[kind] = (sum.0 + node.bytes, sum.1 + 1)
                    if node.cloud != .local { value.cloud = node.logical; value.cloudLocal = node.bytes; value.cloudFiles = 1 }
                    value.online = node.cloud == .onlineOnly ? 1 : 0; value.unknown = node.cloud == .unknownCloud ? 1 : 0
                    if node.logical >= 1_000_000 || node.bytes >= 1_000_000 {
                        let row = entry(path, value)
                        largest.append(row); logicalLargest.append(row)
                        if row.cloudFileCount > 0 { cloudLargest.append(row) }
                        if logicalLargest.count > 40 { logicalLargest.sort { $0.logicalBytes > $1.logicalBytes }; logicalLargest.removeLast(logicalLargest.count - 30) }
                        if cloudLargest.count > 40 { cloudLargest.sort { $0.cloudLogicalBytes > $1.cloudLogicalBytes }; cloudLargest.removeLast(cloudLargest.count - 30) }
                        if largest.count > 40 { largest.sort { $0.bytes > $1.bytes }; largest.removeLast(largest.count - 30) }
                    }
                } else { for child in node.children { value.add(total(child)) } }
                return value
            }
            var unreadable = 0
            let entries = initial.map { url -> StorageMapEntry in let value = total(url.path); unreadable += value.unreadable; return entry(url.path, value) }.sorted { $0.bytes > $1.bytes }
            let cache = keepCache ? (reached == nodes.count ? nodes : nodes.filter { reachable.contains($0.key) }) : [:]
            let kinds = kindTotals.map { StorageKind(name: $0.key, bytes: $0.value.0, files: $0.value.1) }.sorted { $0.bytes > $1.bytes }
            return StorageMapSnapshot(root: root, entries: entries, largestFiles: Array(largest.sorted { $0.bytes > $1.bytes }.prefix(30)), largestLogicalFiles: Array(logicalLargest.sorted { $0.logicalBytes > $1.logicalBytes }.prefix(30)), largestCloudFiles: Array(cloudLargest.sorted { $0.cloudLogicalBytes > $1.cloudLogicalBytes }.prefix(30)), unreadableCount: unreadable, kinds: kinds, limited: limited, finished: finished, examinedCount: count, reusedCount: reused, refreshedFolderCount: folders, incremental: prior != nil, currentPath: currentPath, nodes: cache)
        }
        func pulse() {
            guard Date().timeIntervalSince(lastPulse) > 0.15 else { return }; lastPulse = Date()
            let base = lastPublished ?? prior
            if let base {
                progress(StorageMapSnapshot(root: root, entries: base.entries, largestFiles: base.largestFiles, largestLogicalFiles: base.largestLogicalFiles, largestCloudFiles: base.largestCloudFiles, unreadableCount: base.unreadableCount, kinds: base.kinds, limited: limited, finished: false, examinedCount: count, reusedCount: reused, refreshedFolderCount: folders, incremental: prior != nil, currentPath: currentPath, nodes: [:]))
            }
        }
        func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }
        /// `known` is what the parent's listing said about this entry; the top level is read with lstat.
        func visit(_ path: String, known: BulkEntry?, device: dev_t?, depth: Int) throws -> StorageMapNode {
            try Task.checkCancellation()
            if let cached = nodes[path], cached.complete, prior != nil,
               !dirty.contains(path) {
                reused += cached.subtreeCount; return cached
            }
            guard count < max(1, maximumEntries), Date().timeIntervalSince(start) < maximumDuration, depth < 128,
                  nodes.count < 1_000_000 || nodes[path] != nil else {
                limited = true
                let partial = StorageMapNode(directory: nodes[path]?.directory ?? false, identity: nil, bytes: 0, logical: 0, cloud: .local, complete: false)
                nodes[path] = partial; return partial
            }
            count += 1; currentPath = path
            if count.isMultiple(of: 1024) { pulse() }
            func failed() -> StorageMapNode {
                let failed = StorageMapNode(directory: false, identity: nil, bytes: 0, logical: 0, cloud: .local, complete: false, unreadable: 1)
                nodes[path] = failed; return failed
            }
            var item: BulkEntry
            if let known { item = known } else {
                var info = stat()
                guard lstat(path, &info) == 0 else { return failed() }
                let mode = info.st_mode & S_IFMT
                item = BulkEntry(name: "", type: (mode == S_IFDIR ? VDIR : mode == S_IFREG ? VREG : mode == S_IFLNK ? VLNK : VBAD).rawValue, device: info.st_dev, fileID: info.st_ino,
                                 flags: info.st_flags, allocated: UInt64(max(0, info.st_blocks)) * 512, logical: UInt64(max(0, info.st_size)))
            }
            // A folder is opened before its device is compared: a mount point shows its own volume only once opened, as lstat did.
            var folder: Int32 = -1
            if item.isDirectory {
                folder = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                var info = stat()
                if folder >= 0 ? fstat(folder, &info) == 0 : lstat(path, &info) == 0 {
                    item = BulkEntry(name: item.name, type: item.type, device: info.st_dev, fileID: info.st_ino, flags: info.st_flags, allocated: 0, logical: 0)
                } else if folder < 0 { return failed() }
            }
            defer { if folder >= 0 { close(folder) } }
            let identity = FileIdentity(device: item.device, inode: item.fileID)
            var node = StorageMapNode(directory: item.isDirectory, identity: identity, bytes: 0, logical: 0, cloud: .local)
            if let device, device != item.device { node.complete = false; nodes[path] = node; return node }
            if item.isRegular {
                node = StorageMapNode(directory: false, identity: identity, bytes: item.allocated, logical: item.logical,
                                      // The resource lookups leave autoreleased objects behind: without a pool they pile up for the whole map.
                                      cloud: autoreleasepool { cloudProbe(URL(fileURLWithPath: path, isDirectory: false), item.flags) }, regular: true, kind: StorageKind.kindIndex(path))
            } else if item.isDirectory && path != "/System/Volumes" {
                folders += 1
                let listing = folder >= 0 ? bulkEntries(folder) : (entries: [], complete: false)
                if folder >= 0 { close(folder); folder = -1 }
                if listing.complete {
                    let children = listing.entries.filter { !$0.hiddenByFoundation }.sorted { $0.name < $1.name }
                    node.children = children.map { join(path, $0.name) }
                    for (child, childPath) in zip(children, node.children) {
                        let result = try visit(childPath, known: child, device: item.device, depth: depth + 1)
                        node.complete = node.complete && result.complete; node.subtreeCount += result.subtreeCount
                        if limited { node.complete = false; break }
                    }
                } else { node.complete = false; node.unreadable = 1 }
            }
            nodes[path] = node; return node
        }
        lastPublished = snapshot(false); progress(lastPublished!)
        for url in initial {
            _ = try visit(url.path, known: nil, device: root.path == "/" ? nil : rootInfo.st_dev, depth: 0)
            if Date().timeIntervalSince(lastPulse) > 0.15 { lastPublished = snapshot(false); progress(lastPublished!); lastPulse = Date() }
            if limited { break }
        }
        try Task.checkCancellation()
        return snapshot(true, keepCache: true)
    }
}
