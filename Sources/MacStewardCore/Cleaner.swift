import Foundation
import Darwin

public final class Cleaner {
    public let configuration: Configuration
    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }
    /// `approvedIDs`: held items the user ticked themselves (recent caches, caches whose app was quit).
    public func clean(_ report: ScanReport, selectedIDs: Set<String>, approvedIDs: Set<String> = [], progress: @Sendable (CleanProgress) -> Void = { _ in }) throws -> CleanupReceipt {
        try clean(report, selectedIDs: selectedIDs, approvedIDs: approvedIDs, activityOverride: nil, progress: progress)
    }
    // Test-only injection stays internal; the public API always captures real activity.
    func clean(_ report: ScanReport, selectedIDs: Set<String>, approvedIDs: Set<String> = [], activityOverride: ActivitySnapshot?, progress: @Sendable (CleanProgress) -> Void = { _ in }) throws -> CleanupReceipt {
        guard report.version == 1, report.home == configuration.home.path, Date().timeIntervalSince(report.createdAt) >= 0, Date().timeIntervalSince(report.createdAt) < 3600 else { throw StewardError.blocked(String(localized: "Scan is expired or belongs to another home directory")) }
        let state = configuration.home.appendingPathComponent("Library/Application Support/MacSteward", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = state.appendingPathComponent("cleanup.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw StewardError.blocked(String(localized: "Cannot open cleanup lock")) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw StewardError.blocked(String(localized: "Another cleanup is running")) }
        defer { _ = flock(lock, LOCK_UN) }
        let before = DiskSpace.read(at: configuration.home.path); var items = [CleanupItem]()
        let policy = SafetyPolicy(configuration: configuration)
        // A simulator or a reviewed Xcode folder goes last: caches inside it may be ticked too, and they are cleaned first.
        let containers: Set<String> = [XcodeStorageInventory.simulatorRule, XcodeStorageInventory.trashRule]
        let selected = report.findings.filter { selectedIDs.contains($0.id) }.sorted { !containers.contains($0.rule) && containers.contains($1.rule) }
        // Parent/child overlap can double count and invalidate plans; reject it.
        for first in selected { for second in selected where first.id != second.id && !containers.contains(second.rule) {
            if first.path.hasPrefix(second.path + "/") { throw StewardError.blocked(String(localized: "Overlapping cleanup targets; scan again")) }
        } }
        var snapshot: (taken: Date, activity: ActivitySnapshot)?
        var freed: UInt64 = 0
        for (index, finding) in selected.enumerated() {
            // Stop between items: the one in progress always finishes, the rest are left untouched.
            if Task.isCancelled {
                items += selected[index...].map { CleanupItem(path: $0.path, outcome: "skipped", detail: String(localized: "Stopped before cleaning"), bytes: 0) }
                break
            }
            let removedSoFar = items.filter { $0.outcome == "removed" }.count
            progress(CleanProgress(completed: index, total: selected.count, current: finding.title, group: finding.group, freedBytes: freed, removed: removedSoFar, skipped: index - removedSoFar))
            defer { freed = items.filter { $0.outcome == "removed" }.reduce(0) { $0 + $1.bytes } }
            do {
                try Task.checkCancellation()
                // Refresh open-file/process evidence before each destructive operation.
                // Open-file/process evidence is at most 5 seconds old for every destructive operation.
                if snapshot == nil || Date().timeIntervalSince(snapshot!.taken) > 5 { snapshot = (Date(), activityOverride ?? ActivitySnapshot.capture()) }
                let activity = snapshot!.activity
                if finding.rule == XcodeStorageInventory.trashRule {
                    guard approvedIDs.contains(finding.id) else { throw StewardError.blocked(String(localized: "Only folders you ticked are deleted")) }
                    try XcodeStorageInventory.trash(finding, configuration: configuration, activity: activity)
                    items.append(CleanupItem(path: finding.path, outcome: "removed", detail: finding.reason, bytes: finding.bytes)); continue
                }
                if finding.rule == XcodeStorageInventory.simulatorRule {
                    guard approvedIDs.contains(finding.id) else { throw StewardError.blocked(String(localized: "Only simulators you ticked are removed")) }
                    try XcodeStorageInventory.removeSimulator(finding, configuration: configuration, activity: activity)
                    items.append(CleanupItem(path: finding.path, outcome: "removed", detail: String(localized: "\(finding.title). \(finding.reason)"), bytes: finding.bytes)); continue
                }
                let tree = try policy.validate(finding, activity: activity, approved: approvedIDs.contains(finding.id))
                try SecureRemoval.remove(URL(fileURLWithPath: finding.path), tree: tree)
                items.append(CleanupItem(path: finding.path, outcome: "removed", detail: finding.reason, bytes: finding.bytes))
            } catch { items.append(CleanupItem(path: finding.path, outcome: "skipped", detail: error.localizedDescription, bytes: 0)) }
        }
        let receipt = CleanupReceipt(id: UUID(), date: Date(), before: before, after: .read(at: configuration.home.path), items: items)
        let logs = state.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: logs.appendingPathComponent(receipt.id.uuidString + ".json"), options: [.atomic])
        return receipt
    }
}

/// Live state of a cleanup for the cleaning screen.
public struct CleanProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let current: String
    public let group: CleanupGroup?
    public let freedBytes: UInt64
    public let removed: Int
    public let skipped: Int
    public var finished: Bool { completed >= total }
    public init(completed: Int, total: Int, current: String, group: CleanupGroup?, freedBytes: UInt64, removed: Int, skipped: Int) {
        self.completed = completed; self.total = total; self.current = current; self.group = group; self.freedBytes = freedBytes; self.removed = removed; self.skipped = skipped
    }
}
