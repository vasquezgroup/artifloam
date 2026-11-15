import XCTest
@testable import MacStewardCore

/// Red locks: risky items the person may still delete after unlocking them. Nothing that would break an app or macOS.
final class RedLockTests: XCTestCase {
    private func finding(_ group: CleanupGroup = .developerCaches, safety: Safety = .protected, hold: Hold? = .inUse, rule: String = "npm-cache", path: String = "/x") -> Finding {
        Finding(path: path, group: group, bytes: 1, modifiedAt: Date(), safety: safety, reason: "", rule: rule, fingerprint: "f", hold: hold)
    }
    func testOnlyHeldRiskyItemsGetARedLock() {
        XCTAssertTrue(finding().dangerous, "in use")
        XCTAssertTrue(finding(hold: .unverified).dangerous)
        XCTAssertFalse(finding(hold: .recent).dangerous, "recent is orange: choosable without unlocking")
        XCTAssertFalse(finding(hold: nil).dangerous, "kept on purpose, nothing the cleaner can delete")
        XCTAssertFalse(finding(.systemCaches).dangerous, "would break macOS")
        XCTAssertFalse(finding(.languages).dangerous, "would break an app's signature")
        XCTAssertFalse(finding(.worktrees, rule: "worktree-review-only").dangerous, "Git rechecks worktrees in their own flow")
        XCTAssertFalse(finding(safety: .automatic, hold: nil).dangerous)
    }
    func testSmartPickFallsBackToOrangeButNeverRed() {
        let red = finding(path: "/red"), orange = finding(hold: .recent, path: "/orange"), ready = finding(safety: .automatic, hold: nil, path: "/ready")
        XCTAssertEqual([red, orange, ready].smartPick(reviewable: []).map(\.path), ["/ready"])
        XCTAssertEqual([red, orange].smartPick(reviewable: []).map(\.path), ["/orange"])
        XCTAssertTrue([red].smartPick(reviewable: []).isEmpty)
    }
    func testSessionScratchFolderWithARepositoryIsDeletedOnlyAfterUnlocking() throws {
        // Real /private/tmp spelling: Foundation shortens it to /tmp, which must not count as a different path.
        let temp = URL(fileURLWithPath: "/private/tmp/artifloam-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let session = temp.appendingPathComponent("-Users-x-project/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session.appendingPathComponent("clone/.git"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: session.appendingPathComponent("clone/big.bin"))
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        var config = Configuration(home: home, projectRoots: []); config.agentTemp = temp
        XCTAssertNoThrow(try SafetyPolicy(configuration: config).validatePath(session, rule: "agent-session-scratch"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(session.appendingPathComponent("clone"), rule: "agent-session-scratch"), "only <temp>/<project>/<session id>")
        let item = Finding(path: session.path, group: .agentBuilds, bytes: 2_000_000, modifiedAt: Date(), safety: .protected, reason: "", rule: "agent-session-scratch", fingerprint: "f", hold: .unverified)
        XCTAssertTrue(item.dangerous)
        let busy = ActivitySnapshot(openPaths: [session.path + "/clone/big.bin"])
        let locked = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [item]), selectedIDs: [item.id], activityOverride: busy)
        XCTAssertEqual(locked.removedCount, 0, "never without the person's unlock")
        let unlocked = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [item]), selectedIDs: [item.id], approvedIDs: [item.id], activityOverride: busy)
        XCTAssertEqual(unlocked.removedCount, 1, unlocked.items.first?.detail ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }
}
