import XCTest
@testable import MacStewardCore

final class AgentFolderDiscoveryTests: XCTestCase {
    func testDiscoveryPrecedenceAndMissingOverrides() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let standard = home.appendingPathComponent(".codex")
        let custom = home.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: standard, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        func inspect(_ env: [String: String] = [:], selected: URL? = nil) -> AgentFolderDiscovery {
            .inspect(home: home, directoryName: ".codex", environmentKey: "CODEX_HOME", environment: env, selected: selected)
        }
        XCTAssertEqual(inspect().state, .found)
        XCTAssertEqual(inspect().url.path, standard.path)
        XCTAssertEqual(inspect(["CODEX_HOME": custom.path]).url.path, custom.path)
        XCTAssertEqual(inspect(["CODEX_HOME": custom.path]).source, .environment)
        XCTAssertEqual(inspect(["CODEX_HOME": "~/custom"]).url.path, custom.path)
        let missing = home.appendingPathComponent("not-installed")
        XCTAssertEqual(inspect(["CODEX_HOME": missing.path]).state, .missing)
        XCTAssertEqual(inspect(["CODEX_HOME": custom.path], selected: missing).url.path, missing.path)
        XCTAssertEqual(inspect(["CODEX_HOME": custom.path], selected: missing).source, .selected)
        XCTAssertEqual(inspect(["CODEX_HOME": "   "]).url.path, standard.path)
        XCTAssertEqual(inspect(["CODEX_HOME": "relative/path"]).url.path, standard.path)
        let file = home.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(inspect(selected: file).state, .notDirectory)
    }
    func testClaudeUsesItsOwnLocation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let result = AgentFolderDiscovery.inspect(home: home, directoryName: ".claude", environmentKey: "CLAUDE_CONFIG_DIR", environment: ["CODEX_HOME": "/other-tool"])
        XCTAssertEqual(result.state, .found)
        XCTAssertEqual(result.url, home.appendingPathComponent(".claude"))
    }
}
