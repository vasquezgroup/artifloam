import XCTest
import Darwin
@testable import MacStewardCore

final class StorageMapTests: XCTestCase {
    func testMapsAllocatedBytesWithoutFollowingSymlinksOrCountingHardlinksTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.bin")
        try Data(repeating: 65, count: 1_500_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: folder.appendingPathComponent("hardlink.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: folder)
        let result = try StorageMapper.scan(root: root)
        XCTAssertEqual(result.entries.first { $0.url.lastPathComponent == "alias" }?.bytes, 0)
        XCTAssertEqual(result.entries.first { $0.url.lastPathComponent == "folder" }?.fileCount, 1)
        XCTAssertEqual(result.largestFiles.count, 1)
        XCTAssertEqual(result.bytes, result.largestFiles.first?.bytes)
        XCTAssertTrue(result.finished)
        XCTAssertFalse(result.limited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testBudgetMarksPartialMeasurements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<5 { try Data(repeating: 65, count: 2000).write(to: root.appendingPathComponent("\(index).bin")) }
        let result = try StorageMapper.scan(root: root, maximumEntries: 1)
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.entries.contains { !$0.complete })
        let deeper = try StorageMapper.scan(root: root, maximumEntries: 100)
        XCTAssertFalse(deeper.limited)
        XCTAssertTrue(deeper.entries.allSatisfy(\.complete))
        XCTAssertGreaterThan(deeper.bytes, result.bytes)
    }
    func testSubfolderOpensFromPartialMapAndMeasuresWhatIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for index in 0..<4 { try Data(repeating: 65, count: 2000).write(to: inner.appendingPathComponent("\(index).bin")) }
        let partial = try StorageMapper.scan(root: root, maximumEntries: 2)
        XCTAssertTrue(partial.limited)
        XCTAssertFalse(partial.canRefreshIncrementally)
        XCTAssertTrue(partial.canOpenSubfolders)
        XCTAssertFalse(partial.hasMeasured(inner))
        let full = try StorageMapper.scan(root: root, maximumEntries: 100)
        XCTAssertTrue(full.hasMeasured(inner))
        let opened = try StorageMapper.refresh(partial, root: inner, changedPaths: [], maximumEntries: 100)
        XCTAssertEqual(opened.root.path, inner.path)
        XCTAssertFalse(opened.limited)
        XCTAssertEqual(opened.entries.count, 4)
        XCTAssertTrue(opened.entries.allSatisfy { $0.complete && $0.bytes > 0 })
    }
    func testCancelledMappingThrows() async throws {
        let task = Task.detached { try Task.checkCancellation(); return try StorageMapper.scan(root: URL(fileURLWithPath: "/")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled mapping should not return a full map") } catch is CancellationError { }
    }
}

extension StorageMapTests {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ root: URL, _ relative: String, bytes: Int) throws -> URL {
        let path = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: path)
        return path
    }
    func testSparseLogicalSizeIsNotCloudOrLocalAllocatedSpace() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let path = try write(root, "sparse.bin", bytes: 0)
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 10_000_000); try handle.close()
        let value = try StorageMapper.scan(root: root)
        XCTAssertEqual(value.logicalBytes, 10_000_000)
        XCTAssertLessThan(value.bytes, value.logicalBytes)
        XCTAssertEqual(value.cloudLogicalBytes, 0)
        XCTAssertEqual(value.onlineOnlyCount, 0)
    }
    func testCloudSizeAndAvailabilityUseMetadataWithoutOpeningContents() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "local.bin", bytes: 100)
        _ = try write(root, "cloud.bin", bytes: 200)
        _ = try write(root, "unknown.bin", bytes: 300)
        let placeholder = try write(root, "online.bin", bytes: 0)
        let handle = try FileHandle(forWritingTo: placeholder); try handle.truncate(atOffset: 8_000_000); try handle.close()
        let value = try StorageMapper.run(root: root, previous: nil, changedPaths: [], maximumEntries: 100, maximumDuration: 10, cloudProbe: { url, _ in
            switch url.lastPathComponent { case "cloud.bin": return .cloud; case "online.bin": return .onlineOnly; case "unknown.bin": return .unknownCloud; default: return .local }
        })
        XCTAssertEqual(value.cloudFileCount, 3)
        XCTAssertEqual(value.onlineOnlyCount, 1)
        XCTAssertEqual(value.cloudLogicalBytes, 8_000_500)
        XCTAssertEqual(value.logicalBytes, 8_000_600)
        XCTAssertEqual(value.entries.first { $0.url.lastPathComponent == "unknown.bin" }?.unknownCloudCount, 1)
        XCTAssertEqual(value.largestCloudFiles.first?.url.lastPathComponent, "online.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))
    }
    func testDatalessLocalSparseFileIsNotBlindlyClassifiedAsCloud() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let plain = try write(root, "plain.bin", bytes: 0)
        XCTAssertEqual(StorageMapper.cloudStatus(plain, flags: UInt32(SF_DATALESS), home: root), .local)
        let provider = try write(root, "Library/CloudStorage/TestDrive/online.bin", bytes: 0)
        XCTAssertEqual(StorageMapper.cloudStatus(provider, flags: UInt32(SF_DATALESS), home: root), .onlineOnly)
        XCTAssertEqual(StorageMapper.cloudStatus(root.appendingPathComponent("Library/CloudStorage/TestDrive/missing.bin"), flags: 0, home: root), .unknownCloud)
    }
    func testRefreshReadsChangedAncestorsAndReusesOtherFolders() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let changed = try write(root, "A/nested/change.bin", bytes: 1_100_000)
        for i in 0..<20 { _ = try write(root, "B/keep\(i).bin", bytes: 2000) }
        let initial = try StorageMapper.scan(root: root)
        try Data(repeating: 66, count: 2_100_000).write(to: changed)
        let updated = try StorageMapper.refresh(initial, changedPaths: [changed])
        XCTAssertTrue(updated.incremental)
        XCTAssertGreaterThanOrEqual(updated.reusedCount, 21)
        XCTAssertLessThan(updated.examinedCount, initial.examinedCount)
        XCTAssertEqual(updated.logicalBytes, 2_140_000)
        XCTAssertEqual(updated.refreshedFolderCount, 2)
        let unchanged = try StorageMapper.refresh(updated, changedPaths: [])
        XCTAssertEqual(unchanged.examinedCount, 0)
        XCTAssertEqual(unchanged.logicalBytes, updated.logicalBytes)
        let full = try StorageMapper.refresh(unchanged, changedPaths: [], forceFull: true)
        XCTAssertFalse(full.incremental)
        XCTAssertEqual(full.logicalBytes, updated.logicalBytes)
        XCTAssertEqual(full.examinedCount, initial.examinedCount)
    }
    func testRefreshHandlesRenamesDeletionAndCrossFolderHardlinks() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try write(root, "A/shared.bin", bytes: 1_500_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        let other = root.appendingPathComponent("B/shared.bin")
        try FileManager.default.linkItem(at: original, to: other)
        let first = try StorageMapper.scan(root: root)
        XCTAssertEqual(first.logicalBytes, 1_500_000)
        try FileManager.default.removeItem(at: original)
        let second = try StorageMapper.refresh(first, changedPaths: [original])
        XCTAssertEqual(second.bytes, first.bytes)
        XCTAssertEqual(second.logicalBytes, first.logicalBytes)
        XCTAssertEqual(second.largestFiles.count, 1)
        XCTAssertEqual(second.largestFiles.first?.url.path, other.path)
        let renamed = root.appendingPathComponent("C")
        try FileManager.default.moveItem(at: root.appendingPathComponent("B"), to: renamed)
        let third = try StorageMapper.refresh(second, changedPaths: [root.appendingPathComponent("B"), renamed])
        XCTAssertEqual(third.logicalBytes, 1_500_000)
        XCTAssertTrue(third.largestFiles.first?.url.path.hasPrefix(renamed.path + "/") == true)
        XCTAssertFalse(third.entries.contains { $0.url.lastPathComponent == "B" })
        try FileManager.default.removeItem(at: renamed)
        let fourth = try StorageMapper.refresh(third, changedPaths: [renamed])
        XCTAssertEqual(fourth.bytes, 0)
        XCTAssertEqual(fourth.logicalBytes, 0)
        XCTAssertTrue(fourth.largestFiles.isEmpty)
    }
    func testRefreshOfPartialMapDoesNotReuseIncompleteCache() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 { _ = try write(root, "\(i).bin", bytes: 1000) }
        let initial = try StorageMapper.scan(root: root, maximumEntries: 1)
        let full = try StorageMapper.refresh(initial, changedPaths: [], maximumEntries: 100)
        XCTAssertFalse(full.incremental)
        XCTAssertFalse(full.limited)
        XCTAssertEqual(full.logicalBytes, 5000)
    }
    func testReplacingCachedFileWithSymlinkDropsItsOldSize() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try location(); defer { try? FileManager.default.removeItem(at: outside) }
        let original = try write(root, "entry.bin", bytes: 1_500_000)
        let destination = try write(outside, "outside.bin", bytes: 3_000_000)
        let first = try StorageMapper.scan(root: root)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: destination)
        let updated = try StorageMapper.refresh(first, changedPaths: [original])
        XCTAssertEqual(updated.bytes, 0)
        XCTAssertEqual(updated.logicalBytes, 0)
        XCTAssertTrue(updated.largestFiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
    func testRecursiveMonitorReportsNestedFileChanges() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "folder/nested/file.bin", bytes: 1000)
        let received = expectation(description: "recursive filesystem event")
        received.assertForOverFulfill = false
        let monitor = FolderChangeMonitor(root: root) { paths, _ in
            if paths.contains(where: { $0.path.contains("folder/nested") }) { received.fulfill() }
        }
        guard monitor.available else { throw XCTSkip("Filesystem notifications unavailable") }
        try await Task.sleep(for: .milliseconds(200))
        try Data(repeating: 66, count: 2000).write(to: file)
        await fulfillment(of: [received], timeout: 8)
        withExtendedLifetime(monitor) { }
    }
}
