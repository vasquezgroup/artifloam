import Foundation

/// Storage visibility is separate from cleanup eligibility. These entries never enter automatic
/// cleanup. Folders in ~/Library/Developer/Xcode can be ticked by the person, flagged when risky or
/// recently used, and go to the Trash. Simulator runtimes stay with Xcode.
public enum XcodeStorageInventory {
    /// Ticked by the person and moved to the Trash; see `trash`.
    public static let trashRule = "xcode-reviewed-trash"
    /// Ticked by the person one at a time and deleted by `simctl`; never part of automatic cleanup.
    public static let simulatorRule = "unused-simulator"
    static let simulatorIdleDays = 90
    struct UnusedSimulator: Equatable { let udid: String; let name: String; let bytes: UInt64; let available: Bool; let lastUsed: Date? }
    /// Shut-down simulators holding real data that Xcode can no longer run, or that nothing has used for 90 days.
    /// A simulator with no recorded use counts as used, so a missing date never makes it removable.
    static func unusedSimulators(listJSON data: Data, now: Date = Date()) -> [UnusedSimulator] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let groups = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return groups.flatMap { runtime, devices in
            devices.compactMap { device -> UnusedSimulator? in
                guard let udid = device["udid"] as? String, UUID(uuidString: udid) != nil, device["state"] as? String == "Shutdown" else { return nil }
                let bytes = (device["dataPathSize"] as? NSNumber)?.uint64Value ?? 0, available = device["isAvailable"] as? Bool ?? true
                let used = (device["lastUsedAt"] as? String).flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                let idle = used.map { now.timeIntervalSince($0) >= Double(simulatorIdleDays) * 86_400 } ?? false
                guard bytes >= 100_000_000, !available || idle else { return nil }
                let os = runtime.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "iOS.", with: "iOS ") ?? ""
                return UnusedSimulator(udid: udid, name: [device["name"] as? String ?? "Simulator", os].filter { !$0.isEmpty }.joined(separator: " · "), bytes: bytes, available: available, lastUsed: used)
            }
        }
    }
    /// A simulator's caches are also listed on their own, for automatic cleanup. Its row counts only the rest, so totals add up.
    static func countingNestedCachesOnce(_ findings: [Finding]) -> [Finding] {
        let caches = findings.filter { $0.rule == "simulator-cache" }
        return findings.map { finding in
            guard finding.rule == simulatorRule else { return finding }
            var counted = finding
            let nested = caches.filter { $0.path.hasPrefix(finding.path + "/") }.reduce(0) { $0 + $1.bytes }
            counted.bytes = finding.bytes > nested ? finding.bytes - nested : 0
            return counted
        }
    }
    private static func listSimulators() -> [UnusedSimulator]? {
        let result = run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 12)
        return result.code == 0 ? unusedSimulators(listJSON: Data(result.output.utf8)) : nil
    }
    /// Rechecks right before deleting: still a known, shut-down, unused simulator, and no simulator is running.
    static func removeSimulator(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot) throws {
        let udid = URL(fileURLWithPath: finding.path).lastPathComponent
        let base = configuration.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)").path
        guard finding.rule == simulatorRule, finding.path == base else { throw StewardError.blocked("Not a simulator Artifloam can remove.") }
        guard !configuration.ignoredPaths.contains(where: { base == $0 || base.hasPrefix($0 + "/") }) else { throw StewardError.blocked("Path is on the ignore list") }
        guard activity.reliable, !BroadCaches.simulatorRunning(activity) else { throw StewardError.blocked("A simulator is running") }
        guard listSimulators()?.contains(where: { $0.udid == udid }) == true else { throw StewardError.blocked("This simulator was used or changed; scan again") }
        let result = run("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: 120)
        guard result.code == 0 else { throw StewardError.blocked("simctl could not delete it: " + result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
            let warnings = ([flag] + [rule == trashRule && Date().timeIntervalSince(modified) < 30 * 86_400 ? "Used in the last 30 days." : nil]).compactMap { $0 }
            rows.append(Finding(path: url.path, group: .xcode, bytes: bytes, modifiedAt: modified, safety: safety, reason: reason, rule: rule, fingerprint: "review-only", warnings: warnings.isEmpty ? nil : warnings))
        }
        for url in children(home.appendingPathComponent("Library/Developer/Xcode/Archives")) {
            add(url, reason: "Release archives from Xcode Organizer. Moves to the Trash.", flag: "May hold the only signed build and debug symbols of a release.")
        }
        for url in children(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")) {
            add(url, reason: "Device support for one iOS version. Xcode rebuilds it the next time you connect a device with it.")
        }
        for project in children(home.appendingPathComponent("Library/Developer/Xcode/DerivedData")) where project.lastPathComponent != "ModuleCache.noindex" {
            add(project.appendingPathComponent("Build/Products"), reason: "Built apps and frameworks. Xcode builds them again.", flag: "May include signed builds you still need.")
            add(project.appendingPathComponent("SourcePackages"), reason: "Downloaded Swift packages. Xcode fetches them again when you open the project.")
        }
        let hasXcodeStorage = [home.appendingPathComponent("Library/Developer/CoreSimulator").path, "/Library/Developer/CoreSimulator", "/Applications/Xcode.app"].contains { FileManager.default.fileExists(atPath: $0) }
        if hasXcodeStorage, home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, DeveloperTools.gitExecutable != nil {
            let result = run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"], timeout: 12)
            if let data = result.output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for runtime in object["runtimes"] as? [[String: Any]] ?? [] {
                    guard let path = runtime["bundlePath"] as? String, path.hasPrefix("/"), path.hasSuffix(".simruntime"),
                          path.hasPrefix("/Library/Developer/CoreSimulator/") || path.hasPrefix("/private/var/run/com.apple.security.cryptexd/mnt/") else { continue }
                    add(URL(fileURLWithPath: path), reason: "Simulator OS runtime. Manage removal in Xcode > Settings > Components (Platforms on older Xcode). Simulators Xcode can still run, and their data, are not cleaned automatically.", immutable: true, rule: "xcode-managed-review")
                }
            }
            if result.code != 0 || !result.error.isEmpty {
                notices.append("Xcode could not provide a complete simulator-runtime inventory. Review installed runtimes in Xcode Settings > Components.")
            }
            let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            for simulator in listSimulators() ?? [] {
                let path = devices.appendingPathComponent(simulator.udid).path
                guard !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                let why = simulator.available ? "Not used since \(simulator.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "it was set up")." : "Xcode can no longer run it."
                rows.append(Finding(path: path, group: .xcode, bytes: simulator.bytes, modifiedAt: simulator.lastUsed ?? Date(), safety: .review, reason: why + " Removed by Xcode's own simctl.", rule: simulatorRule, fingerprint: "review-only", warnings: ["Deletes the apps and data inside this simulator for good."], label: simulator.name))
            }
        }
        return (rows, notices)
    }
    /// Only the folders `inspect` lists: one level inside Archives or iOS DeviceSupport, or a project's Build/Products or SourcePackages.
    static func trashable(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL
        guard path.resolvingSymlinksInPath().path == path.path else { return false }
        let xcode = home.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Library/Developer/Xcode").path
        let parent = path.deletingLastPathComponent()
        if [xcode + "/Archives", xcode + "/iOS DeviceSupport"].contains(parent.path) { return true }
        if path.lastPathComponent == "SourcePackages" { return parent.deletingLastPathComponent().path == xcode + "/DerivedData" }
        if path.lastPathComponent == "Products", parent.lastPathComponent == "Build" { return parent.deletingLastPathComponent().deletingLastPathComponent().path == xcode + "/DerivedData" }
        return false
    }
    /// Rechecks a ticked folder right before moving it to the Trash, where the person can restore it.
    static func trash(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot) throws {
        let url = URL(fileURLWithPath: finding.path)
        guard finding.rule == trashRule, trashable(url, home: configuration.home) else { throw StewardError.blocked("Not an Xcode folder Artifloam moves. Use Finder.") }
        guard !configuration.ignoredPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { throw StewardError.blocked("Path is on the ignore list") }
        guard activity.reliable else { throw StewardError.blocked("Cannot verify running processes and open files") }
        guard !activity.isActive(url) else { throw StewardError.blocked("A running process uses this folder") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw StewardError.blocked("Folder changed or belongs to another user; scan again") }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
