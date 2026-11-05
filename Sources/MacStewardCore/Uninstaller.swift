import Foundation
import Darwin

public struct UninstallItem: Identifiable, Sendable, Equatable {
    public var id: String { url.path }
    public let title: String
    public let url: URL
    public let bytes: UInt64
}
/// Removes what Artifloam itself created: fixed names only, nothing found by searching, and never the person's files.
/// Files go to the Trash so they can be put back. Settings and macOS permissions can't go there, so they are cleared.
public enum Uninstaller {
    public struct Step: Sendable {
        public let title: String
        /// Returns what could not be done, in words a person can act on.
        public let perform: @Sendable () -> [String]
    }
    public struct Actions: Sendable {
        var stopSchedule: @Sendable () throws -> Void = { try Scheduler.disable() }
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        var clearSettings: @Sendable () -> Void = { for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        var resetPermissions: @Sendable () -> Void = { for domain in domains { _ = run("/usr/bin/tccutil", ["reset", "All", domain], timeout: 10) } }
        public init() {}
    }
    static let domains = [StewardPreferences.domain, StewardPreferences.legacyDomain]

    /// This account's own files and folders at the fixed locations that exist. A symlink or another user's file is left alone.
    public static func items(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UninstallItem] {
        var places = [("Cleanup receipts and app data", "Library/Application Support/MacSteward")]
        for domain in domains {
            places += [("Cache", "Library/Caches/\(domain)"), ("Saved window state", "Library/Saved Application State/\(domain).savedState"),
                       ("Web storage", "Library/HTTPStorages/\(domain)"), ("Web data", "Library/WebKit/\(domain)")]
        }
        return places.compactMap { title, relative in
            let url = home.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT != S_IFLNK else { return nil }
            return UninstallItem(title: title, url: url, bytes: allocatedSize(url))
        }
    }
    public static func size(of url: URL) -> UInt64 { allocatedSize(url) }
    /// Only an installed copy. A copy macOS is running from a temporary location, or a build folder, stays for the person to remove.
    public static func removableApp(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let app = url.standardizedFileURL
        guard app.lastPathComponent == "Artifloam.app", app.resolvingSymlinksInPath().path == app.path,
              ["/Applications", home.standardizedFileURL.appendingPathComponent("Applications").path].contains(app.deletingLastPathComponent().path) else { return false }
        return Bundle(url: app)?.bundleIdentifier.map(domains.contains) ?? false
    }
    /// In order: nothing may run again, then data, then the app itself last, so a failure leaves a working app to retry from.
    public static func plan(items: [UninstallItem], app: URL?, actions: Actions = Actions()) -> [Step] {
        var steps = [Step(title: "Stopping the daily cleanup") {
            do { try actions.stopSchedule(); return [] } catch { return ["The daily cleanup could not be removed: " + error.localizedDescription] }
        }]
        if !items.isEmpty {
            steps.append(Step(title: "Moving app data to the Trash") {
                items.compactMap { item in
                    do { try actions.trash(item.url); return nil } catch { return item.title + " stayed in place: " + error.localizedDescription }
                }
            })
        }
        steps.append(Step(title: "Clearing settings and permissions") {
            actions.resetPermissions(); actions.clearSettings(); return []
        })
        if let app {
            steps.append(Step(title: "Moving Artifloam to the Trash") {
                do { try actions.trash(app); return [] } catch { return ["Artifloam stayed in Applications. Drag it to the Trash: " + error.localizedDescription] }
            })
        }
        return steps
    }
}
