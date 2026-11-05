import XCTest
@testable import MacStewardCore

final class FocusedToolsTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }
    private func old(_ url: URL) throws { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60 * 86400)], ofItemAtPath: url.path) }

    func testFocusedScanInspectsOnlyItsOwnGroups() throws {
        let logs = home.appendingPathComponent("Library/Logs/NGL"); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("NGLClient_Illustrator.log"); try Data(repeating: 1, count: 70_000).write(to: log); try old(log)
        let config = Configuration(home: home, includeAdditionalLogs: true, projectRoots: [])
        let all = try Scanner(configuration: config).scanWithProgress({ _ in }, activityOverride: ActivitySnapshot())
        XCTAssertTrue(all.findings.contains { $0.group == .userLogs })
        let worktreesOnly = try Scanner(configuration: config, groups: [.worktrees]).scanWithProgress({ _ in }, activityOverride: ActivitySnapshot())
        XCTAssertFalse(worktreesOnly.findings.contains { $0.group == .userLogs })
    }
    func testSessionIndexFindsClaudeAndCodexActivityInsideAWorktree() throws {
        let tree = URL(fileURLWithPath: "/Users/someone/project/.claude/worktrees/task-1")
        let claude = home.appendingPathComponent(".claude/projects/" + AgentSessionIndex.claudeKey(tree.path))
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: claude.appendingPathComponent("s.jsonl"))
        let codexDay = home.appendingPathComponent(".codex/sessions/2026/11/02"); try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        let other = URL(fileURLWithPath: "/Users/someone/other-checkout")
        try Data(#"{"type":"session_meta","payload":{"cwd":"/Users/someone/other-checkout/app"}}"#.utf8 + Data("\n{\"later\":1}\n".utf8)).write(to: codexDay.appendingPathComponent("rollout.jsonl"))
        let index = AgentSessionIndex.load(claudeHome: home.appendingPathComponent(".claude"), codexHome: home.appendingPathComponent(".codex"))
        XCTAssertNotNil(index.lastUsed(tree))
        XCTAssertNotNil(index.lastUsed(other), "a Codex session in a subfolder counts")
        XCTAssertNil(index.lastUsed(URL(fileURLWithPath: "/Users/someone/unused")))
    }
    func testDuplicateSearchIncludesSubfoldersButSkipsDependencies() throws {
        let data = Data(repeating: 65, count: 1_000_001)
        for relative in ["a.bin", "nested/deeper/copy.bin", "node_modules/pkg/copy.bin"] {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let groups = try DuplicateFinder.scan(folder: home)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(), ["a.bin", "copy.bin"])
        XCTAssertFalse(groups.first?.files.contains { $0.contains("node_modules") } ?? true)
    }
}
