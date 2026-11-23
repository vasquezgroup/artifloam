import XCTest
@testable import MacStewardCore

private final class Events: @unchecked Sendable {
    private let lock = NSLock(); private var values = [ScanProgress]()
    func append(_ value: ScanProgress) { lock.lock(); values.append(value); lock.unlock() }
    var all: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

/// A project folder that macOS holds back (a permission prompt nobody answers) must not hold the scan.
final class ScanStallTests: XCTestCase {
    private func held(skipAfter: TimeInterval) throws -> (MacStewardCore.Scanner, DispatchSemaphore) {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let project = home.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        var config = Configuration(home: home, projectRoots: [project])
        config.agentTemp = home.appendingPathComponent("empty-sessions")
        let scanner = MacStewardCore.Scanner(configuration: config)
        let release = DispatchSemaphore(value: 0)
        // Freed at the end so the blocked thread does not outlive the test.
        addTeardownBlock { release.signal() }
        scanner.stallAfter = 0.1; scanner.skipAfter = skipAfter
        scanner.beforeWalk = { _ in release.wait() }
        return (scanner, release)
    }
    func testHeldFolderIsSkippedAfterTheTimeoutAndNamedInTheNotices() throws {
        let (scanner, _) = try held(skipAfter: 0.5), events = Events()
        let report = try scanner.scanWithProgress({ events.append($0) }, activityOverride: ActivitySnapshot())
        XCTAssertTrue(events.all.contains { $0.stalled?.hasSuffix("/projects") == true })
        XCTAssertTrue(report.notices.contains { $0.contains("Skipped") && $0.contains("/projects") })
    }
    func testSkipButtonEndsTheWaitEarly() throws {
        let (scanner, _) = try held(skipAfter: 600)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { scanner.skip.request() }
        let started = Date()
        let report = try scanner.scanWithProgress({ _ in }, activityOverride: ActivitySnapshot())
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertTrue(report.notices.contains { $0.contains("Skipped") })
    }
    func testClickBeforeAStallDoesNotSkipTheNextOne() throws {
        let (scanner, _) = try held(skipAfter: 1.0)
        scanner.skip.request() // Left over from a moment when nothing was held.
        let started = Date()
        _ = try scanner.scanWithProgress({ _ in }, activityOverride: ActivitySnapshot())
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }
    func testHeldCheckCanBeSkippedAndIsNamed() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let cache = home.appendingPathComponent("projects/app/__pycache__")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_100_000).write(to: cache.appendingPathComponent("a.pyc"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        var config = Configuration(home: home, projectRoots: [home.appendingPathComponent("projects")])
        config.agentTemp = home.appendingPathComponent("empty-sessions")
        let scanner = MacStewardCore.Scanner(configuration: config), release = DispatchSemaphore(value: 0), events = Events()
        addTeardownBlock { release.signal() }
        scanner.stallAfter = 0.1; scanner.skipAfter = 600
        scanner.beforeCheck = { path in if path.hasSuffix("__pycache__") { release.wait() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { scanner.skip.request() }
        let report = try scanner.scanWithProgress({ events.append($0) }, activityOverride: ActivitySnapshot())
        XCTAssertTrue(events.all.contains { $0.stalled?.hasSuffix("__pycache__") == true && $0.total != nil })
        XCTAssertTrue(report.notices.contains { $0.contains("__pycache__") && $0.contains("as you asked") })
        XCTAssertFalse(report.findings.contains { $0.path.hasSuffix("__pycache__") })
    }
}
