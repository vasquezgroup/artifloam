import Foundation
import Darwin
import AppKit

// MARK: Trash bins

public struct TrashItem: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let isFolder: Bool
    /// nil: a folder, whose size Finder doesn't share.
    public let bytes: UInt64?
    public let modified: Date?
    public var kind: String { isFolder ? "Folders" : StorageKind.classify(name) }
}
public struct TrashBinsReport: Sendable {
    /// nil when the size isn't fully known: macOS keeps folders in the Trash private without Full Disk Access.
    public let bytes: UInt64?
    public let items: Int?
    public let volumes: [String]
    /// Names stay on this Mac. Empty when nothing could be listed.
    public var contents: [TrashItem] = []
    public static let emptied = TrashBinsReport(bytes: 0, items: 0, volumes: [])
    public var measuredBytes: UInt64 { contents.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public var unmeasured: Int { contents.filter { $0.bytes == nil }.count }
    public var kinds: [(name: String, bytes: UInt64, count: Int)] {
        Dictionary(grouping: contents, by: \.kind).map { ($0.key, $0.value.reduce(0) { $0 + ($1.bytes ?? 0) }, $0.value.count) }.sorted { ($0.1, $0.0) > ($1.1, $1.0) }
    }
    public func largest(_ limit: Int = 8) -> [TrashItem] {
        Array(contents.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(limit))
    }
    public var oldest: Date? { contents.compactMap(\.modified).min() }
    public func unchanged(sinceDays days: Int, now: Date = Date()) -> [TrashItem] {
        contents.filter { $0.modified.map { now.timeIntervalSince($0) > Double(days) * 86400 } ?? false }
    }
}
public enum TrashBins {
    /// Finder empties all mounted Trashes. Refuse a redirected container before asking it to do so.
    static func validateRoots(home: URL, volumes: [URL]) throws {
        let folders = [home.appendingPathComponent(".Trash")] + volumes.flatMap { volume in
            [volume.appendingPathComponent(".Trashes"), volume.appendingPathComponent(".Trashes/\(getuid())")]
        }
        for folder in folders {
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw StewardError.blocked("Cannot verify a Trash folder. Empty it yourself in Finder.")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw StewardError.blocked("A Trash folder is redirected or is not a directory. Review it in Finder.") }
        }
    }
    /// Bulk reads of files take Finder a fraction of a second; asking for all items at once can take a minute, so folders are listed by name.
    static let finderListing = #"const t=Application('Finder').trash;const n=t.files.name(),s=t.files.physicalSize(),d=t.files.modificationDate();JSON.stringify({files:n.map((x,i)=>[x,s[i],d[i]]),folders:t.folders.name(),folderDates:t.folders.modificationDate()})"#
    static func parseFinder(_ json: String) -> [TrashItem]? {
        guard let data = json.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let files = root["files"] as? [[Any]], let folders = root["folders"] as? [String] else { return nil }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = root["folderDates"] as? [Any] ?? []
        func date(_ value: Any?) -> Date? { (value as? String).flatMap(format.date(from:)) }
        var items = files.compactMap { row -> TrashItem? in
            guard row.count == 3, let name = row[0] as? String else { return nil }
            return TrashItem(name: name.displaySafe, isFolder: false, bytes: (row[1] as? NSNumber).map { UInt64(max(0, $0.int64Value)) }, modified: date(row[2]))
        }
        for (index, name) in folders.enumerated() { items.append(TrashItem(name: name.displaySafe, isFolder: true, bytes: nil, modified: index < dates.count ? date(dates[index]) : nil)) }
        return items
    }
    /// `askFinder` may show a macOS Automation prompt, so only pass it for an explicit user check.
    public static func inspect(home: URL = FileManager.default.homeDirectoryForCurrentUser, askFinder: Bool = false) -> TrashBinsReport {
        let uid = getuid()
        var folders = [home.appendingPathComponent(".Trash")]
        for volume in children(URL(fileURLWithPath: "/Volumes")) { folders.append(volume.appendingPathComponent(".Trashes/\(uid)")) }
        var bytes: UInt64 = 0, items = 0, readable = false, volumes = [String](), contents = [TrashItem]()
        for folder in folders {
            // A symlink planted as a volume's Trash folder must not count someone else's files as Trash.
            var info = stat(); guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            readable = true; items += entries.count
            if folder.path.hasPrefix("/Volumes/"), !entries.isEmpty { volumes.append(folder.pathComponents[2]) }
            for entry in entries {
                let size = allocatedSize(entry); bytes += size
                let name = entry.lastPathComponent
                if name == ".DS_Store" { items -= 1; continue }
                var kind = stat(); let folder = lstat(entry.path, &kind) == 0 && kind.st_mode & S_IFMT == S_IFDIR
                contents.append(TrashItem(name: name.displaySafe, isFolder: folder, bytes: size, modified: Date(timeIntervalSince1970: TimeInterval(kind.st_mtimespec.tv_sec))))
            }
        }
        if readable { return TrashBinsReport(bytes: bytes, items: items, volumes: volumes, contents: contents) }
        // Finder can read the Trash even when the folder itself is private.
        guard askFinder, let listed = parseFinder(run("/usr/bin/osascript", ["-l", "JavaScript", "-e", finderListing], timeout: 20).output) else { return TrashBinsReport(bytes: nil, items: nil, volumes: []) }
        // Finder answers null for a folder's size, so folders stay unmeasured without Full Disk Access and the page says "at least".
        let report = TrashBinsReport(bytes: nil, items: listed.count, volumes: [], contents: listed)
        return report.unmeasured == 0 ? TrashBinsReport(bytes: report.measuredBytes, items: listed.count, volumes: [], contents: listed) : report
    }
    /// Shows macOS's own permission question for controlling Finder, and nothing else. True once it's allowed.
    public static func requestFinderAccess() -> Bool {
        run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to get name of startup disk"], timeout: 120).code == 0
    }
    /// Finder empties every volume's Trash and handles locked items the way the user expects. Permanent.
    public static func empty() throws {
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) else { throw StewardError.blocked("Cannot verify mounted Trash folders. Empty the Trash yourself in Finder.") }
        try validateRoots(home: FileManager.default.homeDirectoryForCurrentUser,
                          volumes: volumes)
        let result = run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 600)
        guard result.code == 0 else { throw StewardError.blocked("Finder could not empty the Trash: " + result.error.trimmingCharacters(in: .whitespacesAndNewlines) + ". Allow Artifloam to control Finder in System Settings → Privacy & Security → Automation.") }
    }
}
func allocatedSize(_ url: URL) -> UInt64 {
    var value = stat(); guard lstat(url.path, &value) == 0 else { return 0 }
    if value.st_mode & S_IFMT != S_IFDIR { return UInt64(max(0, value.st_blocks)) * 512 }
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    return fd >= 0 ? directoryBytes(fd: fd) : 0
}

