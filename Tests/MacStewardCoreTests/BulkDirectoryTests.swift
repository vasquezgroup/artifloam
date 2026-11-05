import XCTest
@testable import MacStewardCore

final class BulkDirectoryTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testFolderSizeCountsEverythingNextToASymlink() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        // The FileManager version skipped the folder listed after a symlink.
        for name in ["a-link", "b-link", "c-link"] { try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: "/tmp") }
        for name in ["one", "two", "three"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 300_000).write(to: root.appendingPathComponent(name).appendingPathComponent("data.bin"))
        }
        var expected: UInt64 = 0
        for name in ["one", "two", "three"] {
            let values = try root.appendingPathComponent(name).appendingPathComponent("data.bin").resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            expected += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        XCTAssertEqual(directoryBytes(root), expected)
        XCTAssertEqual(allocatedSize(root), expected)
    }
    func testAppleDoubleFilesStayHiddenLikeFileManager() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 200_000).write(to: root.appendingPathComponent("._sidecar"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("._folder"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: root.appendingPathComponent("._folder/kept.bin"))
        let listed = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(listed, ["._folder"], "FileManager hides AppleDouble files, not folders")
        let kept = try root.appendingPathComponent("._folder/kept.bin").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        XCTAssertEqual(directoryBytes(root), UInt64(kept))
        var visited = [String]()
        walk(root, maximumDepth: 3, includeFiles: true) { url, _ in visited.append(url.lastPathComponent); return true }
        XCTAssertFalse(visited.contains("._sidecar"))
        XCTAssertTrue(visited.contains("kept.bin"))
        XCTAssertEqual(try StorageMapper.scan(root: root).bytes, UInt64(kept))
    }
    func testOpenFilesLeaveOutOnlyThisProcess() {
        let output = "p100\nfcwd\nn/Users/a/cache\np\(getpid())\nf3\nn/Users/a/scanned\np200\nf4\nn/Users/a/other\n"
        XCTAssertEqual(ActivitySnapshot.openPaths(lsof: output, leaving: getpid()), ["/Users/a/cache", "/Users/a/other"])
    }
}
