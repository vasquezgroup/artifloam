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
}