// MARK: App leftovers

public struct LeftoverItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bundleID: String
    public let kind: String
    public let bytes: UInt64
    public let modified: Date
    /// Another app from the same vendor is installed, so this may be shared data. Never preselected.
    public let vendorInstalled: Bool
}
/// One app's leftovers, the way a person thinks of them: "Adobe", not twelve bundle identifiers.
public struct LeftoverApp: Identifiable, Sendable {
    public var id: String { (shared ? "shared:" : "") + key }
    let key: String
    public let name: String
    public let items: [LeftoverItem]
    /// Its maker has another app on this Mac, so these may still be in use.
    public let shared: Bool
    public var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    public var newest: Date? { items.map(\.modified).max() }
    public var kinds: [String] { Array(Set(items.map(\.kind))).sorted() }
}
public enum AppLeftovers {
    /// Grouped by maker. With a single identifier the name comes from it (com.hnc.Discord is Discord); the identifiers stay visible beside it.
    public static func grouped(_ items: [LeftoverItem]) -> [LeftoverApp] {
        func parts(_ item: LeftoverItem) -> [String] { item.bundleID.split(separator: ".").map(String.init) }
        func title(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
        let groups = Dictionary(grouping: items) { item -> String in let found = parts(item); return (found.count > 1 ? found[0] + "." + found[1] : item.bundleID).lowercased() + (item.vendorInstalled ? "|shared" : "") }
        return groups.map { key, list in
            let found = parts(list[0]), maker = found.count > 1 ? found[1] : found.first ?? list[0].bundleID, single = Set(list.map(\.bundleID)).count == 1
            let name = title(single && found.count == 3 ? found[2] : maker)
            return LeftoverApp(key: key, name: name.displaySafe, items: list.sorted { $0.bytes > $1.bytes }, shared: list[0].vendorInstalled)
        }.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }
    /// Library folders whose entries are named after an app's bundle identifier.
    static let locations: [(String, String)] = [
        ("Library/Application Support", "Support files"), ("Library/Caches", "Cache"), ("Library/Preferences", "Preferences"),
        ("Library/Saved Application State", "Saved window state"), ("Library/HTTPStorages", "Web storage"), ("Library/WebKit", "Web data"), ("Library/Logs", "Logs")
    ]
    /// Libraries bundled into many apps name their files after themselves, not the app, so they never look orphaned.
    static let sharedLibraries = ["org.cups.", "org.sparkle-project.", "com.segment.", "com.firebase.", "com.google.firebase", "com.crashlytics", "io.sentry", "com.bugsnag.", "com.breakpad.", "com.telemetrydeck.", "com.microsoft.appcenter", "com.amplitude.", "com.mixpanel", "io.realm.", "com.squirrel.", "com.github.electron", "org.chromium."]
    /// Only reverse-DNS names (com.vendor.app) are considered, so folders named by people are never matched.
    static func bundleID(_ name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
        let parts = id.split(separator: ".")
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              ["com", "org", "net", "io", "de", "ch", "co", "app", "dev", "me", "us", "uk", "fr", "jp"].contains(parts[0].lowercased()) else { return nil }
        return id
    }
    /// `installed` and `referenced` are lower-cased identifiers; a leftover must match neither, nor be a prefix/child of one.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, installed: Set<String>, referenced: Set<String> = [], olderThan days: Int = 30, now: Date = Date(), activity: ActivitySnapshot = ActivitySnapshot(), registered: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> [LeftoverItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        func related(_ id: String) -> Bool {
            let id = id.lowercased()
            if id.hasPrefix("com.apple.") || sharedLibraries.contains(where: { id.hasPrefix($0) }) { return true }
            // Helpers like com.vendor.app.helper belong to com.vendor.app, and vice versa.
            return (installed.union(referenced)).contains { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
        }
        var items = [LeftoverItem]()
        for (relative, kind) in locations {
            for url in children(home.appendingPathComponent(relative)) {
                // Launch Services also knows apps installed outside the Applications folders.
                guard let id = bundleID(url.lastPathComponent), !related(id), !registered(id) else { continue }
                var value = stat(); guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else { continue }
                // The newest file anywhere inside: a folder's own date changes only with its direct children.
                guard !activity.isActive(url), let modified = (try? TreeSummary.read(url, dependencies: true))?.newest, modified < cutoff else { continue }
                let vendor = id.lowercased().split(separator: ".").prefix(2).joined(separator: ".") + "."
                items.append(LeftoverItem(url: url, bundleID: id, kind: kind, bytes: allocatedSize(url), modified: modified, vendorInstalled: installed.contains { $0.hasPrefix(vendor) }))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
    /// Identifiers of installed apps (including helpers inside them) and of launch agents/daemons.
    public static func knownIdentifiers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (installed: Set<String>, referenced: Set<String>) {
        var installed = Set<String>()
        for root in ["/Applications", "/System/Applications", "/System/Applications/Utilities", home.appendingPathComponent("Applications").path, "/Library/Application Support"] {
            // Bundle level only: helpers usually share their app's prefix, and the vendor check covers the rest.
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if ["app", "appex", "xpc", "prefPane", "plugin"].contains(url.pathExtension), let id = Bundle(url: url)?.bundleIdentifier { installed.insert(id.lowercased()) }
                if walker.level >= 3 { walker.skipDescendants() }
            }
        }
        let referenced = Set(BackgroundInventory.scan(home: home).flatMap { [$0.label.lowercased(), $0.url.deletingPathExtension().lastPathComponent.lowercased()] })
        return (installed, referenced)
    }
}

// MARK: Login items and launch agents

public enum LoginItems {
    /// Apps opened at login (System Settings › Login Items › Open at Login), read via System Events.
    public static func list() throws -> [String] {
        let result = run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set names to name of every login item\nset AppleScript's text item delimiters to linefeed\nreturn names as text"], timeout: 20)
        guard result.code == 0 else { throw StewardError.blocked("System Events did not answer. Allow Artifloam to control System Events in System Settings → Privacy & Security → Automation.") }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // One per line: a name may itself contain a comma.
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
    /// "--" ends osascript's options. Without it, a name starting with "-e" is compiled as more script and can run commands.
    static func scriptArguments(_ script: String, argument: String) -> [String] { ["-e", script, "--", argument] }
    /// A real app bundle, and not a link to something else: this is what starts every time the person signs in.
    static func isApp(_ url: URL) -> Bool {
        var info = stat()
        return url.pathExtension.lowercased() == "app" && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }
    static let addScript = "on run argv\ntell application \"System Events\" to make new login item at end of login items with properties {path:(item 1 of argv), hidden:false}\nend run"
    /// Runs on a person's choice in the open panel. The path travels as an argument, never as script text.
    public static func add(_ app: URL) throws {
        let name = app.deletingPathExtension().lastPathComponent
        guard isApp(app) else { throw StewardError.blocked("\(name.displaySafe) isn't an app, so it wasn't added.") }
        guard try !list().contains(name) else { return }
        let result = run("/usr/bin/osascript", scriptArguments(addScript, argument: app.path), timeout: 20)
        guard result.code == 0 else { throw StewardError.blocked("Could not add \(name.displaySafe): " + result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    public static func remove(_ name: String) throws {
        let script = "on run argv\ntell application \"System Events\" to delete login item (item 1 of argv)\nend run"
        let result = run("/usr/bin/osascript", scriptArguments(script, argument: name), timeout: 20)
        guard result.code == 0 else { throw StewardError.blocked("Could not remove \(name): " + result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
public enum LaunchAgentControl {
    static var domain: String { "gui/\(getuid())" }
    /// Labels launchd keeps switched off for this account.
    public static func disabledLabels() -> Set<String> {
        let output = run("/bin/launchctl", ["print-disabled", domain]).output
        return Set(output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\"")
            return parts.count >= 3 && line.contains("=> disabled") ? String(parts[1]) : nil
        })
    }
    /// Reversible: launchd stops loading it at login until enabled again. No file is changed.
    public static func setEnabled(_ enabled: Bool, item: BackgroundItem) throws {
        guard item.scope == "Your account" else { throw StewardError.blocked("Only your own launch agents can be switched here. Use System Settings for items shared by all users.") }
        let result = run("/bin/launchctl", [enabled ? "enable" : "disable", "\(domain)/\(item.label)"])
        guard result.code == 0 else { throw StewardError.blocked("launchd refused: " + result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Stop it now too; a disabled agent would otherwise keep running until logout.
        if !enabled { _ = run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"]) }
    }
}
