import XCTest
@testable import MacStewardCore

final class CareToolsTests: XCTestCase {
    func testOnlyARealAppCanBecomeALoginItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Good.app"), contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        let script = root.appendingPathComponent("evil.command"); try Data("x".utf8).write(to: script)
        let fake = root.appendingPathComponent("Fake.app"); try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Link.app"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertTrue(LoginItems.isApp(app))
        XCTAssertFalse(LoginItems.isApp(script))
        XCTAssertFalse(LoginItems.isApp(fake))
        XCTAssertFalse(LoginItems.isApp(link))
        XCTAssertThrowsError(try LoginItems.add(script))
        // The path is only ever an argument, so a strange name can't become script text.
        XCTAssertFalse(LoginItems.addScript.contains(root.path))
        XCTAssertEqual(LoginItems.scriptArguments(LoginItems.addScript, argument: "/tmp/-e do shell script.app").suffix(2), ["--", "/tmp/-e do shell script.app"])
    }
    func testLeftoversGroupByMakerAndKeepMaybeSharedApart() {
        func item(_ id: String, _ bytes: UInt64, shared: Bool = false) -> LeftoverItem {
            LeftoverItem(url: URL(fileURLWithPath: "/tmp/" + id), bundleID: id, kind: "Web data", bytes: bytes, modified: Date(), vendorInstalled: shared)
        }
        let apps = AppLeftovers.grouped([item("com.adobe.a", 5, shared: true), item("com.adobe.b", 7, shared: true), item("com.hnc.Discord", 3), item("fr.madrau.switchresx.daemon", 1), item("com.parallels.desktop.console", 2), item("plain", 1)])
        XCTAssertEqual(apps.first?.name, "Adobe")
        XCTAssertEqual(apps.first?.bytes, 12)
        XCTAssertEqual(apps.first?.shared, true)
        XCTAssertEqual(apps.first?.items.count, 2)
        XCTAssertEqual(Set(apps.map(\.name)), ["Adobe", "Discord", "Madrau", "Parallels", "Plain"])
        XCTAssertEqual(apps.filter(\.shared).count, 1)
    }
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }
    @discardableResult private func make(_ relative: String, age days: Double = 60) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testOnlyReverseDNSNamesCountAsAppIdentifiers() {
        XCTAssertEqual(AppLeftovers.bundleID("com.vendor.App.plist"), "com.vendor.App")
        XCTAssertEqual(AppLeftovers.bundleID("org.example.tool.savedState"), "org.example.tool")
        XCTAssertNil(AppLeftovers.bundleID("My Project"))
        XCTAssertNil(AppLeftovers.bundleID("Google"))
        XCTAssertNil(AppLeftovers.bundleID("notes.backup.txt"))
    }
    func testLeftoversSkipInstalledRelatedRecentAndAppleEntries() throws {
        try make("Library/Preferences/com.gone.App.plist")
        try make("Library/Caches/com.vendor.Removed")
        try make("Library/Preferences/com.kept.App.plist")
        try make("Library/Application Support/com.kept.App.helper")
        try make("Library/Preferences/com.apple.finder.plist")
        try make("Library/Preferences/com.fresh.App.plist", age: 2)
        try make("Library/Application Support/Google")
        try make("Library/Preferences/com.segment.storage.oai.plist")
        try make("Library/Preferences/org.sparkle-project.Sparkle.Autoupdate.plist")
        let found = AppLeftovers.scan(home: home, installed: ["com.kept.app", "com.vendor.stillhere"], registered: { _ in false })
        XCTAssertEqual(Set(found.map(\.bundleID)), ["com.gone.App", "com.vendor.Removed"])
        XCTAssertFalse(found.first { $0.bundleID == "com.gone.App" }!.vendorInstalled)
        XCTAssertTrue(found.first { $0.bundleID == "com.vendor.Removed" }!.vendorInstalled, "same vendor still installed")
    }
    func testTrashReviewAllowsLeftoversOnlyDirectlyInsideSearchedLibraryFolders() throws {
        let leftover = try make("Library/Preferences/com.gone.App.plist")
        let nested = try make("Library/Application Support/Vendor/com.gone.App")
        let library = home.appendingPathComponent("Library/Preferences")
        XCTAssertFalse(ReviewedTrash.allowed(leftover, home: home, allowApplication: false), "Library stays protected by default")
        XCTAssertTrue(ReviewedTrash.allowed(leftover, home: home, allowApplication: false, allowLeftover: true))
        XCTAssertFalse(ReviewedTrash.allowed(nested, home: home, allowApplication: false, allowLeftover: true))
        XCTAssertFalse(ReviewedTrash.allowed(library, home: home, allowApplication: false, allowLeftover: true))
    }
}

