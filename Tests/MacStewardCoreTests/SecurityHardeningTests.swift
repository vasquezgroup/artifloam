import XCTest
@testable import MacStewardCore

final class SecurityHardeningTests: XCTestCase {
    private var root: URL!
    private let identity = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    override func setUpWithError() throws {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steward-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    /// A committed repository plus an executable that leaves a marker file if anything runs it.
    private func hostileRepository() throws -> (repo: URL, script: URL, marker: URL) {
        let repo = root.appendingPathComponent("repo"), script = root.appendingPathComponent("evil.sh"), marker = root.appendingPathComponent("RAN")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(git(repo, ["init", "-b", "main"]).code, 0)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        XCTAssertEqual(git(repo, ["add", "a.txt"]).code, 0)
        XCTAssertEqual(git(repo, identity + ["commit", "-m", "initial"]).code, 0)
        try Data("#!/bin/sh\ntouch '\(marker.path)'\ncat\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (repo, script, marker)
    }
    /// Bypasses the sandbox, to write hostile config and to prove the fixture really runs the script.
    private func unprotectedGit(_ repo: URL, _ args: [String]) -> CommandResult {
        MacStewardCore.run(DeveloperTools.gitExecutable!, ["-C", repo.path] + args)
    }

    func testFsmonitorFromRepositoryConfigDoesNotRun() throws {
        let (repo, script, marker) = try hostileRepository()
        XCTAssertEqual(unprotectedGit(repo, ["config", "core.fsmonitor", script.path]).code, 0)
        _ = unprotectedGit(repo, ["status", "--porcelain"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "fixture must be able to run without the protection")
        try FileManager.default.removeItem(at: marker)
        for args in [["status", "--porcelain"], ["ls-files", "-z"], ["check-ignore", "--", "a.txt"]] { _ = git(repo, args) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testCleanFilterFromRepositoryConfigDoesNotRun() throws {
        let (repo, script, marker) = try hostileRepository()
        try Data("*.txt filter=evil\n".utf8).write(to: repo.appendingPathComponent(".git/info/attributes"))
        XCTAssertEqual(unprotectedGit(repo, ["config", "filter.evil.clean", script.path]).code, 0)
        Thread.sleep(forTimeInterval: 1.1) // Same size, newer time: Git must read the content to compare it.
        try Data("y\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = git(repo, ["status", "--porcelain"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testHookInRepositoryDoesNotRun() throws {
        let (repo, script, marker) = try hostileRepository()
        XCTAssertEqual(git(repo, ["branch", "other"]).code, 0)
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: script, to: hooks.appendingPathComponent("reference-transaction"))
        XCTAssertEqual(git(repo, ["branch", "-D", "other"]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUpdateFeedAcceptsOnlyOurDownloads() {
        func url(_ text: String) -> URL { URL(string: text)! }
        XCTAssertTrue(UpdateFeed.trusted(version: "0.17.0", url: url("https://vasquezgroup.ch/downloads/Artifloam-0.17.0.zip")))
        for bad in ["http://vasquezgroup.ch/downloads/a.zip", "https://evil.example/downloads/a.zip", "https://vasquezgroup.ch@evil.example/downloads/a.zip", "https://vasquezgroup.ch.evil.example/downloads/a.zip",
                    "file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.Battery", "https://vasquezgroup.ch/other/a.zip", "https://vasquezgroup.ch/downloads/../a.zip", "https://vasquezgroup.ch:8443/downloads/a.zip"] {
            XCTAssertFalse(UpdateFeed.trusted(version: "1.0", url: url(bad)), bad)
        }
        XCTAssertFalse(UpdateFeed.trusted(version: "Urgent: call support", url: url("https://vasquezgroup.ch/downloads/a.zip")))
    }

    func testProtectedNamesIgnoreCase() throws {
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: cache.appendingPathComponent("Credentials.JSON"))
        XCTAssertThrowsError(try TreeInventory.read(cache))
        XCTAssertThrowsError(try TreeSummary.read(cache))
    }

    func testRemovalRefusesSymlinkSwappedIntoThePath() throws {
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        let target = real.appendingPathComponent("__pycache__")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("bytecode".utf8).write(to: target.appendingPathComponent("a.pyc"))
        let tree = try TreeInventory.read(target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try SecureRemoval.remove(link.appendingPathComponent("__pycache__"), tree: tree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "a redirected path deletes nothing")
        try SecureRemoval.remove(target, tree: tree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "the real path still works")
    }

    func testCleanWorktreeIsNotForcedSoALateFileSurvives() throws {
        let (repo, _, _) = try hostileRepository()
        let tree = root.appendingPathComponent("tree")
        XCTAssertEqual(git(repo, ["worktree", "add", "-b", "tree", tree.path]).code, 0)
        try Data("written after the review".utf8).write(to: tree.appendingPathComponent("late.txt"))
        XCTAssertThrowsError(try WorktreeReview.gitRemove(tree, primary: repo, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("late.txt").path))
    }
}
