import XCTest
@testable import MacStewardCore

final class DuplicateKeepOneTests: XCTestCase {
    func testOneCopyAlwaysStays() {
        let groups = [DuplicateGroup(id: "a", files: ["/a1", "/a2", "/a3"], size: 1), DuplicateGroup(id: "b", files: ["/b1", "/b2"], size: 1)]
        XCTAssertEqual(DuplicateGroup.trashable(["/a2", "/a3", "/b2"], in: groups), ["/a2", "/a3", "/b2"])
        XCTAssertEqual(DuplicateGroup.trashable(["/a1", "/a2", "/a3", "/b1", "/b2"], in: groups), ["/a2", "/a3", "/b2"], "every copy chosen still leaves one per group")
        XCTAssertEqual(DuplicateGroup.trashable(["/elsewhere"], in: groups), [], "paths outside the groups are ignored")
    }
    func testExtrasKeepTheChosenCopyWithoutDiskReads() {
        let groups = [DuplicateGroup(id: "a", files: ["/a1", "/a2", "/a3"], size: 1), DuplicateGroup(id: "b", files: ["/b1", "/b2"], size: 1)]
        XCTAssertEqual(DuplicateGroup.extras(groups, keeping: ["a": "/a2", "b": "/b1"]), ["/a1", "/a3", "/b2"])
        XCTAssertEqual(DuplicateGroup.extras(groups, keeping: ["a": "/gone"]), ["/a2", "/a3", "/b2"], "a missing or stale choice keeps the first copy")
    }
}
