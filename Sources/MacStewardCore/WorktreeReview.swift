import Foundation
import CryptoKit

/// One Git verdict for a linked worktree, shared by the scan and the recheck before deletion.
public struct WorktreeAssessment: Sendable {
    public let primary: URL?
    public let base: String
    public let branch: String?
    public let head: String
    /// First reason the checkout must stay. nil means it can be deleted.
    public let blocker: String?
    /// Recoverable leftovers the person should see before choosing it.
    public let warnings: [String]
    /// Now for a running process, else the latest Claude Code or Codex session in this checkout.
    public let lastUsed: Date?
    /// HEAD plus a digest of non-ignored status, so any later change forces a new review.
    public let fingerprint: String
    /// Commits not yet in the base branch. Deleting keeps the branch then, so they stay recoverable.
    public var unmerged = 0
    /// Status listed nothing. Git then rechecks at deletion, so a file created after the review is never lost.
    public var clean = false
}
public struct WorktreeRemoval: Sendable {
    public let branch: String?
    public let head: String
    public let branchDeleted: Bool
}

/// Explicit, reviewed worktree deletion. Never called by cache cleanup or scheduling.
public enum WorktreeReview {
    static let recentInterval: TimeInterval = 6 * 3600
    static let sessionInterval: TimeInterval = 24 * 3600

