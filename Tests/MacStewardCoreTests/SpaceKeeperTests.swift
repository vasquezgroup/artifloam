import XCTest
@testable import MacStewardCore

final class SpaceKeeperTests: XCTestCase {
    private let gb: UInt64 = 1 << 30
    func testRunsWeeklyAndRightAwayWhenSpaceIsLowButNotInALoop() {
        let now = Date()
        XCTAssertEqual(SpaceKeeper.reason(free: 400 * gb, total: 1000 * gb, lastRun: nil, now: now), .weekly, "first run happens")
        XCTAssertNil(SpaceKeeper.reason(free: 400 * gb, total: 1000 * gb, lastRun: now.addingTimeInterval(-2 * 86_400), now: now))
        XCTAssertEqual(SpaceKeeper.reason(free: 400 * gb, total: 1000 * gb, lastRun: now.addingTimeInterval(-8 * 86_400), now: now), .weekly)
        XCTAssertEqual(SpaceKeeper.reason(free: 100 * gb, total: 1000 * gb, lastRun: now.addingTimeInterval(-7 * 3600), now: now), .lowSpace)
        XCTAssertNil(SpaceKeeper.reason(free: 100 * gb, total: 1000 * gb, lastRun: now.addingTimeInterval(-3600), now: now), "never more often than every 6 hours")
    }
    private func item(_ path: String, _ group: CleanupGroup, _ safety: Safety, rule: String) -> Finding {
        Finding(path: path, group: group, bytes: 1, modifiedAt: Date(), safety: safety, reason: "", rule: rule, fingerprint: "")
    }
    func testUnattendedRunTakesOnlyExactKnownLocations() {
        let report = ScanReport(home: "/fixture", findings: [
            item("/logs", .userLogs, .automatic, rule: "old-user-log"), item("/sim", .xcode, .automatic, rule: "simulator-cache"),
            item("/Caches/org.swift.swiftpm", .userCaches, .automatic, rule: "app-cache"), item("/Caches/com.tool.ShipIt", .userCaches, .automatic, rule: "app-cache"), item("/.cache/uv", .userCaches, .automatic, rule: "xdg-cache"),
            // Unknown contents and tool commands wait for a person.
            item("/Caches/Adobe", .userCaches, .automatic, rule: "app-cache"), item("/.cache/codex-runtimes", .userCaches, .automatic, rule: "xdg-cache"), item("/brew", .developerCaches, .automatic, rule: "homebrew-cache"),
            item("/gradle", .developerCaches, .automatic, rule: "gradle-generated-cache"), item("/.npm/_cacache", .developerCaches, .automatic, rule: "npm-cache"), item("/old", .agentBuilds, .automatic, rule: "old-agent-version"),
            // Never without a person, whatever the rule.
            item("/held", .userCaches, .protected, rule: "old-user-log"), item("/deps", .inactiveDependencies, .automatic, rule: "inactive-dependencies"), item("/tree", .worktrees, .review, rule: "worktree-review-only"), item("/d", .xcode, .review, rule: XcodeStorageInventory.simulatorRule)
        ])
        XCTAssertEqual(SpaceKeeper.selection(report), ["/logs", "/sim", "/Caches/org.swift.swiftpm", "/Caches/com.tool.ShipIt", "/.cache/uv"])
    }
    func testLowSpaceLine() {
        XCTAssertTrue(SpaceKeeper.isLow(free: 149 * gb, total: 1000 * gb))
        XCTAssertFalse(SpaceKeeper.isLow(free: 150 * gb, total: 1000 * gb))
        XCTAssertFalse(SpaceKeeper.isLow(free: 0, total: 0), "an unreadable disk is not a low one")
    }
    func testSimulatorsListedWhenShutDownAndSureOnlyWhenBrokenOrLongIdle() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!
        func device(_ id: Int, state: String = "Shutdown", available: Bool = true, used: String? = nil, size: Int = 2_000_000_000) -> [String: Any] {
            var value: [String: Any] = ["udid": String(format: "00000000-0000-0000-0000-%012d", id), "name": "Phone \(id)", "state": state, "isAvailable": available, "dataPathSize": size]
            if let used { value["lastUsedAt"] = used }
            return value
        }
        let list: [String: Any] = ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
            device(1, available: false), device(2, used: "2026-09-01T00:00:00Z"), device(3, used: "2026-09-01T00:00:00.123Z"),
            device(4, used: "2026-10-30T00:00:00Z"), device(5), device(6, state: "Booted", available: false), device(7, available: false, size: 4096)]]]
        let all = Simulators.parse(try JSONSerialization.data(withJSONObject: list))
        let listed = XcodeStorageInventory.deletableSimulators(all)
        XCTAssertEqual(Set(listed.map { Int($0.id.suffix(12))! }), [1, 2, 3, 4, 5], "running and empty ones aren't listed")
        XCTAssertEqual(Set(listed.filter { $0.safeToDelete(now: now) }.map { Int($0.id.suffix(12))! }), [1, 2, 3], "recent and undated ones are the person's call")
        XCTAssertFalse(all.first { $0.id.hasSuffix("6") }!.safeToDelete(now: now), "never a running one")
        XCTAssertEqual(listed.first?.name.hasSuffix("iOS 18.0"), true)
        XCTAssertTrue(Simulators.parse(Data("not json".utf8)).isEmpty)
    }
    func testSimulatorMemoryCountsItsWholeProcessTree() {
        let id = "EB339375-40A8-4A6D-BEB5-29AAE682F7CE"
        let ps = """
          10     1   100 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/\(id)/data/var/run/launchd_bootstrap.plist
          11    10   200 SpringBoard
          12    11    50 widget
          20     1   999 Safari
        """
        XCTAssertEqual(Simulators.memory(ps: ps, ids: [id, "OTHER"]), [id: 350 * 1024])
    }
    func testSimulatorFindingNeedsItsOwnTickAndAnExactPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000001").path
        let finding = Finding(path: path, group: .xcode, bytes: 1, modifiedAt: Date(), safety: .review, reason: "", rule: XcodeStorageInventory.simulatorRule, fingerprint: "review-only", warnings: ["Deletes it"], label: "Phone")
        XCTAssertTrue(finding.userCleanable); XCTAssertFalse(finding.tickable, "bulk selection skips it")
        XCTAssertEqual(finding.title, "Phone")
        let report = ScanReport(home: home.path, findings: [finding])
        let receipt = try Cleaner(configuration: Configuration(home: home)).clean(report, selectedIDs: [finding.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(receipt.items.first?.outcome, "skipped", "not approved by a person")
        let elsewhere = Finding(path: "/tmp/00000000-0000-0000-0000-000000000001", group: .xcode, bytes: 1, modifiedAt: Date(), safety: .review, reason: "", rule: XcodeStorageInventory.simulatorRule, fingerprint: "review-only")
        XCTAssertThrowsError(try XcodeStorageInventory.removeSimulator(elsewhere, configuration: Configuration(home: home), activity: ActivitySnapshot()))
        try? FileManager.default.removeItem(at: home)
    }
    func testSimulatorAndItsCachesCountOnceAndCanBeTickedTogether() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000001").path
        let simulator = Finding(path: path, group: .xcode, bytes: 10, modifiedAt: Date(), safety: .review, reason: "", rule: XcodeStorageInventory.simulatorRule, fingerprint: "review-only")
        let cache = Finding(path: path + "/data/Library/Caches", group: .xcode, bytes: 4, modifiedAt: Date(), safety: .automatic, reason: "", rule: "simulator-cache", fingerprint: "")
        let other = Finding(path: path + "-other", group: .xcode, bytes: 3, modifiedAt: Date(), safety: .automatic, reason: "", rule: "simulator-cache", fingerprint: "")
        let counted = XcodeStorageInventory.countingNestedCachesOnce([simulator, cache, other])
        XCTAssertEqual(counted.map(\.bytes), [6, 4, 3], "only caches inside the simulator are subtracted")
        let report = ScanReport(home: home.path, findings: [simulator, cache])
        let receipt = try Cleaner(configuration: Configuration(home: home)).clean(report, selectedIDs: [simulator.id, cache.id], approvedIDs: [simulator.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(receipt.items.map(\.path), [cache.path, simulator.path], "no overlap error, and the simulator goes last")
    }
    func testNpmCacheRuleMatchesOnlyTheExactFolder() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        XCTAssertNoThrow(try SafetyPolicy(configuration: Configuration(home: home, includeDeveloperCaches: true)).validatePath(cache, rule: "npm-cache"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: Configuration(home: home, includeDeveloperCaches: true)).validatePath(home.appendingPathComponent(".npm"), rule: "npm-cache"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: Configuration(home: home, includeDeveloperCaches: false)).validatePath(cache, rule: "npm-cache"))
        XCTAssertEqual(DeveloperJunk.minimumAge(rule: "npm-cache", configured: 7), 30)
    }
}

