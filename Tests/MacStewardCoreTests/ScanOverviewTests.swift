import XCTest
@testable import MacStewardCore

final class ScanOverviewTests: XCTestCase {
    func testOnlyAutomaticCachesContributeToEligibleSpace() {
        func item(_ path: String, _ group: CleanupGroup, _ safety: Safety, _ bytes: UInt64) -> Finding {
            Finding(path: path, group: group, bytes: bytes, modifiedAt: Date(), safety: safety, reason: "fixture", rule: "fixture", fingerprint: path)
        }
        let result = ScanOverview(findings: [item("/a", .projectCaches, .automatic, 100), item("/b", .xcode, .automatic, 300), item("/c", .worktrees, .review, 9_000), item("/d", .projectCaches, .protected, 2_000)])
        XCTAssertEqual(result.eligibleBytes, 400)
        XCTAssertEqual(result.automaticCount, 2)
        XCTAssertEqual(result.reviewCount, 1)
        XCTAssertEqual(result.protectedCount, 1)
        XCTAssertEqual(result.categories.count, CleanupGroup.allCases.count)
        let projects = result.categories.first { $0.group == .projectCaches }
        XCTAssertEqual(projects?.count, 2)
        XCTAssertEqual(projects?.eligibleBytes, 100)
        XCTAssertEqual(result.categories.first { $0.group == .worktrees }?.eligibleBytes, 0)
    }
    func testEmptyScanHasZeroTotalsAndRetainsAllCategories() {
        let result = ScanOverview(findings: [])
        XCTAssertEqual(result.eligibleBytes, 0)
        XCTAssertEqual(result.automaticCount, 0)
        XCTAssertTrue(result.categories.allSatisfy { $0.count == 0 })
    }
}