final class StorageKindTests: XCTestCase {
    func testSpaceMapTotalsKindsAndCountsHardLinksOnce() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("clips"), withIntermediateDirectories: true)
        let video = root.appendingPathComponent("clips/a.mov")
        try Data(repeating: 1, count: 200_000).write(to: video)
        try FileManager.default.linkItem(at: video, to: root.appendingPathComponent("b.mov"))
        try Data(repeating: 2, count: 50_000).write(to: root.appendingPathComponent("photo.JPG"))
        let kinds = try StorageMapper.scan(root: root).kinds
        XCTAssertEqual(kinds.first { $0.name == "Videos" }?.files, 1)
        XCTAssertEqual(kinds.first { $0.name == "Images" }?.files, 1)
        XCTAssertEqual(StorageKind.classify("/x/archive.tar"), "Archives")
        XCTAssertEqual(StorageKind.classify("/x/unknown.zzz"), "Other")
    }
}

final class InactiveDependenciesTests: XCTestCase {
    private let identity = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    private func project() throws -> URL {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString + "/app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        for (name, text) in [("package.json", "{}"), ("package-lock.json", "{}"), (".gitignore", "node_modules\n")] { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        XCTAssertEqual(git(root, ["init"]).code, 0)
        XCTAssertEqual(git(root, ["add", "."]).code, 0)
        XCTAssertEqual(git(root, identity + ["commit", "-m", "init"]).code, 0)
        return root
    }
    func testOnlyLockedDependencyFoldersQualify() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertTrue(ProjectActivity.dependencyFolder(root.appendingPathComponent("node_modules")))
        XCTAssertFalse(ProjectActivity.dependencyFolder(root.appendingPathComponent("dist")))
        try FileManager.default.removeItem(at: root.appendingPathComponent("package-lock.json"))
        XCTAssertFalse(ProjectActivity.dependencyFolder(root.appendingPathComponent("node_modules")), "no lockfile, no exact reinstall")
    }
    func testRecentCommitsEditsAndOpenFilesKeepTheProjectBusy() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let later = Date().addingTimeInterval(60 * 86400)
        XCTAssertNotNil(ProjectActivity.busyReason(root, activity: ActivitySnapshot(), sessions: AgentSessionIndex()), "committed today")
        XCTAssertNil(ProjectActivity.busyReason(root, activity: ActivitySnapshot(), sessions: AgentSessionIndex(), now: later))
        XCTAssertNotNil(ProjectActivity.busyReason(root, activity: ActivitySnapshot(openPaths: [root.path + "/package.json"]), sessions: AgentSessionIndex(), now: later))
        try Data("{\"edited\":1}".utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertNotNil(ProjectActivity.busyReason(root, activity: ActivitySnapshot(), sessions: AgentSessionIndex(), now: later), "uncommitted change")
    }
    func testDependencyRemovalUnlinksSymlinksWithoutTouchingTheirTargets() throws {
        let root = try project(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("shared-store")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("precious.txt"))
        let modules = root.appendingPathComponent("node_modules")
        try FileManager.default.createSymbolicLink(at: modules.appendingPathComponent("linked-package"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: modules.appendingPathComponent(".bin/tool"), withDestinationURL: outside.appendingPathComponent("precious.txt"))
        try Data("test cert".utf8).write(to: modules.appendingPathComponent("fixture.pem"))
        XCTAssertThrowsError(try TreeInventory.read(modules), "cache rules still refuse symlinks and certificates")
        let tree = try TreeInventory.read(modules, dependencies: true)
        try SecureRemoval.remove(modules, tree: tree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modules.path))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("precious.txt"), encoding: .utf8), "keep")
    }
}

final class AgentVersionTests: XCTestCase {
    func testOnlyOlderVersionsAreCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2.1.9", "2.1.10", "2.1.309", "notes"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        XCTAssertEqual(Set(DeveloperJunk.oldAgentVersions(in: root).map(\.lastPathComponent)), ["2.1.9", "2.1.10"], "numeric order, newest kept, non-versions ignored")
        try FileManager.default.removeItem(at: root.appendingPathComponent("2.1.9")); try FileManager.default.removeItem(at: root.appendingPathComponent("2.1.10"))
        XCTAssertTrue(DeveloperJunk.oldAgentVersions(in: root).isEmpty, "a single version is never a candidate")
    }
}

