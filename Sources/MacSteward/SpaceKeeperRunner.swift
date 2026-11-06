import SwiftUI
import UserNotifications
import MacStewardCore

/// Runs "Keep space free" while Artifloam is open (it stays in the menu bar when the window closes).
@MainActor
final class SpaceKeeperRunner: ObservableObject {
    private let defaults = StewardPreferences.defaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "keepSpaceFree") } }
    @Published var includeSimulators: Bool { didSet { defaults.set(includeSimulators, forKey: "keepSpaceFreeSimulators") } }
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastFreed: UInt64 = 0
    /// Still under the low-space line: what's left needs a person's choice in Cleanup.
    @Published private(set) var needsReview = false
    nonisolated static let reviewNotification = "keep-space-free-review"
    /// Xcode is installed, so the simulator option is worth showing.
    let hasXcode = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

    init() {
        enabled = defaults.bool(forKey: "keepSpaceFree")
        // Off until chosen: this deletes the apps and data inside for good, and a runtime can look missing only for a while.
        includeSimulators = defaults.object(forKey: "keepSpaceFreeSimulators") as? Bool ?? false
        lastRun = defaults.object(forKey: "keepSpaceFreeLastRun") as? Date
        lastFreed = (defaults.object(forKey: "keepSpaceFreeLastFreed") as? NSNumber)?.uint64Value ?? 0
    }

    /// Called with every disk reading; starts a run when it's due.
    func consider(disk: DiskSpace, configuration: @autoclosure () -> Configuration, busy: Bool) {
        let low = enabled && SpaceKeeper.isLow(free: disk.free, total: disk.total)
        if low != needsReview { needsReview = low }
        guard enabled, !running, !busy, SpaceKeeper.reason(free: disk.free, total: disk.total, lastRun: lastRun) != nil else { return }
        run(configuration())
    }

    func run(_ base: Configuration, notify: Bool = true) {
        guard !running else { return }
        running = true
        var configuration = base
        configuration.includeApplicationCaches = true
        let simulators = includeSimulators && hasXcode
        Task {
            let freed = await Task.detached(priority: .utility) { () -> UInt64 in
                var freed: UInt64 = 0
                // 1. Caches that rebuild, of closed apps, and old logs: exactly what the cleaner treats as automatic.
                if let report = try? Scanner(configuration: configuration, summaries: StewardModel.treeSummaries).scan(),
                   let receipt = try? Cleaner(configuration: configuration).clean(report, selectedIDs: SpaceKeeper.selection(report)) {
                    freed += receipt.items.filter { $0.outcome == "removed" }.reduce(0) { $0 + $1.bytes }
                }
                // 2. Browser caches, only for browsers that are closed. Sign-ins and website data stay.
                let browserItems = BrowserData.scan().filter { !BrowserData.isRunning($0.bundleID) }.flatMap(\.items).filter(\.recommended)
                let removed = Set(BrowserData.clean(Set(browserItems.map(\.id)), ignoredPaths: configuration.ignoredPaths).removed)
                freed += browserItems.filter { removed.contains($0.id) }.reduce(0) { $0 + $1.bytes }
                // 3. Developers: simulators Xcode can no longer run.
                if simulators, let gone = SpaceKeeper.removeUnavailableSimulators(ignoredPaths: configuration.ignoredPaths) { freed += gone.bytes }
                return freed
            }.value
            lastRun = Date(); lastFreed = freed; running = false
            defaults.set(lastRun, forKey: "keepSpaceFreeLastRun"); defaults.set(NSNumber(value: freed), forKey: "keepSpaceFreeLastFreed")
            if notify && freed > 50_000_000 { Self.notify(String(localized: "Freed \(formattedBytes(freed))"), String(localized: "Keep space free cleaned caches that rebuild themselves. Your files were not touched.")) }
            let disk = DiskSpace.read()
            needsReview = enabled && SpaceKeeper.isLow(free: disk.free, total: disk.total)
            if notify && needsReview { offerReview() }
        }
    }

    /// At most once a day: this runs again every 6 hours while the disk stays nearly full.
    private func offerReview() {
        let last = defaults.object(forKey: "keepSpaceFreeReviewOffered") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        defaults.set(Date(), forKey: "keepSpaceFreeReviewOffered")
        Self.notify(String(localized: "Your Mac is still low on space"), String(localized: "Artifloam cleaned what's safe to remove on its own. Click to review larger items you can choose to remove."), identifier: Self.reviewNotification)
    }

    private static func notify(_ title: String, _ body: String, identifier: String = "keep-space-free") {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
