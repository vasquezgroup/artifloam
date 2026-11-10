import Foundation

/// Storage visibility is separate from cleanup eligibility. These entries never enter automatic
/// cleanup. Folders in ~/Library/Developer/Xcode can be ticked by the person, flagged when risky or
/// recently used, and go to the Trash. Simulator runtimes stay with Xcode.
public enum XcodeStorageInventory {
    /// Ticked by the person and deleted for good; see `trash`.
    public static let trashRule = "xcode-reviewed-trash"
    /// Ticked by the person one at a time and deleted by `simctl`; never part of automatic cleanup.
    public static let simulatorRule = "unused-simulator"
    /// Shut-down simulators worth asking about: anything holding at least 100 MB. Running ones are never listed.
    public static func deletableSimulators(_ all: [SimulatorDevice]) -> [SimulatorDevice] { all.filter { !$0.running && $0.bytes >= 100_000_000 } }
    /// Plain words for someone who doesn't know simulators: why it's listed and whether deleting it is a sure thing.
    static func simulatorReason(_ simulator: SimulatorDevice, now: Date = Date()) -> String {
        if !simulator.available { return String(localized: "Made for an iOS version this Xcode no longer has, so it can't start anymore. Safe to delete.") }
        guard let used = simulator.lastUsed else { return String(localized: "No record of when it was last used. Delete it only if you're done testing on it.") }
        let days = Int(now.timeIntervalSince(used) / 86_400)
        if days >= SimulatorDevice.idleDays { return String(localized: "Not used for \(days) days. Safe to delete.") }
        return String(localized: "Used \(used.formatted(.relative(presentation: .named))). Delete it only if you're done testing on it.")
    }
    /// Caches inside a simulator or an orphaned DerivedData folder are also listed on their own, for automatic cleanup. The outer row counts only the rest, so totals add up.
    static func countingNestedCachesOnce(_ findings: [Finding]) -> [Finding] {
        let caches = findings.filter { ["simulator-cache", "xcode-intermediates"].contains($0.rule) }
        return findings.map { finding in
            guard [simulatorRule, trashRule].contains(finding.rule) else { return finding }
            var counted = finding
            let nested = caches.filter { $0.path.hasPrefix(finding.path + "/") }.reduce(0) { $0 + $1.bytes }
            counted.bytes = finding.bytes > nested ? finding.bytes - nested : 0
            return counted
        }
    }
    /// Rechecks right before deleting: still there, shut down, and not used since the person saw it. Other simulators may keep running.
    static func removeSimulator(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot) throws {
        let udid = URL(fileURLWithPath: finding.path).lastPathComponent
        let base = configuration.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)").path
        guard finding.rule == simulatorRule, finding.path == base else { throw StewardError.blocked(String(localized: "Not a simulator Artifloam can remove.")) }
        guard !configuration.ignoredPaths.contains(where: { base == $0 || base.hasPrefix($0 + "/") }) else { throw StewardError.blocked(String(localized: "Path is on the ignore list")) }
        guard let now = Simulators.list()?.first(where: { $0.id == udid }) else { throw StewardError.blocked(String(localized: "This simulator was used or changed; scan again")) }
        guard !now.running else { throw StewardError.blocked(String(localized: "This simulator is running. Shut it down first.")) }
        guard (now.lastUsed ?? .distantPast) <= finding.modifiedAt.addingTimeInterval(60) else { throw StewardError.blocked(String(localized: "This simulator was used or changed; scan again")) }
        let result = run("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: 120)
        guard result.code == 0 else { throw StewardError.blocked(String(localized: "simctl could not delete it: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")) }
    }
    static func inspect(home: URL, ignoredPaths: [String] = []) -> (findings: [Finding], notices: [String]) {
        var rows: [Finding] = [], notices: [String] = []
        let excluded = ignoredPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        func add(_ url: URL, safety: Safety = .review, reason: String, immutable: Bool = false, rule: String = trashRule, flag: String? = nil) {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !Task.isCancelled,
                  !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  value.isDirectory == true, value.isSymbolicLink != true else { return }
            let bytes = immutable ? runtimeBytes(url, modified: value.contentModificationDate) : directoryBytes(url)
            guard bytes >= 1_000_000 else { return }
            let modified = value.contentModificationDate ?? Date()
            // "in use" = modified in the last 30 days; Xcode records no last-used date for these folders.
            let warnings = ([flag] + [rule == trashRule && Date().timeIntervalSince(modified) < 30 * 86_400 ? String(localized: "Used in the last 30 days.") : nil]).compactMap { $0 }
            rows.append(Finding(path: url.path, group: .xcode, bytes: bytes, modifiedAt: modified, safety: safety, reason: reason, rule: rule, fingerprint: "review-only", warnings: warnings.isEmpty ? nil : warnings))
        }
        for url in children(home.appendingPathComponent("Library/Developer/Xcode/Archives")) {
            add(url, reason: String(localized: "Release archives from Xcode Organizer. Deleted permanently."), flag: String(localized: "May hold the only signed build and debug symbols of a release."))
        }
        for platform in deviceSupportPlatforms {
            for url in children(home.appendingPathComponent("Library/Developer/Xcode/\(platform) DeviceSupport")) {
                add(url, reason: String(localized: "Device support for one \(platform) version. Xcode rebuilds it the next time you connect a device with it."))
            }
        }
        for project in children(home.appendingPathComponent("Library/Developer/Xcode/DerivedData")) where project.lastPathComponent != "ModuleCache.noindex" {
            // A project that is gone needs none of its build data: one row for the whole folder.
            if orphaned(project) { add(project, reason: String(localized: "Build data for a project Xcode can no longer find. Xcode rebuilds it if the project comes back.")); continue }
            add(project.appendingPathComponent("Build/Products"), reason: String(localized: "Built apps and frameworks. Xcode builds them again."), flag: String(localized: "May include signed builds you still need."))
            add(project.appendingPathComponent("SourcePackages"), reason: String(localized: "Downloaded Swift packages. Xcode fetches them again when you open the project."))
            add(project.appendingPathComponent("Index.noindex"), reason: String(localized: "Xcode's search index for one project. Xcode rebuilds it when you open the project again."))
        }
        let hasXcodeStorage = [home.appendingPathComponent("Library/Developer/CoreSimulator").path, "/Library/Developer/CoreSimulator", "/Applications/Xcode.app"].contains { FileManager.default.fileExists(atPath: $0) }
        if hasXcodeStorage, home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, DeveloperTools.gitExecutable != nil {
            let result = run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"], timeout: 12)
            if let data = result.output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for runtime in object["runtimes"] as? [[String: Any]] ?? [] {
                    guard let path = runtime["bundlePath"] as? String, path.hasPrefix("/"), path.hasSuffix(".simruntime"),
                          path.hasPrefix("/Library/Developer/CoreSimulator/") || path.hasPrefix("/private/var/run/com.apple.security.cryptexd/mnt/") else { continue }
                    add(URL(fileURLWithPath: path), reason: String(localized: "Simulator OS runtime. Manage removal in Xcode > Settings > Components (Platforms on older Xcode). Simulators Xcode can still run, and their data, are not cleaned automatically."), immutable: true, rule: "xcode-managed-review")
                }
            }
            if result.code != 0 || !result.error.isEmpty {
                notices.append(String(localized: "Xcode could not provide a complete simulator-runtime inventory. Review installed runtimes in Xcode Settings > Components."))
            }
            let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            for simulator in deletableSimulators(Simulators.list() ?? []) {
                let path = devices.appendingPathComponent(simulator.id).path
                guard !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                rows.append(Finding(path: path, group: .xcode, bytes: simulator.bytes, modifiedAt: simulator.lastUsed ?? Date(), safety: .review, reason: simulatorReason(simulator), rule: simulatorRule, fingerprint: "review-only",
                                    warnings: [String(localized: "Deletes the test apps and their data inside it, never your projects. Xcode makes a new simulator in a minute.")], label: simulator.name, finished: simulator.safeToDelete()))
            }
        }
        return (rows, notices)
    }
    static let deviceSupportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]
    /// A DerivedData folder whose project file is gone. Without a readable WorkspacePath it is never called orphaned.
    static func orphaned(_ project: URL) -> Bool {
        guard let data = BoundedFile.read(project.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = plist["WorkspacePath"] as? String, workspace.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: workspace)
    }
    /// Only the folders `inspect` lists: one level inside Archives or a DeviceSupport folder, a project's Build/Products,
    /// SourcePackages or Index.noindex, or a whole DerivedData folder whose project is gone (checked again here).
    static func trashable(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL
        guard path.resolvingSymlinksInPath().path == path.path else { return false }
        let xcode = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Library/Developer/Xcode").path
        let parent = path.deletingLastPathComponent()
        if ([xcode + "/Archives"] + deviceSupportPlatforms.map { xcode + "/\($0) DeviceSupport" }).contains(parent.path) { return true }
        if parent.path == xcode + "/DerivedData" { return path.lastPathComponent != "ModuleCache.noindex" && orphaned(path) }
        if ["SourcePackages", "Index.noindex"].contains(path.lastPathComponent) { return parent.deletingLastPathComponent().path == xcode + "/DerivedData" }
        if path.lastPathComponent == "Products", parent.lastPathComponent == "Build" { return parent.deletingLastPathComponent().deletingLastPathComponent().path == xcode + "/DerivedData" }
        return false
    }
    /// Rechecks a ticked folder right before deleting it for good.
    static func trash(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot) throws {
        let url = URL(fileURLWithPath: finding.path)
        guard finding.rule == trashRule, trashable(url, home: configuration.home) else { throw StewardError.blocked(String(localized: "Not an Xcode folder Artifloam deletes. Use Finder.")) }
        guard !configuration.ignoredPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { throw StewardError.blocked(String(localized: "Path is on the ignore list")) }
        guard activity.reliable else { throw StewardError.blocked(String(localized: "Cannot verify running processes and open files")) }
        guard !activity.isActive(url) else { throw StewardError.blocked(String(localized: "A running process uses this folder")) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw StewardError.blocked(String(localized: "Folder changed or belongs to another user; scan again")) }
        try FileManager.default.removeItem(at: url)
    }
    /// Installed runtimes are read-only and never change, but measuring one takes seconds (about 6 s for watchOS),
    /// so each is measured once per path and modification date. v2: sizes from before the symlink fix in directoryBytes were too small.
    static func runtimeBytes(_ url: URL, modified: Date?, defaults: UserDefaults = StewardPreferences.defaults) -> UInt64 {
        let key = url.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        var known = defaults.dictionary(forKey: "runtimeSizes-v2") as? [String: UInt64] ?? [:]
        if let bytes = known[key] { return bytes }
        let bytes = directoryBytes(url)
        guard !Task.isCancelled else { return bytes }
        known = known.filter { FileManager.default.fileExists(atPath: String($0.key.split(separator: "|")[0])) }
        known[key] = bytes; defaults.set(known, forKey: "runtimeSizes-v2"); defaults.removeObject(forKey: "runtimeSizes")
        return bytes
    }
}
