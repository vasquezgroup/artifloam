import XCTest
@testable import MacStewardCore

final class PortabilityTests: XCTestCase {
    private var sandbox: URL!
    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("artifloam-portable-\(UUID())")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }
    private func cache(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(git(root, ["init", "-b", "main"]).code, 0)
        try Data(".next/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let cache = root.appendingPathComponent(".next/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("regenerable".utf8).write(to: cache.appendingPathComponent("entry"))
        return cache
    }
    func testIndependentProjectRootsOutsideHomeAreRecognised() throws {
        let a = sandbox.appendingPathComponent("volume-one/app")
        let b = sandbox.appendingPathComponent("volume-two/web")
        let paths = try [cache(in: a), cache(in: b)]
        let config = Configuration(home: sandbox.appendingPathComponent("different-user-home"), projectRoots: [a, b])
        let policy = SafetyPolicy(configuration: config)
        for path in paths { XCTAssertNoThrow(try policy.validatePath(path, rule: "framework-cache")) }
    }
    func testUnselectedSiblingRootCannotBeCleaned() throws {
        let selected = sandbox.appendingPathComponent("projects")
        let sibling = sandbox.appendingPathComponent("projects-other")
        _ = try cache(in: selected)
        let outside = try cache(in: sibling)
        let config = Configuration(home: sandbox, projectRoots: [selected])
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(outside, rule: "framework-cache"))
    }
    func testTrackedFileStillBlocksUserSelectedExternalRoot() throws {
        let root = sandbox.appendingPathComponent("external")
        let path = try cache(in: root)
        XCTAssertEqual(git(root, ["add", "-f", ".next/cache/entry"]).code, 0)
        let config = Configuration(home: sandbox.appendingPathComponent("home"), projectRoots: [root])
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(path, rule: "framework-cache"))
    }
    func testNoSelectedProjectRootsAllowsNoProjectCleanup() throws {
        let path = try cache(in: sandbox.appendingPathComponent("project"))
        let config = Configuration(home: sandbox, projectRoots: [])
        XCTAssertTrue(config.projectRoots.isEmpty)
        XCTAssertThrowsError(try SafetyPolicy(configuration: config).validatePath(path, rule: "framework-cache"))
    }
    func testToolHomesAreConfigurableWithoutSpecificUsername() {
        let home = sandbox.appendingPathComponent("another-user")
        let config = Configuration(home: home, claudeHome: sandbox.appendingPathComponent("claude-data"), codexHome: sandbox.appendingPathComponent("codex-data"))
        XCTAssertEqual(config.claudeHome, sandbox.appendingPathComponent("claude-data"))
        XCTAssertEqual(config.codexHome, sandbox.appendingPathComponent("codex-data"))
        XCTAssertEqual(Configuration(home: home).claudeHome, home.appendingPathComponent(".claude"))
        XCTAssertEqual(Configuration(home: home).codexHome, home.appendingPathComponent(".codex"))
    }
}