final class StorageNavigationTests: XCTestCase {
    func testSubfolderMapIsBuiltFromTheEnclosingMapWithoutRereading() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 {
            let folder = root.appendingPathComponent("child/f\(index % 4)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 20_000).write(to: folder.appendingPathComponent("\(index).bin"))
        }
        let parent = try StorageMapper.scan(root: root)
        let child = try StorageMapper.refresh(parent, root: root.appendingPathComponent("child"), changedPaths: [])
        XCTAssertEqual(child.root.lastPathComponent, "child")
        XCTAssertEqual(child.entries.count, 4)
        XCTAssertEqual(child.bytes, parent.bytes)
        XCTAssertGreaterThan(child.reusedCount, 40, "subtrees come from the parent's cache")
        XCTAssertLessThan(child.examinedCount, 10, "only the new top level is listed")
    }
}

final class BroadCacheTests: XCTestCase {
    func testSystemBrowserAndPersistentCachesAreNeverCandidates() {
        XCTAssertTrue(BroadCaches.allowedAppCache("com.spotify.client"))
        XCTAssertTrue(BroadCaches.allowedAppCache("Adobe"))
        for name in ["com.apple.Safari", "CloudKit", "Arc", "Google", "ms-playwright", "pypoetry", ".DS_Store", "local.macsteward.app", "com.vasquezgroup.artifloam"] { XCTAssertFalse(BroadCaches.allowedAppCache(name), name) }
    }
    func testOwnerMatchingByBundleIdentifierAndName() {
        let running = [(id: "com.spotify.client", name: "Spotify"), (id: "com.readdle.SparkDesktop", name: "Spark Mail")]
        XCTAssertTrue(BroadCaches.ownerRunning("com.spotify.client", running: running))
        XCTAssertTrue(BroadCaches.ownerRunning("Spark Mail", running: running))
        XCTAssertTrue(BroadCaches.ownerRunning("com.spotify.client.helper", running: running))
        XCTAssertFalse(BroadCaches.ownerRunning("com.adobe.InDesign", running: running))
    }
    func testOnlySimulatorAssetAndCacheFoldersQualify() {
        let home = URL(fileURLWithPath: "/Users/someone"), device = "/Users/someone/Library/Developer/CoreSimulator/Devices/\(UUID().uuidString)/data"
        XCTAssertTrue(BroadCaches.validSimulatorPath(URL(fileURLWithPath: device + "/private/var/MobileAsset/AssetsV2"), home: home))
        XCTAssertTrue(BroadCaches.validSimulatorPath(URL(fileURLWithPath: device + "/Library/Caches"), home: home))
        XCTAssertFalse(BroadCaches.validSimulatorPath(URL(fileURLWithPath: device + "/Containers"), home: home), "app data stays")
        XCTAssertFalse(BroadCaches.validSimulatorPath(URL(fileURLWithPath: "/Users/someone/Library/Developer/CoreSimulator/Devices/not-a-uuid/data/Library/Caches"), home: home))
    }
}

final class CleanProgressTests: XCTestCase {
    func testStoppingLeavesRemainingItemsUntouchedAndReportsProgress() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let files = try (0..<3).map { index -> URL in
            let url = home.appendingPathComponent("Library/Caches/com.example.app\(index)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("blob"))
            return url
        }
        let findings = files.map { Finding(path: $0.path, group: .userCaches, bytes: 1, modifiedAt: Date(), safety: .automatic, reason: "fixture", rule: "app-cache", fingerprint: "x") }
        let report = ScanReport(home: home.path, findings: findings)
        let config = Configuration(home: home, includeApplicationCaches: true, projectRoots: [])
        final class Box: @unchecked Sendable { var updates = [CleanProgress]() }
        let box = Box()
        let task = Task.detached { try Cleaner(configuration: config).clean(report, selectedIDs: Set(findings.map(\.id)), activityOverride: ActivitySnapshot()) { box.updates.append($0) } }
        task.cancel()
        let receipt = try await task.value
        XCTAssertEqual(receipt.removedCount, 0)
        XCTAssertTrue(receipt.items.allSatisfy { $0.outcome == "skipped" })
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "nothing removed after Stop")
        XCTAssertLessThanOrEqual(box.updates.count, 1)
    }
}
