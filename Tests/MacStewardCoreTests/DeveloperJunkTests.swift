import XCTest
import Darwin
@testable import MacStewardCore

final class DeveloperJunkTests: XCTestCase {
    private func fixture() throws -> (URL, URL, Configuration) {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent(".gradle/caches/8.14.3/transforms/0123456789abcdef0123456789abcdef")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("transformed"), withIntermediateDirectories: true)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n# Gradle cache".utf8).write(to: home.appendingPathComponent(".gradle/caches/CACHEDIR.TAG"))
        try Data("generated".utf8).write(to: path.appendingPathComponent("transformed/output.jar"))
        var times = [timeval(tv_sec: Int(Date().addingTimeInterval(-40 * 86400).timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(Date().addingTimeInterval(-40 * 86400).timeIntervalSince1970), tv_usec: 0)]
        for url in [path.appendingPathComponent("transformed/output.jar"), path.appendingPathComponent("transformed"), path] { XCTAssertEqual(utimes(url.path, &times), 0) }
        return (home, path, Configuration(home: home, includeDeveloperCaches: true, includeAdditionalLogs: true))
    }
    private func finding(_ path: URL) throws -> Finding {
        let tree = try TreeInventory.read(path)
        return Finding(path: path.path, group: .developerCaches, bytes: tree.bytes, modifiedAt: tree.newest, safety: .automatic, reason: "fixture", rule: "gradle-generated-cache", fingerprint: tree.fingerprint)
    }
    func testOldGeneratedTransformCanBeCleanedWithoutTouchingDependencies() throws {
        let (home, path, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let dependency = home.appendingPathComponent(".gradle/caches/modules-2/keep.jar")
        try FileManager.default.createDirectory(at: dependency.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("downloaded dependency".utf8).write(to: dependency)
        let item = try finding(path)
        let receipt = try Cleaner(configuration: configuration).clean(ScanReport(home: home.path, findings: [item]), selectedIDs: [item.id], activityOverride: ActivitySnapshot())
        XCTAssertEqual(receipt.removedCount, 1, receipt.items.map(\.detail).joined())
        XCTAssertEqual(try String(contentsOf: dependency, encoding: .utf8), "downloaded dependency")
        XCTAssertTrue(DeveloperJunk.hasGradleMarker(home: home))
    }
    func testActiveGradleAndRecentlyAccessedArtifactsStayProtected() throws {
        let (home, path, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let item = try finding(path)
        XCTAssertThrowsError(try SafetyPolicy(configuration: configuration).validate(item, activity: ActivitySnapshot(commands: "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14.3")))
        let file = path.appendingPathComponent("transformed/output.jar")
        var times = [timeval(tv_sec: Int(Date().timeIntervalSince1970), tv_usec: 0), timeval(tv_sec: Int(Date().addingTimeInterval(-40 * 86400).timeIntervalSince1970), tv_usec: 0)]
        XCTAssertEqual(utimes(file.path, &times), 0)
        XCTAssertThrowsError(try SafetyPolicy(configuration: configuration).validate(try finding(path), activity: ActivitySnapshot()))
    }
    func testDependenciesConfigAndUnmarkedCachesCannotBecomeTargets() throws {
        let (home, path, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        for relative in [".gradle", ".gradle/gradle.properties", ".gradle/caches/modules-2/keep.jar", ".gradle/caches/8.14.3", ".gradle/caches/8.14.3/transforms/not-a-hash"] {
            XCTAssertThrowsError(try SafetyPolicy(configuration: configuration).validatePath(home.appendingPathComponent(relative), rule: "gradle-generated-cache"))
        }
        try Data("secret".utf8).write(to: path.appendingPathComponent("gradle.properties"))
        XCTAssertThrowsError(try TreeInventory.read(path))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".gradle/caches/CACHEDIR.TAG"))
        XCTAssertThrowsError(try SafetyPolicy(configuration: configuration).validatePath(path, rule: "gradle-generated-cache"))
    }
    func testKeptXcodeArchiveIsExcludedFromInventory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-01-01")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_100_000).write(to: archive.appendingPathComponent("archive.bin"))
        XCTAssertEqual(XcodeStorageInventory.inspect(home: home).findings.count, 1)
        XCTAssertTrue(XcodeStorageInventory.inspect(home: home, ignoredPaths: [archive.path]).findings.isEmpty)
    }
    func testXcodeFoldersCanBeTickedButFlaggedOnesAreNotBulkTicked() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let xcode = home.appendingPathComponent("Library/Developer/Xcode")
        let archive = xcode.appendingPathComponent("Archives/2026-01-01")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_100_000).write(to: archive.appendingPathComponent("archive.bin"))
        let row = try XCTUnwrap(XcodeStorageInventory.inspect(home: home).findings.first)
        XCTAssertTrue(row.userCleanable); XCTAssertFalse(row.tickable, "archives are flagged, so only ticked one by one")
        XCTAssertTrue(XcodeStorageInventory.trashable(archive, home: home))
        XCTAssertTrue(XcodeStorageInventory.trashable(xcode.appendingPathComponent("iOS DeviceSupport/iPhone 18.1"), home: home))
        XCTAssertTrue(XcodeStorageInventory.trashable(xcode.appendingPathComponent("DerivedData/App-abc/Build/Products"), home: home))
        XCTAssertTrue(XcodeStorageInventory.trashable(xcode.appendingPathComponent("DerivedData/App-abc/SourcePackages"), home: home))
        for path in ["Archives", "DerivedData", "DerivedData/App-abc", "DerivedData/App-abc/Build", "Archives/2026-01-01/App.xcarchive", "UserData"] {
            XCTAssertFalse(XcodeStorageInventory.trashable(xcode.appendingPathComponent(path), home: home), path)
        }
    }
    func testTrackedFilesInGlobalDeveloperCacheAreProtected() throws {
        let (home, path, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent(".gradle")
        XCTAssertEqual(git(repo, ["init"]).code, 0)
        try Data("caches/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        XCTAssertEqual(git(repo, ["add", "-f", "caches/8.14.3/transforms/0123456789abcdef0123456789abcdef/transformed/output.jar"]).code, 0)
        XCTAssertThrowsError(try SafetyPolicy(configuration: configuration).validatePath(path, rule: "gradle-generated-cache"))
    }
    func testNewDeveloperCleanupIsNotEnabledInScheduledConfiguration() throws {
        let (home, path, _) = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try SafetyPolicy(configuration: Configuration(home: home)).validatePath(path, rule: "gradle-generated-cache"))
    }
    func testLogAllowlistExcludesPreferencesDocumentsAndOtherLogs() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let policy = SafetyPolicy(configuration: Configuration(home: home, includeAdditionalLogs: true))
        for path in ["Library/Logs/NGL/NGLClient_Illustrator.log", "Library/Containers/com.microsoft.Word/Data/Library/Logs/Diagnostics/WORD/Primary123.log"] {
            XCTAssertNoThrow(try policy.validatePath(home.appendingPathComponent(path), rule: "old-user-log"))
        }
        for path in ["Library/Logs/NGL/NGLClient_config.ngllogcontrolconfig", "Library/Logs/MyOriginal.log", "Library/Containers/com.microsoft.Word/Data/Documents/Original.log"] {
            XCTAssertThrowsError(try policy.validatePath(home.appendingPathComponent(path), rule: "old-user-log"))
        }
    }
    func testXcodeManagedStorageIsNeverAnAutomaticTarget() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let policy = SafetyPolicy(configuration: Configuration(home: home, includeDeveloperCaches: true))
        for path in ["Library/Developer/Xcode/Archives/release.xcarchive", "Library/Developer/Xcode/iOS DeviceSupport/18.0", "Library/Developer/CoreSimulator/Devices/precious"] {
            XCTAssertThrowsError(try policy.validatePath(home.appendingPathComponent(path), rule: "xcode-managed-review"))
        }
    }
}
