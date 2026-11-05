import Foundation
import Darwin
import CoreServices

public struct LargeFileItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let localBytes: UInt64
    public let logicalBytes: UInt64
    public let modified: Date
}
public struct LargeFileReport: Sendable {
    public let files: [LargeFileItem]
    public let examined: Int
    public let unreadable: Int
    public let limited: Bool
}
public enum LargeFileAudit {
    /// Metadata only: old means modified before the threshold, never proof of disuse.
    public static func scan(root: URL, minimumBytes: UInt64 = 100_000_000, modifiedBefore: Date? = nil, maximumEntries: Int = 300_000, maximumDuration: TimeInterval = 45) throws -> LargeFileReport {
        let root = root.standardizedFileURL.resolvingSymlinksInPath(), deadline = Date().addingTimeInterval(maximumDuration)
        var files = [LargeFileItem](), examined = 0, unreadable = 0, limited = false, identities = Set<String>()
        var rootStat = stat(); guard lstat(root.path, &rootStat) == 0 else { throw StewardError.blocked("Folder is not accessible.") }
        var stack = [root]
        while let folder = stack.popLast() {
            try Task.checkCancellation()
            guard examined < maximumEntries, Date() < deadline else { limited = true; break }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
            catch { unreadable += 1; continue }
            for child in children {
                try Task.checkCancellation()
                guard examined < maximumEntries, Date() < deadline else { limited = true; break }
                examined += 1
                var value = stat(); guard lstat(child.path, &value) == 0 else { unreadable += 1; continue }
                guard value.st_dev == rootStat.st_dev else { continue }
                let kind = value.st_mode & S_IFMT
                if kind == S_IFDIR {
                    if !["Library", ".Trash", ".Trashes"].contains(child.lastPathComponent), child.pathExtension.lowercased() != "app", !child.lastPathComponent.hasPrefix("."), (try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true { stack.append(child) }
                } else if kind == S_IFREG {
                    let identity = "\(value.st_dev):\(value.st_ino)"
                    guard identities.insert(identity).inserted else { continue }
                    let size = UInt64(max(0, value.st_size)), date = Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec))
                    guard size >= minimumBytes, modifiedBefore == nil || date < modifiedBefore! else { continue }
                    files.append(LargeFileItem(url: child, localBytes: UInt64(max(0, value.st_blocks)) * 512, logicalBytes: size, modified: date))
                    if files.count > 2000 { files.sort { $0.localBytes > $1.localBytes }; files = Array(files.prefix(1000)); limited = true }
                }
            }
        }
        return LargeFileReport(files: files.sorted { $0.localBytes > $1.localBytes }, examined: examined, unreadable: unreadable, limited: limited)
    }
}
public struct InstalledApplication: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let identifier: String
    public let version: String
    /// When macOS last saw the app opened (Spotlight's kMDItemLastUsedDate); nil if never recorded.
    public let lastUsed: Date?
}
/// How long ago an app was opened, for grouping the Uninstaller. No record counts as the oldest.
public enum AppUsageAge: Int, CaseIterable, Identifiable, Sendable {
    case overYear, sixMonths, months, recent
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .overYear: return "Over a year ago"
        case .sixMonths: return "6–12 months ago"
        case .months: return "1–6 months ago"
        case .recent: return "This month"
        }
    }
    public init(lastUsed: Date?, now: Date = Date()) {
        let days = lastUsed.map { now.timeIntervalSince($0) / 86400 } ?? .infinity
        self = days > 365 ? .overYear : days > 180 ? .sixMonths : days > 30 ? .months : .recent
    }
}
public enum ApplicationInventory {
    /// Spotlight's record first; otherwise the executable's last access time, which apps launched by
    /// helpers (Creative Cloud, Setapp) still update. Either can only make an app look more used, not less.
    static func lastUsed(_ url: URL) -> Date? {
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL), let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return date }
        guard let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else { return nil }
        var info = stat()
        guard stat(url.appendingPathComponent("Contents/MacOS/" + name).path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
    }
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledApplication] {
        var apps = [InstalledApplication]()
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            var folders = [(root, 0)], examined = 0
            while let (folder, depth) = folders.popLast(), examined < 5000 {
                for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    examined += 1; if examined > 5000 { break }
                    var info = stat(); guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                    if url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) {
                        apps.append(InstalledApplication(url: url, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, identifier: bundle.bundleIdentifier ?? "Unknown identifier", version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version", lastUsed: lastUsed(url)))
                    } else if depth < 2, !url.lastPathComponent.hasPrefix(".") { folders.append((url, depth + 1)) }
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
public struct BackgroundItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let label: String
    public let program: String
    public let scope: String
    public var arguments: [String] = []
    public var schedule = "Only when needed"
    /// The program it points at is gone, usually left behind by an uninstalled app.
    public var programMissing = false
}
public enum BackgroundInventory {
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BackgroundItem] {
        [(home.appendingPathComponent("Library/LaunchAgents"), "Your account"), (URL(fileURLWithPath: "/Library/LaunchAgents"), "All users"), (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System service")].flatMap { folder, scope in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "plist" }.compactMap { url -> BackgroundItem? in
                var value = stat(); guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size < 1_048_576, let data = try? Data(contentsOf: url), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                let arguments = info["ProgramArguments"] as? [String] ?? []
                let program = info["Program"] as? String ?? arguments.first ?? "Not specified"
                return BackgroundItem(url: url, label: info["Label"] as? String ?? url.lastPathComponent, program: program, scope: scope, arguments: arguments,
                                      schedule: BackgroundItem.schedule(info, scope: scope), programMissing: program.hasPrefix("/") && !FileManager.default.fileExists(atPath: program))
            }
        }.sorted { $0.label < $1.label }
    }
}
