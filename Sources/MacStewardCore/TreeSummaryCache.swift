import CoreServices
import Darwin
import Foundation

/// Folder totals from earlier scans in this app session. One is reused only while FSEvents reports no change in that
/// folder, below it or in its parent, and the folder itself is still the same inode with the same times. Anything
/// FSEvents cannot vouch for (dropped or wrapped events, mounts, another volume, no history) empties the cache.
/// Cleanup never relies on it: `TreeInventory` reads every file again right before removal.
public final class TreeSummaryCache: @unchecked Sendable {
    public init() {}
    /// Entries older than this are read again even when FSEvents reports nothing.
    static let lifetime: TimeInterval = 3600
    private struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, owner: uid_t
        let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode; owner = info.st_uid
            modified = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    private struct Entry { let summary: TreeSummary; let stamp: Stamp; let dependencies: Bool; let canonical: String; let read: Date }
    private let lock = NSLock()
    private var entries = [String: Entry]()
    private var since: FSEventStreamEventId?
    private var volumes = [dev_t: String]()

    /// Runs once at the start of a scan, before any folder is read: drops every entry that may have changed since the last one.
    func prepare(watching roots: [URL]) {
        let now = FSEventsGetCurrentEventId()
        lock.lock(); let previous = since, known = entries, knownVolumes = volumes; lock.unlock()
        var kept = [String: Entry]()
        // Replaying FSEvents history costs fseventsd seconds per day of it; skip it when every entry has expired anyway.
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        if let previous, known.values.contains(where: { $0.read > cutoff }), knownVolumes.allSatisfy({ Self.volume($0.key) == $0.value }),
           let changed = Self.changes(since: previous, under: roots) {
            let keys = Set(known.values.map(\.canonical))
            var dirty = Set<String>()
            // A change anywhere inside an entry's folder: walk each changed path up through its parents.
            for path in changed {
                var current = Substring(path)
                while !current.isEmpty {
                    if keys.contains(String(current)) { dirty.insert(String(current)) }
                    guard let slash = current.lastIndex(of: "/") else { break }
                    current = current[..<slash]
                }
            }
            let events = Set(changed)
            kept = known.filter { _, entry in
                // A change in the parent folder may have replaced this one; the inode stamp would catch it, but stay conservative.
                let parent = (entry.canonical as NSString).deletingLastPathComponent
                return !dirty.contains(entry.canonical) && !events.contains(parent) && entry.read > cutoff
            }
        }
        lock.lock(); entries = kept; since = now; volumes = kept.isEmpty ? [:] : knownVolumes; lock.unlock()
    }

    /// The folder's totals, from this session's cache when allowed, otherwise read and remembered.
    func read(_ url: URL, dependencies: Bool, reusable: Bool) throws -> TreeSummary {
        guard reusable, let stamp = Stamp(url.path) else { return try TreeSummary.read(url, dependencies: dependencies) }
        lock.lock(); let cached = entries[url.path]; let watching = since != nil; lock.unlock()
        if let cached, cached.stamp == stamp, cached.dependencies == dependencies { return cached.summary }
        // Stamped before reading: a change during the read leaves a stamp that no longer matches.
        let summary = try TreeSummary.read(url, dependencies: dependencies)
        guard watching, stamp.device == Self.markerDevice, let id = Self.volume(stamp.device) else { return summary }
        let canonical = Self.realPath(url.path).lowercased()
        lock.lock()
        entries[url.path] = Entry(summary: summary, stamp: stamp, dependencies: dependencies, canonical: canonical, read: Date())
        volumes[stamp.device] = id
        lock.unlock()
        return summary
    }

    /// The path FSEvents reports: realpath keeps /private/var, which URL.resolvingSymlinksInPath would shorten to /var.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    /// FSEvents' identity for a volume's event history; nil when the volume keeps none.
    private static func volume(_ device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// A folder of this cache's own: touching a file in it, and seeing that event arrive, proves every earlier change arrived too.
    private static let marker: String? = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(StewardPreferences.domain + ".fsevents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return nil }
        return realPath(folder.path)
    }()
    /// The volume whose events arrive in order with the marker's; entries on other volumes are never kept.
    private static let markerDevice: dev_t? = marker.flatMap { path in var info = stat(); return lstat(path, &info) == 0 ? info.st_dev : nil }

    /// Lowercased folders FSEvents recorded under `roots` since `id`, or nil when the history is incomplete.
    private static func changes(since id: FSEventStreamEventId, under roots: [URL]) -> [String]? {
        guard let marker = Self.marker else { return nil }
        final class Collector {
            var paths = [String](), incomplete = false, armed = false
            let marker: String, history = DispatchSemaphore(value: 0), seen = DispatchSemaphore(value: 0)
            init(marker: String) { self.marker = marker }
        }
        let collector = Collector(marker: marker.lowercased())
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let unreliable = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for index in 0..<count {
                let flag = flags[index]
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { collector.history.signal(); continue }
                if flag & unreliable != 0 || index >= list.count { collector.incomplete = true; continue }
                var path = list[index].lowercased()
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if path == collector.marker || path.hasPrefix(collector.marker + "/") {
                    if collector.armed { collector.seen.signal() }
                    continue
                }
                collector.paths.append(path)
            }
        }
        let watched = (roots.map { realPath($0.path) } + [marker]) as CFArray
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched, id, 0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        let queue = DispatchQueue(label: StewardPreferences.domain + ".tree-summary-events")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        guard FSEventStreamStart(stream), collector.history.wait(timeout: .now() + 5) == .success else { return nil }
        // A change made just before this scan can still be on its way from the kernel after the history replay ends.
        // Events arrive in order, so once the marker written now shows up, everything before it has arrived.
        queue.sync { collector.armed = true }
        guard (try? Data(UUID().uuidString.utf8).write(to: URL(fileURLWithPath: marker).appendingPathComponent("marker"))) != nil,
              collector.seen.wait(timeout: .now() + 5) == .success else { return nil }
        return queue.sync { collector.incomplete ? nil : collector.paths }
    }
}
