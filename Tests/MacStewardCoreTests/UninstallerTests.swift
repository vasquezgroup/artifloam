import XCTest
@testable import MacStewardCore

final class UninstallerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func app(_ relative: String, id: String) throws -> URL {
        let url = try folder(relative)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": "x"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testOnlyFixedLocationsAndNeverASymlinkOrThePersonsFiles() throws {
        let support = try folder("Library/Application Support/MacSteward")
        let cache = try folder("Library/Caches/com.vasquezgroup.artifloam")
        let personal = try folder("Documents/MacSteward")
        let elsewhere = try folder("Documents/Precious")
        // A link planted at a fixed location must not get its target removed or listed.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/WebKit"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Library/WebKit/local.macsteward.app"), withDestinationURL: elsewhere)
        let paths = Set(Uninstaller.items(home: root).map(\.url.path))
        XCTAssertEqual(paths, [support.path, cache.path])
        XCTAssertFalse(paths.contains(personal.path))
    }
    func testOnlyAnInstalledArtifloamCanBeRemoved() throws {
        XCTAssertTrue(Uninstaller.removableApp(try app("Applications/Artifloam.app", id: "com.vasquezgroup.artifloam"), home: root))
        XCTAssertFalse(Uninstaller.removableApp(try app("Downloads/Artifloam.app", id: "com.vasquezgroup.artifloam"), home: root), "not installed, such as a build folder")
        XCTAssertFalse(Uninstaller.removableApp(try app("Applications/Other.app", id: "com.vasquezgroup.artifloam"), home: root))
        XCTAssertFalse(Uninstaller.removableApp(try app("other/Applications/Artifloam.app", id: "com.someone.else"), home: root.appendingPathComponent("other")), "an app of the same name made by someone else")
    }
    func testAppGoesLastAndAFailureIsReportedWithoutStoppingTheRest() throws {
        final class Log: @unchecked Sendable { var calls = [String]() }
        let log = Log(), app = root.appendingPathComponent("Artifloam.app"), data = root.appendingPathComponent("data")
        var actions = Uninstaller.Actions()
        actions.stopSchedule = { log.calls.append("schedule") }
        actions.resetPermissions = { log.calls.append("permissions") }
        actions.clearSettings = { log.calls.append("settings") }
        actions.trash = { url in log.calls.append(url.lastPathComponent); if url == data { throw CocoaError(.fileWriteNoPermission) } }
        let steps = Uninstaller.plan(items: [UninstallItem(title: "App data", url: data, bytes: 1)], app: app, actions: actions)
        let failures = steps.flatMap { $0.perform() }
        XCTAssertEqual(log.calls, ["schedule", "data", "permissions", "settings", "Artifloam.app"])
        XCTAssertEqual(failures.count, 1); XCTAssertTrue(failures[0].hasPrefix("App data"))
    }
    func testOneReadableProtectedFolderProvesFullDiskAccess() throws {
        XCTAssertEqual(FullDiskAccess.status(home: root), .unknown, "nothing to test against")
        let safari = try folder("Library/Safari")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }
        XCTAssertEqual(FullDiskAccess.status(home: root), .denied)
        _ = try folder("Library/Mail")
        XCTAssertEqual(FullDiskAccess.status(home: root), .granted, "one blocked folder must not hide access proven by another")
    }
    func testOldSettingsCarryOverOnceWithoutOverwriting() throws {
        let name = "test." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["/kept/new"], forKey: "projectRoots")
        StewardPreferences.migrate(from: ["projectRoots": ["/old"], "ignoredPaths": ["/keep"]], into: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "projectRoots"), ["/kept/new"])
        XCTAssertEqual(defaults.stringArray(forKey: "ignoredPaths"), ["/keep"])
        defaults.removeObject(forKey: "ignoredPaths")
        StewardPreferences.migrate(from: ["ignoredPaths": ["/keep"]], into: defaults)
        XCTAssertNil(defaults.stringArray(forKey: "ignoredPaths"), "a keep entry the person removed must not come back")
    }
}
