import XCTest
@testable import MacStewardCore

final class WorktreeReviewTests: XCTestCase {
    private let identity = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
    private func fixture(parent: String = "") throws -> (URL, URL, Configuration) {
        guard DeveloperTools.gitExecutable != nil else { throw XCTSkip("Git unavailable") }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let primary = root.appendingPathComponent("primary"), tree = root.appendingPathComponent(parent).appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        XCTAssertEqual(git(primary, ["init", "-b", "main"]).code, 0)
        try Data("private.bin\n".utf8).write(to: primary.appendingPathComponent(".gitignore"))
        XCTAssertEqual(git(primary, ["add", ".gitignore"]).code, 0)
        XCTAssertEqual(git(primary, identity + ["commit", "-m", "initial"]).code, 0)
        XCTAssertEqual(git(primary, ["worktree", "add", "-b", "test-tree", tree.path]).code, 0)
        return (root, tree, Configuration(home: root, projectRoots: [primary]))
    }
    private func finding(_ tree: URL, _ config: Configuration) -> Finding {
        let verdict = WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot())
        return Finding(path: tree.path, group: .worktrees, bytes: 0, modifiedAt: Date(), safety: verdict.blocker == nil ? .review : .protected, reason: "fixture", rule: "worktree-review-only", fingerprint: verdict.fingerprint)
    }
    private let realRemove = WorktreeReview.gitRemove
    private func commit(_ tree: URL, _ name: String) throws {
        try Data(name.utf8).write(to: tree.appendingPathComponent(name))
        XCTAssertEqual(git(tree, ["add", name]).code, 0)
        XCTAssertEqual(git(tree, identity + ["commit", "-m", name]).code, 0)
    }

    func testIgnoredSecretsWarnAndAppearingOneForcesNewReview() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(".env\nnode_modules\n".utf8).write(to: tree.appendingPathComponent(".gitignore"))
        XCTAssertEqual(git(tree, ["add", ".gitignore"]).code, 0)
        XCTAssertEqual(git(tree, identity + ["commit", "-m", "ignore"]).code, 0)
        // A package's own test key is not the person's secret.
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data("k".utf8).write(to: tree.appendingPathComponent("node_modules/x/.env"))
        let before = finding(tree, config)
        XCTAssertFalse(WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot()).warnings.contains { $0.contains(".env") })
        try Data("SECRET=1".utf8).write(to: tree.appendingPathComponent(".env"))
        XCTAssertTrue(WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot()).warnings.contains { $0.contains(".env") })
        XCTAssertThrowsError(try WorktreeReview.validate(before, configuration: config, activity: ActivitySnapshot()), "a secret added after the review must not be deleted unseen")
    }

    func testMergedCheckoutIsDeletedWithItsRegistrationAndBranch() throws {
        let (root, tree, config) = try fixture(parent: "sessions"); defer { try? FileManager.default.removeItem(at: root) }
        let primary = config.projectRoots[0]
        try Data("dependency".utf8).write(to: tree.appendingPathComponent("private.bin"))
        let removal = try WorktreeReview.delete(finding(tree, config), configuration: config, activity: ActivitySnapshot(), remove: realRemove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path), "ignored files do not stop deletion")
        XCTAssertTrue(removal.branchDeleted)
        XCTAssertNotEqual(git(primary, ["show-ref", "--verify", "refs/heads/test-tree"]).code, 0)
        XCTAssertFalse(git(primary, ["worktree", "list"]).output.contains(tree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions").path), "empty session folder is removed")
        XCTAssertEqual(git(primary, ["branch", "restored", removal.head]).code, 0, "the reported commit restores the branch")
    }
    func testSquashMergedWorkIsRecognisedAndUnmergedWorkIsFlagged() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = config.projectRoots[0]
        try commit(tree, "feature.txt")
        let unmerged = WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot())
        XCTAssertNil(unmerged.blocker); XCTAssertEqual(unmerged.unmerged, 1)
        XCTAssertTrue(unmerged.warnings.contains { $0.contains("not in") })
        XCTAssertEqual(git(primary, identity + ["cherry-pick", "test-tree"]).code, 0)
        XCTAssertEqual(WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot()).unmerged, 0)
    }
    func testDeletingUnmergedWorkKeepsItsBranch() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = config.projectRoots[0]
        try commit(tree, "feature.txt")
        let removal = try WorktreeReview.delete(finding(tree, config), configuration: config, activity: ActivitySnapshot(), remove: WorktreeReview.gitRemove)
        XCTAssertFalse(removal.branchDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(git(primary, ["show-ref", "--verify", "refs/heads/test-tree"]).code, 0, "unmerged commits stay on their branch")
    }
    func testMergedIntoDefaultBranchCountsWhilePrimaryIsOnAnotherBranch() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = config.projectRoots[0]
        try commit(tree, "feature.txt")
        XCTAssertEqual(git(primary, ["merge", "--ff-only", "test-tree"]).code, 0)
        XCTAssertEqual(git(primary, ["checkout", "-b", "other", "HEAD~1"]).code, 0)
        XCTAssertNil(WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot()).blocker)
    }
    func testUntrackedDeletedAndEditedFilesAllWarn() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("dependency".utf8).write(to: tree.appendingPathComponent("private.bin"))
        XCTAssertEqual(WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot()).warnings.count, 1, "only the recent-commit warning; ignored files are silent")
        try Data("screenshot".utf8).write(to: tree.appendingPathComponent("output.png"))
        try FileManager.default.removeItem(at: tree.appendingPathComponent(".gitignore"))
        let warned = WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot())
        XCTAssertNil(warned.blocker); XCTAssertEqual(warned.warnings.count, 3)
        try Data("edited\n".utf8).write(to: tree.appendingPathComponent(".gitignore"))
        let edited = WorktreeReview.assess(tree.path, configuration: config, activity: ActivitySnapshot())
        XCTAssertNil(edited.blocker); XCTAssertTrue(edited.warnings.contains { $0.contains("uncommitted") })
    }
    func testChangesAfterTheScanForceANewReview() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reviewed = finding(tree, config)
        try Data("new".utf8).write(to: tree.appendingPathComponent("late.txt"))
        XCTAssertThrowsError(try WorktreeReview.delete(reviewed, configuration: config, activity: ActivitySnapshot(), remove: realRemove))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
    }
    func testActivityRecognizesPrivateVarAndTmpAliases() {
        XCTAssertTrue(ActivitySnapshot(openPaths: ["/private/var/folders/project/file"]).isActive(URL(fileURLWithPath: "/var/folders/project")))
        XCTAssertTrue(ActivitySnapshot(openPaths: ["/tmp/project/file"]).isActive(URL(fileURLWithPath: "/private/tmp/project")))
    }
    func testActiveLockedAndExcludedCheckoutsBlockRemoval() throws {
        let (root, tree, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reviewed = finding(tree, config)
        XCTAssertThrowsError(try WorktreeReview.validate(reviewed, configuration: config, activity: ActivitySnapshot(openPaths: [tree.path + "/file"])))
        XCTAssertThrowsError(try WorktreeReview.validate(reviewed, configuration: config, activity: ActivitySnapshot(reliable: false)))
        var excluded = config; excluded.ignoredPaths = [tree.path]
        XCTAssertThrowsError(try WorktreeReview.validate(reviewed, configuration: excluded, activity: ActivitySnapshot()))
        XCTAssertEqual(git(config.projectRoots[0], ["worktree", "lock", tree.path]).code, 0)
        XCTAssertThrowsError(try WorktreeReview.validate(reviewed, configuration: config, activity: ActivitySnapshot()))
    }
}
