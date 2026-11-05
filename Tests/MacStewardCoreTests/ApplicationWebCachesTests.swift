import XCTest
@testable import MacStewardCore

final class ApplicationWebCachesTests: XCTestCase {
    private func fixture() throws -> (URL, URL, Configuration, Finding) {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/entry_0")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_100_000).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: file.path)
        let tree = try TreeInventory.read(file)
        let item = Finding(path: file.path, group: .userCaches, bytes: tree.bytes, modifiedAt: tree.newest, safety: .automatic, reason: "fixture cache", rule: "application-web-cache", fingerprint: tree.fingerprint)
        return (home, file, Configuration(home: home, includeApplicationCaches: true, projectRoots: []), item)
    }
    func testOrdinaryUserCacheCanBeCleanedWithoutDeveloperToolsOrProjectSetup() throws {
        let (home, file, config, item) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let cookies = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cookies")
        try Data("personal data fixture".utf8).write(to: cookies)
        let receipt = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [item]), selectedIDs: [item.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(receipt.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: cookies, encoding: .utf8), "personal data fixture")
    }
    func testOpenProducerAndUnreliableActivityBlockCacheRemoval() throws {
        let (home, _, config, item) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(item, activity: ActivitySnapshot(commands: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(item, activity: ActivitySnapshot(reliable: false)))
    }
    func testRecentCacheCleansOnlyWhenTheUserApprovesIt() throws {
        let (home, file, config, old) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let recent = Finding(path: old.path, group: .userCaches, bytes: old.bytes, modifiedAt: Date(), safety: .protected, reason: "used today", rule: old.rule, fingerprint: old.fingerprint, hold: .recent)
        XCTAssertTrue(recent.userCleanable)
        let unapproved = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [recent]), selectedIDs: [recent.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(unapproved.removedCount, 0, "a held item is never cleaned without the user's approval")
        let approved = try Cleaner(configuration: config).clean(ScanReport(home: home.path, findings: [recent]), selectedIDs: [recent.id], approvedIDs: [recent.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(approved.removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testApprovalNeverOverridesRunningProducersOrUnverifiedActivity() throws {
        let (home, _, config, old) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let recent = Finding(path: old.path, group: .userCaches, bytes: old.bytes, modifiedAt: Date(), safety: .protected, reason: "in use", rule: old.rule, fingerprint: old.fingerprint, hold: .recent)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(recent, activity: ActivitySnapshot(commands: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), approved: true))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(recent, activity: ActivitySnapshot(reliable: false), approved: true))
        let unknownOwner = Finding(path: old.path, group: .userCaches, bytes: old.bytes, modifiedAt: Date(), safety: .protected, reason: "in use", rule: old.rule, fingerprint: old.fingerprint, hold: .inUse)
        XCTAssertFalse(unknownOwner.userCleanable, "an in-use cache without a known app to quit stays locked")
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validate(unknownOwner, activity: ActivitySnapshot(), approved: true))
        XCTAssertTrue(BroadCaches.owns(cache: "com.spark.mail", bundleID: "com.spark.mail", appName: "Spark"))
        XCTAssertFalse(BroadCaches.owns(cache: "com.other.app", bundleID: "com.spark.mail", appName: "Spark"))
    }
    func testCacheIndexesDirectoriesAndPersonalDataNeverBecomeTargets() throws {
        let (home, file, config, _) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let cache = file.deletingLastPathComponent()
        for name in ["index", "index-dir", "cache.lock"] {
            let url = cache.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(url, rule: "application-web-cache"))
        }
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(cache, rule: "application-web-cache"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(cache.deletingLastPathComponent().appendingPathComponent("Cookies"), rule: "application-web-cache"))
    }
    func testDisabledApplicationCacheOptionRemainsRespected() throws {
        let (home, file, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try SafetyPolicy(configuration: Configuration(home: home, projectRoots: [])).validatePath(file, rule: "application-web-cache"))
    }
}
