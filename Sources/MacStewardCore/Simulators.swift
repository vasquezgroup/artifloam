import Foundation

/// A virtual iPhone, iPad or Watch that Xcode keeps in ~/Library/Developer/CoreSimulator, as `simctl` reports it.
public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    /// The UDID, also its folder name.
    public let id: String
    /// "iPhone 18 Pro · iOS 27.2"
    public let name: String
    public let bytes: UInt64
    /// false: made for an iOS version this Xcode no longer has, so it can't start.
    public let available: Bool
    public let lastUsed: Date?
    public let running: Bool
    public static let idleDays = 30
    /// Sure to delete without knowing what it is: shut down, and Xcode can't start it or nothing used it for 30 days.
    /// No recorded use counts as used, so a missing date never makes it sure.
    public func safeToDelete(now: Date = Date()) -> Bool {
        !running && (!available || (lastUsed.map { now.timeIntervalSince($0) >= Double(Self.idleDays) * 86_400 } ?? false))
    }
}

public enum Simulators {
    /// `xcrun simctl list devices -j`. Anything without a real UDID is skipped.
    public static func parse(_ data: Data) -> [SimulatorDevice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let groups = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return groups.flatMap { runtime, devices in
            devices.compactMap { device -> SimulatorDevice? in
                guard let udid = device["udid"] as? String, UUID(uuidString: udid) != nil else { return nil }
                let os = runtime.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: ".")
                    .replacingOccurrences(of: "iOS.", with: "iOS ").replacingOccurrences(of: "watchOS.", with: "watchOS ").replacingOccurrences(of: "tvOS.", with: "tvOS ").replacingOccurrences(of: "xrOS.", with: "visionOS ") ?? ""
                return SimulatorDevice(id: udid, name: [device["name"] as? String ?? String(localized: "Simulator"), os].filter { !$0.isEmpty }.joined(separator: " · "),
                                       bytes: (device["dataPathSize"] as? NSNumber)?.uint64Value ?? 0, available: device["isAvailable"] as? Bool ?? true,
                                       lastUsed: (device["lastUsedAt"] as? String).flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                                       running: !["Shutdown", nil].contains(device["state"] as? String))
            }
        }
    }
    /// nil when Xcode's tools aren't there or don't answer.
    public static func list() -> [SimulatorDevice]? {
        let result = run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 12)
        return result.code == 0 ? parse(Data(result.output.utf8)) : nil
    }
    /// Like turning off a phone: its apps and data stay, and Xcode starts it again when needed.
    public static func shutdown(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && run("/usr/bin/xcrun", ["simctl", "shutdown", id], timeout: 60).code == 0
    }
    /// Memory each running simulator uses: its launchd_sim and everything that started under it.
    public static func memory(of ids: [String]) -> [String: UInt64] {
        memory(ps: run("/bin/ps", ["-axo", "pid=,ppid=,rss=,command="], timeout: 5).output, ids: ids)
    }
    static func memory(ps: String, ids: [String]) -> [String: UInt64] {
        var children = [Int: [Int]](), rss = [Int: UInt64](), roots = [String: Int]()
        for line in ps.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let parent = Int(parts[1]), let kb = UInt64(parts[2]) else { continue }
            children[parent, default: []].append(pid); rss[pid] = kb * 1024
            let command = String(parts[3])
            if command.hasPrefix("launchd_sim "), let id = ids.first(where: { command.contains("/Devices/\($0)/") }) { roots[id] = pid }
        }
        return roots.mapValues { root in
            var total: UInt64 = 0, stack = [root], seen = Set<Int>()
            while let pid = stack.popLast() { if seen.insert(pid).inserted { total += rss[pid] ?? 0; stack += children[pid] ?? [] } }
            return total
        }
    }
}
