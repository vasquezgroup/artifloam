import XCTest
@testable import MacStewardCore

private final class ScanEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [ScanProgress]()
    func append(_ value: ScanProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var all: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
final class ScanProgressTests: XCTestCase {
    private func fixture() throws -> Configuration {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let base = home.appendingPathComponent(".gradle/caches/8.14.3/transforms")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8).write(to: home.appendingPathComponent(".gradle/caches/CACHEDIR.TAG"))
        for character in ["a", "b", "c"] {
            let folder = base.appendingPathComponent(String(repeating: character, count: 32))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1_100_000).write(to: folder.appendingPathComponent("generated.bin"))
        }
        XCTAssertTrue(DeveloperJunk.hasGradleMarker(home: home))
        XCTAssertEqual(DeveloperJunk.gradleCandidates(home: home).count, 3)
        var config = Configuration(home: home, includeDeveloperCaches: true, projectRoots: [])
        config.agentTemp = home.appendingPathComponent("empty-sessions")
        return config
    }
    func testKnownChecklistCountsActualChecksAndReachesCompletionWithoutDeleting() throws {
        let config = try fixture(), events = ScanEvents()
        let report = try Scanner(configuration: config).scanWithProgress({ events.append($0) }, activityOverride: ActivitySnapshot())
        let all = events.all, measured = all.filter { $0.total != nil }
        XCTAssertTrue(all.contains { $0.total == nil && $0.fraction == nil })
        // Three cache checks plus Xcode and Git inventories.
        let expected = 5
        XCTAssertEqual(Set(measured.compactMap(\.total)), [expected])
        XCTAssertEqual(measured.last?.completed, expected)
        XCTAssertEqual(measured.last?.fraction, 1)
        XCTAssertEqual(measured.last?.remaining, 0)
        for pair in zip(measured, measured.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.completed, pair.1.completed) }
        XCTAssertEqual(report.findings.filter { $0.rule == "gradle-generated-cache" }.count, 3)
        for finding in report.findings { XCTAssertTrue(FileManager.default.fileExists(atPath: finding.path)) }
    }
    func testCancellationNeverReportsUnfinishedChecksAsComplete() async throws {
        let config = try fixture(), events = ScanEvents()
        let task = Task.detached {
            try Scanner(configuration: config).scanWithProgress({ update in
                events.append(update)
                // Checks start during discovery, so cancel there: the scan must stop without claiming completion.
                withUnsafeCurrentTask { $0?.cancel() }
            }, activityOverride: ActivitySnapshot(), workers: 1)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(events.all.contains { $0.fraction == 1 })
    }
    func testSimulatorRuntimeSizeIsMeasuredOncePerVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".simruntime")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 100_000).write(to: folder.appendingPathComponent("a"))
        let suite = "runtime-size-test-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_000), first = XcodeStorageInventory.runtimeBytes(folder, modified: date, defaults: defaults)
        XCTAssertGreaterThan(first, 0)
        try Data(repeating: 1, count: 100_000).write(to: folder.appendingPathComponent("b"))
        XCTAssertEqual(XcodeStorageInventory.runtimeBytes(folder, modified: date, defaults: defaults), first, "Same runtime version reuses its size")
        XCTAssertGreaterThan(XcodeStorageInventory.runtimeBytes(folder, modified: Date(timeIntervalSince1970: 2_000), defaults: defaults), first, "A new version is measured again")
    }
    func testChecklistLimitIsExplicitRatherThanClaimingFullCoverage() throws {
        let config = try fixture(), events = ScanEvents()
        let report = try Scanner(configuration: config).scanWithProgress({ events.append($0) }, activityOverride: ActivitySnapshot(), maximumChecks: 3)
        XCTAssertEqual(events.all.last?.total, 3)
        XCTAssertEqual(events.all.last?.completed, 3)
        XCTAssertTrue(report.notices.contains { $0.contains("checklist reached 3 checks") })
    }
    func testPendingChecksReserveRoomAndInvalidCountsAreClamped() {
        let discovery = ScanProgress(message: "Preparing").addingPendingChecks(2)
        XCTAssertNil(discovery.fraction)
        let coreDone = ScanProgress(message: "Core complete", completed: 5, total: 5).addingPendingChecks(2)
        XCTAssertEqual(coreDone.total, 7); XCTAssertEqual(coreDone.remaining, 2); XCTAssertLessThan(coreDone.fraction!, 1)
        XCTAssertEqual(ScanProgress(message: "Final", completed: 7, total: 7).fraction, 1)
        XCTAssertEqual(ScanProgress(message: "Invalid", completed: -4, total: 10).completed, 0)
        XCTAssertEqual(ScanProgress(message: "Invalid", completed: 20, total: 10).completed, 10)
    }
}
