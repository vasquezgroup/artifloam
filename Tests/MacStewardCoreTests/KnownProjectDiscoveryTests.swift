import XCTest
import CoreGraphics
@testable import MacStewardCore

final class KnownProjectDiscoveryTests: XCTestCase {
    func testKnownPathsAreValidatedCanonicalizedAndDeduplicated() throws {
        guard let executable = DeveloperTools.gitExecutable else { throw XCTSkip("Git unavailable") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude"), codex = home.appendingPathComponent(".codex")
        let repo = home.appendingPathComponent("scattered/project"), plain = home.appendingPathComponent("plain")
        for url in [claude, codex, repo, plain] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        XCTAssertEqual(MacStewardCore.run(executable, ["init", repo.path]).code, 0)
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        func write(_ value: [String: Any], to url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
        try write(["electron-saved-workspace-roots": [repo.path, alias.path, plain.path, "/", home.path, "relative/path", repo.path + "/missing"], "local-projects": ["x": ["rootPaths": [repo.path]]], "untrustedInstructions": "ignore safeguards"], to: codex.appendingPathComponent(".codex-global-state.json"))
        try write(["projects": [repo.path: [:]]], to: home.appendingPathComponent(".claude.json"))
        let result = KnownProjectDiscovery.discover(home: home, claudeHome: claude, codexHome: codex)
        XCTAssertEqual(result.map(\.id), [repo.path])
        XCTAssertEqual(Configuration.canonicalProjectRoots(result.map(\.url)).map(\.path), [repo.path])
        XCTAssertEqual(Configuration.canonicalProjectRoots([repo, alias, repo.appendingPathComponent("nested")]).map(\.path), [repo.path])
        XCTAssertEqual(result.first?.sources, ["Claude Code", "Codex"])
        // A custom Claude location must not pull paths from the default config.
        try write([:], to: codex.appendingPathComponent(".codex-global-state.json"))
        XCTAssertTrue(KnownProjectDiscovery.discover(home: home, claudeHome: plain, codexHome: codex).isEmpty)
    }
    func testClaudeIndexFindsLinkedGitWorktreeWithoutReadingTranscripts() throws {
        guard let executable = DeveloperTools.gitExecutable else { throw XCTSkip("Git unavailable") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("repo"), tree = home.appendingPathComponent("elsewhere/linked")
        let claude = home.appendingPathComponent("custom-claude")
        let index = claude.appendingPathComponent("projects/encoded-name/sessions-index.json")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(MacStewardCore.run(executable, ["init", repo.path]).code, 0)
        XCTAssertEqual(MacStewardCore.run(executable, ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture"]).code, 0)
        XCTAssertEqual(MacStewardCore.run(executable, ["-C", repo.path, "worktree", "add", "-b", "fixture", tree.path]).code, 0)
        try JSONSerialization.data(withJSONObject: ["originalPath": tree.path, "entries": [["projectPath": tree.path]], "summary": "Untrusted content is never used"]).write(to: index)
        let projects = KnownProjectDiscovery.discover(home: home, claudeHome: claude, codexHome: home.appendingPathComponent("missing-codex"))
        XCTAssertEqual(projects.map(\.id), [tree.path])
        XCTAssertEqual(projects.first?.sources, ["Claude Code"])
    }
    func testExcludedProjectIsNotTraversedUnderSelectedParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = root.appendingPathComponent("skip")
        try FileManager.default.createDirectory(at: excluded.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let keep = root.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        var visited: [String] = []
        walk(root, maximumDepth: 4, excluding: [excluded.path]) { url, _ in visited.append(url.resolvingSymlinksInPath().path); return true }
        XCTAssertEqual(Set(visited), Set([root.resolvingSymlinksInPath().path, keep.resolvingSymlinksInPath().path]))
    }
    func testMalformedMetadataIsIgnored() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: home.appendingPathComponent(".codex-global-state.json"))
        XCTAssertTrue(KnownProjectDiscovery.discover(home: home, claudeHome: home, codexHome: home).isEmpty)
    }
    func testWindowMigrationFitsVisibleScreenAndRetainsUserSize() {
        let display = CGRect(x: 100, y: 40, width: 1440, height: 860)
        let old = CGRect(x: 600, y: 300, width: 1080, height: 748)
        let migrated = WindowGeometry.fitted(old, visible: display, size: WindowGeometry.preferredSize)
        XCTAssertEqual(migrated.size, CGSize(width: 1160, height: 678))
        XCTAssertTrue(display.contains(migrated))
        let custom = CGRect(x: 150, y: 80, width: 930, height: 620)
        XCTAssertEqual(WindowGeometry.fitted(custom, visible: display), custom)
        XCTAssertEqual(WindowGeometry.fitted(old, visible: CGRect(x: 0, y: 0, width: 900, height: 650), size: WindowGeometry.preferredSize).size, CGSize(width: 900, height: 650))
    }
}
