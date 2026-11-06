import Foundation

/// The step a scan is on, for the step row under the artwork. The message is translated, so it can't say.
public enum ScanStep: Int, Sendable { case access, caches, worktrees, logs, tools }

/// Counts completed checks from an established checklist, not elapsed time.
/// A nil total means discovery is still identifying the work to be checked.
public struct ScanProgress: Sendable, Equatable {
    public let message: String
    public let completed: Int
    public let total: Int?
    public let step: ScanStep
    public init(message: String, completed: Int = 0, total: Int? = nil, step: ScanStep = .access) {
        self.message = message
        self.step = step
        self.total = total.map { max(0, $0) }
        self.completed = max(0, min(completed, self.total ?? max(0, completed)))
    }
    public var fraction: Double? { total.map { $0 == 0 ? 1 : Double(completed) / Double($0) } }
    public var remaining: Int? { total.map { max(0, $0 - completed) } }
    public func addingPendingChecks(_ count: Int) -> ScanProgress {
        ScanProgress(message: message, completed: completed, total: total.map { $0 + max(0, count) }, step: step)
    }
}
