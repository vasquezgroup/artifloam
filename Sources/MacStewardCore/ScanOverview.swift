import Foundation

/// Presentation totals preserve the scanner's safety classifications. Review-only
/// and protected bytes never contribute to space eligible for cleanup.
public struct CleanupCategorySummary: Identifiable, Sendable {
    public var id: CleanupGroup { group }
    public let group: CleanupGroup
    public let eligibleBytes: UInt64
    public let totalBytes: UInt64
    public let automaticCount: Int
    public let reviewCount: Int
    public let protectedCount: Int
    /// Held items the user may tick: recently used caches and caches whose running app can be quit.
    public var choosableBytes: UInt64 = 0
    public var choosableCount = 0
    /// Everything found that can be deleted here: ready, choosable and finished worktrees.
    public var foundBytes: UInt64 = 0
    public var count: Int { automaticCount + reviewCount + protectedCount }
}
public struct ScanOverview: Sendable {
    public let categories: [CleanupCategorySummary]
    public var eligibleBytes: UInt64 { categories.reduce(0) { $0 + $1.eligibleBytes } }
    public var automaticCount: Int { categories.reduce(0) { $0 + $1.automaticCount } }
    public var reviewCount: Int { categories.reduce(0) { $0 + $1.reviewCount } }
    public var protectedCount: Int { categories.reduce(0) { $0 + $1.protectedCount } }
    public var choosableBytes: UInt64 { categories.reduce(0) { $0 + $1.choosableBytes } }
    public var foundBytes: UInt64 { categories.reduce(0) { $0 + $1.foundBytes } }
    public init(findings: [Finding]) {
        categories = CleanupGroup.allCases.map { group in
            let items = findings.filter { $0.group == group }
            let eligible = items.filter { $0.safety == .automatic }
            var summary = CleanupCategorySummary(group: group, eligibleBytes: eligible.reduce(0) { $0 + $1.bytes }, totalBytes: items.reduce(0) { $0 + $1.bytes },
                automaticCount: eligible.count, reviewCount: items.filter { $0.safety == .review }.count,
                protectedCount: items.filter { $0.safety == .protected }.count)
            let choosable = items.filter { $0.safety != .automatic && $0.userCleanable }
            summary.choosableBytes = choosable.reduce(0) { $0 + $1.bytes }; summary.choosableCount = choosable.count
            summary.foundBytes = items.filter { $0.userCleanable || ($0.group == .worktrees && $0.safety == .review) }.reduce(0) { $0 + $1.bytes }
            return summary
        }
    }
}