final class BulkSelectionTests: XCTestCase {
    private func finding(_ path: String, _ group: CleanupGroup, _ safety: Safety, hold: Hold? = nil, owner: String? = nil) -> Finding {
        Finding(path: path, group: group, bytes: 1, modifiedAt: Date(), safety: safety, reason: "fixture", rule: "fixture", fingerprint: path, hold: hold, owner: owner)
    }
    func testCategoryTakesRecentCachesButAllStaysWithReadyItems() {
        let ready = finding("/ready", .userCaches, .automatic), recent = finding("/recent", .userCaches, .protected, hold: .recent)
        let running = finding("/running", .userCaches, .protected, hold: .inUse, owner: "App"), unknown = finding("/unknown", .userCaches, .protected, hold: .inUse), locked = finding("/locked", .userCaches, .protected)
        let other = finding("/other", .userLogs, .automatic), tree = finding("/tree", .worktrees, .review), unfinished = finding("/unfinished", .worktrees, .protected)
        let all = [ready, recent, running, unknown, locked, other, tree, unfinished]
        XCTAssertEqual(all.bulkChoosable(in: .userCaches).map(\.path), ["/ready", "/recent", "/running"])
        XCTAssertEqual(all.bulkChoosable(in: nil).map(\.path), ["/ready", "/other"])
        XCTAssertEqual(all.bulkChoosable(in: .worktrees).map(\.path), ["/tree"])
    }
}
