import Foundation

public enum CleanupGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case agentBuilds, worktrees, xcode, developerCaches, projectCaches, inactiveDependencies, userCaches, userLogs, systemCaches, systemLogs, universalApps, languages, deviceBackups, documentVersions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .agentBuilds: return String(localized: "AI session leftovers")
        case .worktrees: return String(localized: "Claude & Codex worktrees")
        case .xcode: return String(localized: "Xcode storage")
        case .developerCaches: return String(localized: "Developer caches")
        case .projectCaches: return String(localized: "Project caches")
        case .inactiveDependencies: return String(localized: "Inactive project dependencies")
        case .userCaches: return String(localized: "Application caches")
        case .userLogs: return String(localized: "Old application logs")
        case .systemCaches: return String(localized: "System caches")
        case .systemLogs: return String(localized: "System logs")
        case .universalApps: return String(localized: "Universal applications")
        case .languages: return String(localized: "Language resources")
        case .deviceBackups: return String(localized: "iPhone & iPad backups")
        case .documentVersions: return String(localized: "Document versions")
        }
    }
    public var icon: String {
        switch self {
        case .agentBuilds: return "sparkles"
        case .worktrees: return "arrow.triangle.branch"
        case .xcode, .developerCaches: return "hammer.fill"
        case .projectCaches: return "shippingbox.fill"
        case .inactiveDependencies: return "shippingbox"
        case .userCaches, .systemCaches: return "externaldrive.fill"
        case .userLogs, .systemLogs: return "doc.text.fill"
        case .universalApps: return "app.fill"
        case .languages: return "globe"
        case .deviceBackups: return "iphone"
        case .documentVersions: return "clock.arrow.circlepath"
        }
    }
    public var explanation: String {
        switch self {
        case .agentBuilds: return String(localized: "Older copies of Claude Code and Cursor agent (the newest stays), and regenerable Xcode output inside Claude's temporary sessions. Conversation history and original images stay.")
        case .worktrees: return String(localized: "Git status, preserved commits, session activity and running processes decide whether a checkout needs review. Worktrees are never removed automatically.")
        case .xcode: return String(localized: "Old build intermediates may qualify for cleanup. Simulator runtimes are managed in Xcode. Simulators you no longer use can be ticked one by one. Archives, symbols and source packages stay protected.")
        case .developerCaches: return String(localized: "Unused Gradle artifact transforms, generated Gradle JARs, Xcode module caches and npm's download cache. Recent or active caches, downloaded dependencies and configuration stay protected.")
        case .projectCaches: return String(localized: "Known generated caches only. Tracked files, secrets, databases, dependencies and recent files are excluded.")
        case .inactiveDependencies: return String(localized: "node_modules, Rust target and Swift .build folders in projects untouched for 30 days: no commit, no uncommitted change, no running process and no Claude Code or Codex session. Each has a lockfile, so one install rebuilds it. Never selected or scheduled automatically.")
        case .userCaches: return String(localized: "Recognised web caches from closed applications. App data, accounts, cookies and documents stay.")
        case .userLogs: return String(localized: "Recognised CoreSimulator, Adobe NGL and Office diagnostic .log files older than 30 days. Settings, credentials, other logs and conversation histories stay protected.")
        case .systemCaches, .systemLogs: return String(localized: "System-managed data. This version does not request administrator access or remove these files.")
        case .universalApps: return String(localized: "Application binaries stay intact to preserve their signatures and compatibility.")
        case .languages: return String(localized: "Language resources stay inside their signed applications.")
        case .deviceBackups: return String(localized: "Backups contain personal data. Review in Finder; no automatic deletion.")
        case .documentVersions: return String(localized: "Saved document history is protected. No version is treated as disposable cache.")
        }
    }
}
public enum Safety: String, Codable, Sendable { case automatic, review, protected }
/// Why a known cache isn't cleaned automatically. `recent` and `inUse` with a known owner can still be chosen by the user.
public enum Hold: String, Codable, Sendable { case recent, inUse, unverified }
public struct Finding: Codable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let group: CleanupGroup
    public var bytes: UInt64
    public let modifiedAt: Date
    public let safety: Safety
    public let reason: String
    public let rule: String
    public let fingerprint: String
    /// Worktrees only: when a running process or agent session last used it.
    public let lastUsedAt: Date?
    /// Worktrees only: recoverable risks that keep it unticked by default.
    public let warnings: [String]?
    /// Set when a known cache is held back by its state rather than by what it is.
    public let hold: Hold?
    /// The running app that owns a held cache; Artifloam quits it normally before cleaning.
    public let owner: String?
    /// Cleaned without asking (`automatic`), held only by recency or a running owner the user can quit, or an Xcode folder the user may move to the Trash.
    public var userCleanable: Bool { safety == .automatic || hold == .recent || (hold == .inUse && owner != nil) || ([XcodeStorageInventory.trashRule, XcodeStorageInventory.simulatorRule].contains(rule) && safety == .review) }
    /// Ticked by a category checkbox or "Select ready": ready items plus unflagged choices. Flagged and held ones stay one-by-one.
    public var tickable: Bool { safety == .automatic || (userCleanable && hold == nil && (warnings ?? []).isEmpty) }
    /// A readable name when the folder has none, such as a simulator's UUID.
    public var label: String? = nil
    public var title: String { (label ?? URL(fileURLWithPath: path).lastPathComponent).displaySafe }
    public init(path: String, group: CleanupGroup, bytes: UInt64, modifiedAt: Date, safety: Safety, reason: String, rule: String, fingerprint: String, lastUsedAt: Date? = nil, warnings: [String]? = nil, hold: Hold? = nil, owner: String? = nil, label: String? = nil) {
        self.label = label
        self.path = path; self.id = path; self.group = group; self.bytes = bytes; self.modifiedAt = modifiedAt; self.safety = safety; self.reason = reason; self.rule = rule; self.fingerprint = fingerprint; self.lastUsedAt = lastUsedAt; self.warnings = warnings
        self.hold = hold; self.owner = owner
    }
}
public struct DiskSpace: Codable, Sendable {
    public let free: UInt64
    public let total: UInt64
    public static func read(at path: String = NSHomeDirectory()) -> DiskSpace {
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: path)) ?? [:]
        return DiskSpace(free: (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0, total: (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0)
    }
}
public struct ScanReport: Codable, Sendable {
    public let version: Int
    public let createdAt: Date
    public let home: String
    public let disk: DiskSpace
    public let findings: [Finding]
    public let notices: [String]
    public var eligibleBytes: UInt64 { findings.filter { $0.safety == .automatic }.reduce(0) { $0 + $1.bytes } }
    public init(home: String, findings: [Finding], notices: [String] = []) {
        version = 1; createdAt = Date(); self.home = home; disk = .read(at: home); self.findings = findings; self.notices = notices
    }
}
public struct CleanupItem: Codable, Sendable {
    public let path: String
    public let outcome: String
    public let detail: String
    public let bytes: UInt64
}
public struct CleanupReceipt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let before: DiskSpace
    public let after: DiskSpace
    public let items: [CleanupItem]
    public var measuredChange: Int64 { Int64(after.free) - Int64(before.free) }
    public var removedCount: Int { items.filter { $0.outcome == "removed" }.count }
}
public struct Configuration: Sendable {
    public var home: URL
    public var projectRoots: [URL]
    public var projects: URL {
        get { projectRoots.first ?? home.appendingPathComponent("Documents/projects") }
        set { projectRoots = [newValue] }
    }
    public var claudeHome: URL
    public var codexHome: URL
    public var agentTemp: URL
    public var minimumAgeDays: Int
    public var ignoredPaths: [String]
    public var includeApplicationCaches: Bool
    public var includeDeveloperCaches: Bool
    public var includeAdditionalLogs: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, minimumAgeDays: Int = 7, ignoredPaths: [String] = [], includeApplicationCaches: Bool = false, includeDeveloperCaches: Bool = false, includeAdditionalLogs: Bool = false, projectRoots: [URL]? = nil, claudeHome: URL? = nil, codexHome: URL? = nil) {
        self.home = home
        self.projectRoots = projectRoots ?? [home.appendingPathComponent("Documents/projects")]
        let isCurrentUser = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let environment = ProcessInfo.processInfo.environment
        self.claudeHome = AgentFolderDiscovery.location(home: home, directoryName: ".claude", environmentKey: "CLAUDE_CONFIG_DIR", environment: isCurrentUser ? environment : [:], selected: claudeHome).0
        self.codexHome = AgentFolderDiscovery.location(home: home, directoryName: ".codex", environmentKey: "CODEX_HOME", environment: isCurrentUser ? environment : [:], selected: codexHome).0
        agentTemp = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")
        self.minimumAgeDays = max(7, minimumAgeDays); self.ignoredPaths = ignoredPaths; self.includeApplicationCaches = includeApplicationCaches; self.includeDeveloperCaches = includeDeveloperCaches; self.includeAdditionalLogs = includeAdditionalLogs
    }
}
public func formattedBytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .decimal) }

public extension Configuration {
    static func canonicalProjectRoots(_ urls: [URL]) -> [URL] {
        let sorted = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { $0.path != "/" }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        return sorted.reduce(into: [URL]()) { roots, url in
            if !roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) { roots.append(url) }
        }
    }
}

extension Array where Element == Finding {
    /// What a bulk checkbox takes. In a category: everything a person may delete there, the same as its summary tile; worktrees are
    /// the finished ones, rechecked with Git before they go. "All" stays with ready items: it spans every category, including apps that would quit.
    public func bulkChoosable(in group: CleanupGroup?) -> [Finding] {
        guard let group else { return filter(\.tickable) }
        return filter { $0.group == group && (group == .worktrees ? $0.safety == .review : $0.userCleanable) }
    }
}