    public static func assess(_ path: String, configuration: Configuration, activity: ActivitySnapshot, sessions: AgentSessionIndex = AgentSessionIndex(), now: Date = Date()) -> WorktreeAssessment {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let lastUsed = activity.isActive(url) ? now : sessions.lastUsed(url)
        func keep(_ reason: String, primary: URL? = nil, base: String = "", branch: String? = nil, head: String = "") -> WorktreeAssessment {
            WorktreeAssessment(primary: primary, base: base, branch: branch, head: head, blocker: reason, warnings: [], lastUsed: lastUsed, fingerprint: head)
        }
        let excluded = configuration.ignoredPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return keep(String(localized: "Keep: the path is a symbolic link or missing.")) }
        guard !excluded.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { return keep(String(localized: "Keep: in your keep list.")) }
        guard activity.reliable else { return keep(String(localized: "Keep: running processes could not be verified.")) }
        guard !activity.isActive(url) else { return keep(String(localized: "Keep: used by a running process.")) }
        let list = git(url, ["worktree", "list", "--porcelain", "-z"])
        guard list.code == 0 else { return keep(String(localized: "Keep: Git registration could not be verified.")) }
        let blocks = list.output.components(separatedBy: "\0\0").filter { !$0.isEmpty }.map { $0.components(separatedBy: "\0") }
        func location(_ fields: [String]) -> URL? { fields.first { $0.hasPrefix("worktree ") }.map { URL(fileURLWithPath: String($0.dropFirst(9))).standardizedFileURL.resolvingSymlinksInPath() } }
        guard let first = blocks.first, let primary = location(first) else { return keep(String(localized: "Keep: the primary checkout could not be found.")) }
        guard primary.path != url.path, let fields = blocks.dropFirst().first(where: { location($0)?.path == url.path }) else { return keep(String(localized: "Keep: primary or unregistered checkouts are managed in Git.")) }
        guard !fields.contains(where: { $0.hasPrefix("locked") || $0.hasPrefix("prunable") || $0 == "bare" }) else { return keep(String(localized: "Keep: Git marks this worktree locked."), primary: primary) }
        let branch = fields.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }
        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent(".gitmodules").path) else { return keep(String(localized: "Keep: worktrees with submodules must be managed in Git."), primary: primary, branch: branch) }
        let headResult = git(url, ["rev-parse", "HEAD"])
        let head = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headResult.code == 0, !head.isEmpty else { return keep(String(localized: "Keep: Git status could not be verified."), primary: primary, branch: branch) }

        // Ignored build output and dependencies are not listed; they are deleted with the checkout.
        let status = git(url, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard status.code == 0 else { return keep(String(localized: "Keep: Git status could not be verified."), primary: primary, branch: branch, head: head) }
        // Status leaves out ignored files, but they go with the checkout and Git can't restore them.
        // A .env or local database is often the only copy, so it gets the same warning as uncommitted work.
        let ignored = git(url, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"])
        guard ignored.code == 0 else { return keep(String(localized: "Keep: ignored files could not be checked."), primary: primary, branch: branch, head: head) }
        let installed: Set<String> = ["node_modules", ".build", "target", "vendor", "venv", ".venv", "Pods", "DerivedData"]
        let sensitive = ignored.output.split(separator: "\0").map(String.init).filter { path in
            let parts = path.split(separator: "/").map(String.init)
            return !parts.contains(where: installed.contains) && parts.last.map(TreeInventory.isForbidden(name:)) == true
        }.sorted()
        var untracked = 0, deleted = 0, modified = 0
        var entries = status.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            let code = entry.prefix(2)
            if code.first == "R" || code.first == "C" { _ = entries.popFirst() }
            if code == "??" { untracked += 1 } else if code == " D" || code == "D " { deleted += 1 } else { modified += 1 }
        }
        let base = baseRef(primary)
        // Patch-equivalence also recognises squash and rebase merges.
        let unmerged = Set([base, "HEAD"]).map { ref -> (ref: String, count: Int) in
            let cherry = git(primary, ["cherry", ref, head])
            return (ref, cherry.code == 0 ? cherry.output.split(separator: "\n").filter { $0.hasPrefix("+") }.count : .max)
        }.min { $0.count < $1.count }!
        guard unmerged.count != .max else { return keep(String(localized: "Keep: merge state could not be verified."), primary: primary, base: base, branch: branch, head: head) }
        // Unfinished work is the person's call: flagged and left unticked, never blocked.
        var warnings = [String]()
        if modified > 0 { warnings.append(String(localized: "\(modified) tracked files have uncommitted changes. They will be lost.")) }
        if unmerged.count > 0 { warnings.append(unmerged.ref == "HEAD" ? String(localized: "\(unmerged.count) commits are not in the primary checkout. The branch is kept, so they stay recoverable.") : String(localized: "\(unmerged.count) commits are not in \(unmerged.ref). The branch is kept, so they stay recoverable.")) }
        if untracked > 0 { warnings.append(String(localized: "\(untracked) untracked files were never committed. They will be deleted permanently.")) }
        if deleted > 0 { warnings.append(String(localized: "\(deleted) tracked files are deleted here; Git still has them.")) }
        if let first = sensitive.first {
            let name = URL(fileURLWithPath: first).lastPathComponent.displaySafe
            warnings.append(sensitive.count == 1 ? String(localized: "\(name) is ignored by Git, so it can't be restored. It will be deleted permanently.") : String(localized: "\(sensitive.count) files Git ignores, such as \(name), can't be restored. They will be deleted permanently."))
        }
        if let time = TimeInterval(git(url, ["log", "-1", "--format=%ct"]).output.trimmingCharacters(in: .whitespacesAndNewlines)), now.timeIntervalSince1970 - time < recentInterval {
            warnings.append(String(localized: "Committed in the last 6 hours; an agent session may still be open on it."))
        }
        if let lastUsed, now.timeIntervalSince(lastUsed) < sessionInterval {
            warnings.append(String(localized: "A Claude Code or Codex session used it in the last 24 hours."))
        }
        let digest = SHA256.hash(data: Data((status.output + "\0\0" + sensitive.joined(separator: "\0")).utf8)).map { String(format: "%02x", $0) }.joined()
        return WorktreeAssessment(primary: primary, base: base, branch: branch, head: head, blocker: nil, warnings: warnings, lastUsed: lastUsed, fingerprint: "\(head):\(digest)", unmerged: unmerged.count, clean: status.output.isEmpty)
    }

    /// The repository's default branch, falling back to the primary checkout.
    static func baseRef(_ primary: URL) -> String {
        let remote = git(primary, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty { return remote }
        return ["origin/main", "origin/master", "main", "master"].first { git(primary, ["rev-parse", "--verify", "--quiet", $0 + "^{commit}"]).code == 0 } ?? "HEAD"
    }

    public static func validate(_ finding: Finding, configuration: Configuration) throws -> WorktreeAssessment {
        try validate(finding, configuration: configuration, activity: .capture())
    }
    static func validate(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot, sessions: AgentSessionIndex? = nil) throws -> WorktreeAssessment {
        guard finding.group == .worktrees, finding.rule == "worktree-review-only", finding.safety == .review else { throw StewardError.blocked(String(localized: "Only reviewable worktrees can be deleted.")) }
        let assessment = assess(finding.path, configuration: configuration, activity: activity, sessions: sessions ?? .load(claudeHome: configuration.claudeHome, codexHome: configuration.codexHome))
        if let blocker = assessment.blocker { throw StewardError.blocked(blocker) }
        guard assessment.fingerprint == finding.fingerprint else { throw StewardError.blocked(String(localized: "This worktree changed after the scan. Scan again.")) }
        return assessment
    }

    /// Rechecks several worktrees against one fresh process and session snapshot.
    public static func validate(_ findings: [Finding], configuration: Configuration) -> [Result<WorktreeAssessment, Error>] {
        let activity = ActivitySnapshot.capture(), sessions = AgentSessionIndex.load(claudeHome: configuration.claudeHome, codexHome: configuration.codexHome)
        return findings.map { finding in Result { try validate(finding, configuration: configuration, activity: activity, sessions: sessions) } }
    }
    /// Deletes several worktrees, rechecking each against process evidence at most 5 seconds old.
    /// `progress` gets (worktrees done, the one just handled); `shouldStop` is asked before each. Stopping leaves the rest untouched.
    public static func delete(_ findings: [Finding], configuration: Configuration, progress: ((Int, String) -> Void)? = nil, shouldStop: () -> Bool = { false }) -> [Result<WorktreeRemoval, Error>] {
        var activity = ActivitySnapshot.capture(), taken = Date()
        var results = [Result<WorktreeRemoval, Error>]()
        for finding in findings {
            if shouldStop() { break }
            if Date().timeIntervalSince(taken) > 5 { activity = .capture(); taken = Date() }
            results.append(Result { [activity] in try delete(finding, configuration: configuration, activity: activity, remove: gitRemove) })
            progress?(results.count, finding.title)
        }
        return results
    }
    /// Git deletes the checkout and its registration together. Ignored files go with it either way;
    /// --force is used only when the person reviewed and accepted uncommitted or untracked files.
    static func gitRemove(_ worktree: URL, primary: URL, force: Bool) throws {
        let result = git(primary, ["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path])
        guard result.code == 0 else { throw StewardError.blocked(String(localized: "Git could not delete the worktree: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")) }
    }
    static func delete(_ finding: Finding, configuration: Configuration, activity: ActivitySnapshot, sessions: AgentSessionIndex? = nil, remove: (URL, URL, Bool) throws -> Void) throws -> WorktreeRemoval {
        let assessment = try validate(finding, configuration: configuration, activity: activity, sessions: sessions)
        guard let primary = assessment.primary else { throw StewardError.blocked(String(localized: "Cannot find the primary checkout.")) }
        let source = URL(fileURLWithPath: finding.path)
        try remove(source, primary, !assessment.clean)
        _ = git(primary, ["worktree", "prune"])
        var branchDeleted = false
        if let branch = assessment.branch, assessment.unmerged == 0 {
            // Delete only while the tip is still the merged HEAD that was reviewed.
            let tip = git(primary, ["rev-parse", "refs/heads/" + branch]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if tip == assessment.head { branchDeleted = git(primary, ["branch", "-D", branch]).code == 0 }
        }
        removeEmptyParent(of: source, configuration: configuration)
        return WorktreeRemoval(branch: assessment.branch, head: assessment.head, branchDeleted: branchDeleted)
    }

    /// Removes a session folder left empty, such as `project-sessions/` or a Codex `worktrees/<id>/`.
    static func removeEmptyParent(of source: URL, configuration: Configuration) {
        let parent = source.deletingLastPathComponent().standardizedFileURL
        let protected = Set((configuration.projectRoots + [configuration.home, configuration.codexHome, configuration.claudeHome, configuration.codexHome.appendingPathComponent("worktrees"), configuration.claudeHome.appendingPathComponent("worktrees")]).map { $0.standardizedFileURL.path })
        let leftovers: Set<String> = [".DS_Store", ".codex-worktree-name"]
        guard !protected.contains(parent.path), parent.pathComponents.count > 3,
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path), Set(names).isSubset(of: leftovers) else { return }
        for name in names { try? FileManager.default.removeItem(at: parent.appendingPathComponent(name)) }
        // rmdir refuses if anything new appeared meanwhile.
        _ = rmdir(parent.path)
    }
}
