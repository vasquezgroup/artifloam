import XCTest
@testable import MacStewardCore

final class SafetyTests: XCTestCase {
    var home: URL!
    var config: Configuration!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steward-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        config = Configuration(home: home)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }
    func cache(payload: String = "original") throws -> URL {
        let repo = config.projects.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(git(repo, ["init", "-b", "main"]).code, 0)
        try Data(".next/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        let path = repo.appendingPathComponent(".next/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: path.appendingPathComponent("generated.bin"))
        try age(path)
        return path
    }
    func age(_ root: URL) throws {
        let date = Date().addingTimeInterval(-10*86400)
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let file as URL in files { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }
    func finding(_ path: URL, safety: Safety = .automatic) throws -> Finding {
        let tree = try TreeInventory.read(path)
        return Finding(path: path.path, group: .projectCaches, bytes: tree.bytes, modifiedAt: tree.newest, safety: safety, reason: "fixture", rule: "framework-cache", fingerprint: tree.fingerprint)
    }
    func testDeletesOnlyAnUnchangedOldIgnoredCache() throws {
        let path = try cache(); let item = try finding(path)
        XCTAssertEqual(Set(try TreeInventory.read(path).nodes.keys), ["", "generated.bin"])
        let receipt = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [item]), selectedIDs: [item.id], activityOverride: ActivitySnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), receipt.items.map(\.detail).joined(separator: "; ")); XCTAssertEqual(receipt.removedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".gitignore").path))
    }
    func testModifiedAfterScanIsKept() throws {
        let path = try cache(); let item = try finding(path)
        try Data("new unfinished source".utf8).write(to: path.appendingPathComponent("generated.bin")); try age(path)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(item, activity: ActivitySnapshot()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testTrackedFileIsKeptEvenIfIgnored() throws {
        let path = try cache(); let repo = path.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(git(repo, ["add", "-f", ".next/cache/generated.bin"]).code, 0)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(try finding(path), activity: ActivitySnapshot()))
    }
    func testUntrackedButNotIgnoredIsKept() throws {
        let path = try cache(); let ignore = path.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".gitignore")
        try Data().write(to: ignore)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(try finding(path), activity: ActivitySnapshot()))
    }
    func testSymlinkToOriginalDataIsNeverFollowed() throws {
        let path = try cache(); let original = home.appendingPathComponent("original.txt"); try Data("precious".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("linked"), withDestinationURL: original)
        XCTAssertThrowsError(try TreeInventory.read(path)); XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "precious")
    }
    func testSymlinkedAncestorIsBlocked() throws {
        let outside = home.appendingPathComponent("outside", isDirectory: true); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config.projects.appendingPathComponent("linked"), withDestinationURL: outside)
        let path = config.projects.appendingPathComponent("linked/.next/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(path, rule: "framework-cache"))
    }
    func testRecentCacheIsKept() throws {
        let path = try cache(); try Data("recent".utf8).write(to: path.appendingPathComponent("recent.bin"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(try finding(path), activity: ActivitySnapshot()))
    }
    func testOpenFilesAndIncompleteProcessInspectionBlockDeletion() throws {
        let path = try cache(); let item = try finding(path)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(item, activity: ActivitySnapshot(openPaths: [path.appendingPathComponent("generated.bin").path])))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(item, activity: ActivitySnapshot(reliable: false)))
    }
    func testDatabaseAndCredentialsAreProtectedInsideCache() throws {
        for name in ["state.sqlite", ".env", "signing.p12", "credentials.json"] {
            let path = try cache(); let file = path.appendingPathComponent(name); try Data("private".utf8).write(to: file)
            XCTAssertThrowsError(try TreeInventory.read(path)); try FileManager.default.removeItem(at: file)
        }
    }
    func testUnknownRuleAndOutsideLocationAreBlocked() throws {
        let path = try cache()
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(path, rule: "delete-anything"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(home, rule: "framework-cache"))
    }
    func testIgnoreListAndReviewOnlyItemsAreProtected() throws {
        let path = try cache(); var ignored = config!; ignored.ignoredPaths = [path.deletingLastPathComponent().path]
        XCTAssertThrowsError(try SafetyPolicy(configuration: ignored).validate(try finding(path), activity: ActivitySnapshot()))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(try finding(path, safety: .review), activity: ActivitySnapshot()))
    }
    func testDirectorySwappedAfterValidationIsKept() throws {
        let path = try cache(); let tree = try TreeInventory.read(path)
        try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("new unique work".utf8).write(to: path.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try SecureRemoval.remove(path, tree: tree)); XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("keep.txt").path))
    }
    func testNewFileAfterValidationStopsAndPreservesNewFile() throws {
        let path = try cache(); let tree = try TreeInventory.read(path)
        try Data("new unique work".utf8).write(to: path.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try SecureRemoval.remove(path, tree: tree)); XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("keep.txt").path))
    }
    func testMinimumAgeCannotBeLoweredBelowSevenDays() { XCTAssertEqual(Configuration(home: home, minimumAgeDays: 0).minimumAgeDays, 7) }
    func testDuplicateAuditUsesContentNotNames() throws {
        let folder = home.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data(repeating: 65, count: 1_000_001)
        try data.write(to: folder.appendingPathComponent("a.bin")); try data.write(to: folder.appendingPathComponent("different-name.bin"))
        try Data(repeating: 66, count: 1_000_001).write(to: folder.appendingPathComponent("same-size.bin"))
        let result = try DuplicateFinder.scan(home: home); XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.files.count, 2)
    }
    func testSymlinkSwapAfterValidationPreservesOriginal() throws {
        let path = try cache(); let tree = try TreeInventory.read(path)
        let original = home.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: original.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        XCTAssertThrowsError(try SecureRemoval.remove(path, tree: tree))
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("keep.txt"), encoding: .utf8), "precious")
    }
    func testForeignHomePlanIsRejectedBeforeMutation() throws {
        let path = try cache(); let item = try finding(path)
        XCTAssertThrowsError(try Cleaner(configuration: config).clean(ScanReport(home: home.path + "-other", findings: [item]), selectedIDs: [item.id], activityOverride: ActivitySnapshot()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testDirectoryNamedLikeCacheWithoutProducerEvidenceIsBlocked() throws {
        config.agentTemp = home.appendingPathComponent("agent-temp", isDirectory: true)
        let path = config.agentTemp.appendingPathComponent("session/scratchpad/random/ModuleCache.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(path, rule: "agent-xcode-intermediates"))
    }
    func testExpiredPlanIsRejected() throws {
        let path = try cache(); let item = try finding(path)
        let data = try JSONEncoder().encode(ScanReport(home: home.path, findings: [item]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["createdAt"] = Date().addingTimeInterval(-4000).timeIntervalSinceReferenceDate
        let report = try JSONDecoder().decode(ScanReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try Cleaner(configuration: config).clean(report, selectedIDs: [item.id], activityOverride: ActivitySnapshot()))
    }

    func testUnrecognisedUserLogIsNeverAnAutomaticTarget() throws {
        let log = home.appendingPathComponent("Library/Logs/MyOriginal.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unique notes".utf8).write(to: log)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(log, rule: "old-user-log"))
    }

    func testCancellingScanStopsItsOwnReadOnlySubprocess() async throws {
        let started = Date()
        let work = Task.detached { MacStewardCore.run("/bin/sleep", ["10"], timeout: 12) }
        try await Task.sleep(nanoseconds: 150_000_000)
        work.cancel()
        let result = await work.value
        XCTAssertEqual(result.code, 130)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Cancellation must not wait for the subprocess timeout")
    }

}
