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
    /// The bulk walk must leave out what the FileManager walk did: hidden, package, dependency and symlinked copies,
    /// and same-size files whose first 64 KB differ.
    func testWalkFindsRealCopiesOnly() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default, copy = Data(repeating: 7, count: 1_200_000)
        for folder in ["a", "b/deep", ".hidden", "Tool.app/Contents", "node_modules/x", "flagged"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for path in ["a/one.mov", "b/deep/two.mov", ".hidden/three.mov", "Tool.app/Contents/four.mov", "node_modules/x/five.mov", "flagged/six.mov"] { try copy.write(to: root.appendingPathComponent(path)) }
        var hidden = try root.appendingPathComponent("flagged").resourceValues(forKeys: [.isHiddenKey]); hidden.isHidden = true
        var flagged = root.appendingPathComponent("flagged"); try flagged.setResourceValues(hidden)
        try fm.createSymbolicLink(at: root.appendingPathComponent("a/link.mov"), withDestinationURL: root.appendingPathComponent("a/one.mov"))
        var other = copy; other[0] = 8; try other.write(to: root.appendingPathComponent("a/same-size-other.mov"))
        let groups = try DuplicateFinder.scan(folder: root)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.map { URL(fileURLWithPath: $0).lastPathComponent }, ["one.mov", "two.mov"])
    }
}
