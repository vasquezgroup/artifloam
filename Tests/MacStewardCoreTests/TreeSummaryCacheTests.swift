import XCTest
@testable import MacStewardCore

final class TreeSummaryCacheTests: XCTestCase {
    func testChangesInsideACachedFolderAreReadAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cache"), deep = folder.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_000).write(to: deep.appendingPathComponent("one.bin"))
        let cache = TreeSummaryCache()
        func scan() throws -> TreeSummary { cache.prepare(watching: [root]); return try cache.read(folder, dependencies: false, reusable: true) }
        let first = try scan()
        XCTAssertEqual(try scan().fingerprint, first.fingerprint, "Unchanged folder")
        // A new file deep inside, right before the next scan.
        try Data(repeating: 2, count: 80_000).write(to: deep.appendingPathComponent("two.bin"))
        let second = try scan()
        XCTAssertNotEqual(second.fingerprint, first.fingerprint)
        XCTAssertEqual(second.fingerprint, try TreeSummary.read(folder).fingerprint)
        // An in-place append: no folder gains or loses an entry.
        let handle = try FileHandle(forWritingTo: deep.appendingPathComponent("one.bin"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 3, count: 100_000)); try handle.close()
        let third = try scan()
        XCTAssertNotEqual(third.fingerprint, second.fingerprint)
        XCTAssertEqual(third.fingerprint, try TreeSummary.read(folder).fingerprint)
        // A protected file appearing inside is refused, as a fresh read would.
        try Data("x".utf8).write(to: deep.appendingPathComponent("credentials.json"))
        XCTAssertThrowsError(try scan())
    }
    func testNotReusableFoldersAreAlwaysRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = TreeSummaryCache()
        cache.prepare(watching: [root])
        let first = try cache.read(root, dependencies: false, reusable: false)
        try Data(repeating: 1, count: 10_000).write(to: root.appendingPathComponent("file.bin"))
        XCTAssertNotEqual(try cache.read(root, dependencies: false, reusable: false).fingerprint, first.fingerprint)
    }
}
