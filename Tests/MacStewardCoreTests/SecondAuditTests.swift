import XCTest
@testable import MacStewardCore

final class SecondAuditTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steward-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func file(_ relative: String, bytes: Int = 1_200_000, fill: UInt8 = 7, age: TimeInterval? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        if let age { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
        return url
    }

    // MARK: Processes
    func testChildProcessesDoNotInheritAnEnvironmentThatRedirectsBinaries() {
        setenv("DEVELOPER_DIR", "/tmp/fake-xcode", 1); setenv("GIT_EXEC_PATH", "/tmp/fake-git", 1); defer { unsetenv("DEVELOPER_DIR"); unsetenv("GIT_EXEC_PATH") }
        let output = MacStewardCore.run("/usr/bin/env", []).output
        XCTAssertFalse(output.contains("DEVELOPER_DIR")); XCTAssertFalse(output.contains("GIT_EXEC_PATH"))
        XCTAssertTrue(output.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
    }
    func testLoginItemNameCannotBecomeAppleScript() throws {
        let marker = root.appendingPathComponent("INJECTED")
        let hostile = "-eproperty p : (do shell script \"touch \(marker.path)\")"
        let result = MacStewardCore.run("/usr/bin/osascript", LoginItems.scriptArguments("on run argv\nreturn item 1 of argv\nend run", argument: hostile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), hostile, "the name arrives as plain data")
    }
    func testHomebrewCacheIsAnExactRuleAndRunsNothing() throws {
        let cache = root.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let policy = SafetyPolicy(configuration: Configuration(home: root, includeDeveloperCaches: true))
        XCTAssertNoThrow(try policy.validatePath(cache, rule: "homebrew-cache"))
        XCTAssertThrowsError(try policy.validatePath(root.appendingPathComponent("Library/Caches"), rule: "homebrew-cache"))
    }

    // MARK: Browser
    func testBrowserDataInUseIsNotRemoved() throws {
        guard let browser = BrowserData.chromium.first(where: { !BrowserData.isRunning($0.bundleID) }) else { throw XCTSkip("Every browser is running") }
        let cache = root.appendingPathComponent("Library/Application Support/\(browser.support)/Default/GPUCache")
        _ = try file("Library/Application Support/\(browser.support)/Default/GPUCache/data", bytes: 200_000)
        let open = ActivitySnapshot(openPaths: [cache.path + "/data"])
        let id = cache.path
        var result = BrowserData.clean([id], home: root, activity: open)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "skipped: \(result.skipped)")
        result = BrowserData.clean([id], home: root, activity: ActivitySnapshot())
        XCTAssertEqual(result.removed, [id]); XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testBrowserKeepListHolds() throws {
        guard let browser = BrowserData.chromium.first(where: { !BrowserData.isRunning($0.bundleID) }) else { throw XCTSkip("Every browser is running") }
        let cache = root.appendingPathComponent("Library/Application Support/\(browser.support)/Default/GPUCache")
        _ = try file("Library/Application Support/\(browser.support)/Default/GPUCache/data", bytes: 200_000)
        let result = BrowserData.clean([cache.path], home: root, activity: ActivitySnapshot(), ignoredPaths: [cache.deletingLastPathComponent().path])
        XCTAssertTrue(result.removed.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: Duplicates
    func testHardLinksAreOneFileAndCheckoutsAndEnvironmentsAreSkipped() throws {
        let a = try file("scan/a.bin")
        try FileManager.default.linkItem(at: a, to: root.appendingPathComponent("scan/link.bin"))
        XCTAssertTrue(try DuplicateFinder.scan(folder: root.appendingPathComponent("scan")).isEmpty, "a hard link is not a spare copy")
        _ = try file("scan/repo/.git/HEAD", bytes: 10); _ = try file("scan/repo/copy.bin")
        _ = try file("scan/venv/lib/copy.bin")
        XCTAssertTrue(try DuplicateFinder.scan(folder: root.appendingPathComponent("scan")).isEmpty)
        _ = try file("scan/real/copy.bin")
        XCTAssertEqual(try DuplicateFinder.scan(folder: root.appendingPathComponent("scan")).first?.files.count, 2)
    }
    func testUntrackedCopiesInACheckoutAreFoundButNeverTickedAndTrackedOnesNeverOffered() throws {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        let repo = root.appendingPathComponent("scan/project")
        let tracked = try file("scan/project/assets/tracked.bin", fill: 1)
        XCTAssertEqual(git(repo, ["init", "-b", "main"]).code, 0)
        XCTAssertEqual(git(repo, ["add", "assets/tracked.bin"]).code, 0)
        XCTAssertEqual(git(repo, ["-c", "user.name=F", "-c", "user.email=f@example.invalid", "commit", "-m", "i"]).code, 0)
        let untracked = try file("scan/project/notes/copy.bin", fill: 1), outside = try file("scan/outside.bin", fill: 1)
        var groups = try DuplicateFinder.scan(folder: root.appendingPathComponent("scan"))
        var group = try XCTUnwrap(groups.first)
        // The walk reports /private/var for the temporary folder, so these compare by name.
        func names(_ paths: [String]) -> Set<String> { Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }) }
        XCTAssertFalse(names(group.files).contains(tracked.lastPathComponent), "tracked files are never offered")
        XCTAssertEqual(names(group.files), [untracked.lastPathComponent, outside.lastPathComponent]); XCTAssertEqual(names(group.projectFiles), [untracked.lastPathComponent])
        var kept = DuplicateGroup.oldestCopies(groups)
        XCTAssertEqual(names([kept[group.id] ?? ""]), [untracked.lastPathComponent], "the project keeps its copy")
        XCTAssertEqual(names(Array(DuplicateGroup.extras(groups, keeping: kept))), [outside.lastPathComponent])
        XCTAssertEqual(group.potentialBytes, group.size)
        // Both copies inside the project: found, nothing ticked, nothing counted.
        try FileManager.default.moveItem(at: outside, to: repo.appendingPathComponent("notes/copy2.bin"))
        groups = try DuplicateFinder.scan(folder: root.appendingPathComponent("scan"))
        group = try XCTUnwrap(groups.first); kept = DuplicateGroup.oldestCopies(groups)
        XCTAssertEqual(group.projectFiles.count, 2); XCTAssertEqual(group.extraCount, 0); XCTAssertTrue(DuplicateGroup.extras(groups, keeping: kept).isEmpty)
    }
    func testOldHomebrewVersionsAreMeasuredWithoutRunningBrew() throws {
        let cellar = root.appendingPathComponent("Cellar")
        for path in ["git/2.9.0/bin", "git/2.10.0/bin", "pinned/1.0/bin", "pinned/2.0/bin", "single/1.0/bin"] { try FileManager.default.createDirectory(at: cellar.appendingPathComponent(path), withIntermediateDirectories: true) }
        _ = try file("var/homebrew/pinned/pinned", bytes: 1)
        XCTAssertEqual(BroadCaches.oldVersions(cellar: cellar).map { $0.path.replacingOccurrences(of: cellar.path + "/", with: "") }, ["git/2.9.0"], "numeric order; the newest and pinned formulae stay")
        XCTAssertEqual(BroadCaches.brewCleanupScript(cellar: "/opt/homebrew/Cellar")?.contains("/opt/homebrew/bin/brew cleanup --prune=30"), true)
        XCTAssertNil(BroadCaches.brewCleanupScript(cellar: "/tmp/evil; rm -rf ~/Cellar"), "only known locations reach the script")
    }
    func testAnUnreadableOrSpecialFileDoesNotStopTheSearch() throws {
        _ = try file("scan/a.bin"); _ = try file("scan/b.bin")
        let locked = try file("scan/locked.bin"); try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        XCTAssertEqual(mkfifo(root.appendingPathComponent("scan/pipe").path, 0o600), 0)
        XCTAssertEqual(try DuplicateFinder.scan(folder: root.appendingPathComponent("scan")).first?.files.count, 2)
        XCTAssertNil(try DuplicateFinder.hashed(root.appendingPathComponent("scan/pipe").path), "a FIFO neither hangs nor hashes")
    }
    func testRemovalRecheckKeepsTheLastCopy() throws {
        let a = try file("a.bin"), b = try file("b.bin")
        let hash = try XCTUnwrap(DuplicateFinder.hashed(a.path)).hash
        let group = DuplicateGroup(id: hash, files: [a.path, b.path], size: 1_200_000)
        XCTAssertEqual(try DuplicateFinder.stillSafeToTrash([b.path], in: [group]).paths, [b.path])
        // The kept copy was edited after the scan: b is now the only copy of that content.
        try Data(repeating: 9, count: 1_200_000).write(to: a)
        var result = try DuplicateFinder.stillSafeToTrash([b.path], in: [group])
        XCTAssertEqual(result.paths, []); XCTAssertEqual(result.dropped, 1)
        // The kept copy was replaced by a hard link to b: same bytes, but one file.
        try FileManager.default.removeItem(at: a); try FileManager.default.linkItem(at: b, to: a)
        result = try DuplicateFinder.stillSafeToTrash([b.path], in: [group])
        XCTAssertEqual(result.paths, [], "removing one of two links is not removing a spare copy")
        // The kept copy is gone.
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(try DuplicateFinder.stillSafeToTrash([b.path], in: [group]).paths, [])
        // The candidate itself was edited.
        let c = try file("c.bin"), d = try file("d.bin", fill: 8)
        let again = DuplicateGroup(id: hash, files: [c.path, d.path], size: 1_200_000)
        XCTAssertEqual(try DuplicateFinder.stillSafeToTrash([d.path], in: [again]).paths, [])
    }

    // MARK: Quit
    func testOnlyTheExactAppIsAskedToQuit() {
        XCTAssertTrue(BroadCaches.quitsFor(cache: "com.spotify.client", bundleID: "com.spotify.client", appName: "Spotify"))
        XCTAssertTrue(BroadCaches.quitsFor(cache: "com.spotify.client.helper", bundleID: "com.spotify.client", appName: "Spotify"))
        XCTAssertTrue(BroadCaches.quitsFor(cache: "Spotify", bundleID: "com.spotify.client", appName: "Spotify"))
        XCTAssertTrue(BroadCaches.quitsFor(cache: "Adobe", bundleID: "com.adobe.Photoshop", appName: "Adobe Photoshop 2026"), "a family named by whole word; the dialog lists each app")
        XCTAssertFalse(BroadCaches.quitsFor(cache: "Ado", bundleID: "com.adobe.Photoshop", appName: "Adobe Photoshop 2026"))
        for cache in ["com", "com.tinyspeck", "Slac", "Adobe"] { XCTAssertFalse(BroadCaches.quitsFor(cache: cache, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack Adobe"), cache) }
        XCTAssertTrue(BroadCaches.ownerRunning("com.tinyspeck", running: [("com.tinyspeck.slackmacgap", "Slack")]), "a loose match still keeps the cache as in use")
        XCTAssertNil(BroadCaches.owner(of: "com.tinyspeck", running: [("com.tinyspeck.slackmacgap", "Slack")]), "and offers nothing to quit")
        for name in ["com", "com.apple", "COM.apple.foo"] { XCTAssertFalse(BroadCaches.allowedAppCache(name), name) }
    }

    // MARK: Leftovers
    func testLeftoverWithRecentFilesDeepInsideOrOpenIsNotOffered() throws {
        let support = "Library/Application Support"
        let now = Date()
        _ = try file("\(support)/com.vendor.old/data/x", bytes: 10, age: 90 * 86_400)
        _ = try file("\(support)/com.vendor.live/data/y", bytes: 10)
        _ = try file("\(support)/com.vendor.open/data/z", bytes: 10, age: 90 * 86_400)
        for name in ["com.vendor.old", "com.vendor.old/data", "com.vendor.live", "com.vendor.open", "com.vendor.open/data"] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: root.appendingPathComponent("\(support)/\(name)").path)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: root.appendingPathComponent("\(support)/com.vendor.live").path)
        let open = root.appendingPathComponent("\(support)/com.vendor.open/data/z").path
        let found = AppLeftovers.scan(home: root, installed: [], activity: ActivitySnapshot(openPaths: [open]), registered: { _ in false }).map(\.bundleID)
        XCTAssertEqual(found, ["com.vendor.old"])
    }

    // MARK: Trash rules
    func testLeftoverNamedLikeAnAppCanBeReviewed() throws {
        let url = root.appendingPathComponent("Library/Application Support/com.vendor.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertTrue(ReviewedTrash.allowed(url, home: root, allowApplication: false, allowLeftover: true))
    }
    func testFilesInsidePackagesAreRefused() throws {
        let inside = try file("Documents/Thing.bundle/Contents/data", bytes: 10)
        let outside = try file("Documents/plain/data", bytes: 10)
        XCTAssertFalse(ReviewedTrash.allowed(inside, home: root, allowApplication: false))
        XCTAssertTrue(ReviewedTrash.allowed(outside, home: root, allowApplication: false))
    }
    func testProtectedFoldersIgnoreCase() throws {
        for path in ["LIBRARY/Preferences/x", "library/Keychains/x", ".SSH/id_rsa", ".Ssh/config"] {
            let url = try file(path, bytes: 1)
            XCTAssertFalse(ReviewedTrash.allowed(url, home: root, allowApplication: false), path)
        }
    }
    func testBundleIdentifierAloneDoesNotProtectAnApp() throws {
        XCTAssertTrue(AppleCode.signedByApple(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        let fake = root.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.fake"], format: .xml, options: 0).write(to: fake.appendingPathComponent("Contents/Info.plist"))
        XCTAssertFalse(AppleCode.isProtectedApp(fake, identifier: "com.apple.fake"))
        XCTAssertTrue(AppleCode.isProtectedApp(URL(fileURLWithPath: "/System/Applications/Calculator.app"), identifier: "com.apple.calculator"))
    }

    // MARK: Reads and display
    func testBoundedReadRefusesWhatWouldHang() throws {
        let pipe = root.appendingPathComponent("pipe"); XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertNil(BoundedFile.read(pipe))
        let link = root.appendingPathComponent("zero"); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
        XCTAssertNil(BoundedFile.read(link))
        XCTAssertNil(BoundedFile.read(try file("big", bytes: 2_000), limit: 1_000))
        XCTAssertEqual(BoundedFile.read(try file("small", bytes: 10))?.count, 10)
    }
    func testBoundedReadRefusesRedirectedParentAndNegativeLimit() throws {
        let source = try file("real/info.json", bytes: 10)
        let alias = root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
        XCTAssertNil(BoundedFile.read(alias.appendingPathComponent("info.json")))
        XCTAssertNil(BoundedFile.read(source, limit: -1))
        XCTAssertEqual(BoundedFile.read(source, limit: 10)?.count, 10)
    }
    func testDuplicateSubfolderKeepsTrackedFilesAndRechecksNewGitTracking() throws {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        let repo = root.appendingPathComponent("project")
        let tracked = try file("project/assets/tracked.bin")
        let a = try file("project/assets/a.bin"), b = try file("project/assets/b.bin")
        XCTAssertEqual(git(repo, ["init", "-b", "main"]).code, 0)
        XCTAssertEqual(git(repo, ["add", "assets/tracked.bin"]).code, 0)
        let groups = try DuplicateFinder.scan(folder: repo.appendingPathComponent("assets"))
        let group = try XCTUnwrap(groups.first)
        func names(_ paths: [String]) -> Set<String> { Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }) }
        XCTAssertEqual(names(group.files), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertEqual(names(group.projectFiles), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertFalse(names(group.files).contains(tracked.lastPathComponent))
        XCTAssertEqual(git(repo, ["add", "assets/b.bin"]).code, 0)
        XCTAssertTrue(try DuplicateFinder.stillSafeToTrash([b.path], in: groups).paths.isEmpty)
    }
    func testDuplicateTrashRechecksTheKeptCopyAfterReviewAndBetweenMoves() throws {
        let a = try file("Documents/a.bin"), b = try file("Documents/b.bin"), c = try file("Documents/c.bin")
        let hash = try XCTUnwrap(DuplicateFinder.hashed(a.path)).hash
        let group = DuplicateGroup(id: hash, files: [a.path, b.path, c.path], size: 1_200_000)
        let candidates = try ReviewedTrash.review([b, c], home: root)
        var calls = 0
        let results = ReviewedTrash.move(candidates, home: root, duplicateGroups: [group]) { url in
            calls += 1
            try FileManager.default.removeItem(at: url)
            try Data(repeating: 9, count: 1_200_000).write(to: a)
            return nil
        }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(results[0].error)
        XCTAssertNotNil(results[1].error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
    }
    func testUnavailableSimulatorCleanupRefusesUnknownActivity() {
        XCTAssertNil(SpaceKeeper.removeUnavailableSimulators(activity: ActivitySnapshot(reliable: false)))
    }
    func testKeepListedAndMalformedSimulatorsAreNotRemovable() {
        let kept = "11111111-1111-1111-1111-111111111111", other = "22222222-2222-2222-2222-222222222222"
        let keepPath = root.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(kept)").path
        XCTAssertEqual(SpaceKeeper.removable([kept, other, "--all", "../x"], home: root, ignoredPaths: [keepPath]), [other])
    }
    func testTrashEmptyRefusesRedirectedVolumeContainerWithoutTouchingItsTarget() throws {
        let home = root.appendingPathComponent("home"), volume = root.appendingPathComponent("volume"), kept = try file("kept/important", bytes: 10)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        XCTAssertNoThrow(try TrashBins.validateRoots(home: home, volumes: [volume]))
        try FileManager.default.createSymbolicLink(at: volume.appendingPathComponent(".Trashes"), withDestinationURL: kept.deletingLastPathComponent())
        XCTAssertThrowsError(try TrashBins.validateRoots(home: home, volumes: [volume]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }
    func testDisplayedNamesCannotFakeRowsOrExtensions() {
        XCTAssertEqual("report\u{202E}fdp.exe".displaySafe, "report\u{FFFD}fdp.exe")
        XCTAssertEqual("a\nb".displaySafe, "a\u{FFFD}b")
        XCTAssertEqual("Résumé 文档.pdf".displaySafe, "Résumé 文档.pdf")
    }
    func testSessionsMatchEitherFolderNameEncoding() {
        var index = AgentSessionIndex(); let date = Date()
        index.claude["-tmp-caf---x"] = date
        XCTAssertEqual(index.lastUsed(URL(fileURLWithPath: "/tmp/caf\u{0065}\u{0301}-x".replacingOccurrences(of: "e\u{0301}", with: "\u{1F600}"))), date, "an emoji is two UTF-16 units")
    }
}
