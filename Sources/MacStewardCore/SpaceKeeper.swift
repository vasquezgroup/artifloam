import Foundation

/// "Keep space free": a weekly cleanup that also runs right away when space gets low.
/// Nobody is watching, so it takes only exact, known locations that rebuild. Everything else waits for a person in Cleanup.
public enum SpaceKeeper {
    public enum Reason: String, Sendable { case lowSpace, weekly }
    /// Below this share of free space, a run starts right away.
    public static let lowSpaceShare = 0.15
    public static func isLow(free: UInt64, total: UInt64) -> Bool { total > 0 && Double(free) / Double(total) < lowSpaceShare }
    static let cooldown: TimeInterval = 6 * 3600
    static let week: TimeInterval = 7 * 86_400

    /// Whether to run now. Low space wins, but never more often than every 6 hours, so a nearly full disk doesn't loop.
    public static func reason(free: UInt64, total: UInt64, lastRun: Date?, now: Date = Date()) -> Reason? {
        let since = lastRun.map { now.timeIntervalSince($0) } ?? .infinity
        guard since >= cooldown else { return nil }
        if isLow(free: free, total: total) { return .lowSpace }
        return since >= week ? .weekly : nil
    }

    /// Rules with exact paths and contents their producer rebuilds. New rules stay out until added here on purpose.
    static let unattendedRules: Set<String> = ["simulator-cache", "application-web-cache", "old-user-log", "xcode-intermediates", "agent-xcode-intermediates",
                                               "nx-task-cache", "framework-cache", "python-bytecode", "project-test-cache"]
    /// Ready items on the list above, plus the few app and tool caches known to rebuild.
    public static func selection(_ report: ScanReport) -> Set<String> {
        Set(report.findings.filter { finding in
            finding.safety == .automatic && (unattendedRules.contains(finding.rule) || BroadCaches.knownRebuildable(rule: finding.rule, name: finding.title))
        }.map(\.id))
    }

    /// Simulators whose runtime is no longer installed: Xcode can't boot them. Apple's `simctl` removes them.
    public struct Simulators: Sendable { public let count: Int; public let bytes: UInt64 }
    public static func unavailableSimulators(home: URL = FileManager.default.homeDirectoryForCurrentUser, ignoredPaths: [String] = []) -> Simulators? {
        guard let ids = unavailableIDs(home: home, ignoredPaths: ignoredPaths) else { return nil }
        return Simulators(count: ids.count, bytes: ids.reduce(UInt64(0)) { $0 + simulatorBytes($1, home: home) })
    }
    private static func simulatorBytes(_ id: String, home: URL) -> UInt64 {
        (try? TreeSummary.read(home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(id)"), dependencies: false).bytes) ?? 0
    }
    private static func unavailableIDs(home: URL, ignoredPaths: [String]) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
        let result = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        return removable(devices.values.flatMap { $0 }.compactMap { $0["udid"] as? String }, home: home, ignoredPaths: ignoredPaths)
    }
    /// Real simulator IDs that the person hasn't put on the keep list.
    static func removable(_ ids: [String], home: URL, ignoredPaths: [String]) -> [String] {
        let base = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices").path
        return ids.filter { id in
            let path = base + "/" + id
            return UUID(uuidString: id) != nil && !ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
    /// Removes unavailable simulators one by one with `simctl`, so the keep list holds, and never while a simulator runs.
    public static func removeUnavailableSimulators(activity: ActivitySnapshot = .capture(), home: URL = FileManager.default.homeDirectoryForCurrentUser, ignoredPaths: [String] = []) -> Simulators? {
        guard activity.reliable, !BroadCaches.simulatorRunning(activity), let ids = unavailableIDs(home: home, ignoredPaths: ignoredPaths) else { return nil }
        var count = 0, bytes: UInt64 = 0
        for id in ids {
            let size = simulatorBytes(id, home: home)
            if run("/usr/bin/xcrun", ["simctl", "delete", id], timeout: 120).code == 0 { count += 1; bytes += size }
        }
        return count > 0 ? Simulators(count: count, bytes: bytes) : nil
    }
}
