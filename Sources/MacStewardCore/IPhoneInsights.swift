import Foundation

/// Groups that help someone decide what to remove. An app can be in more than one.
public enum IPhoneAppGroup: String, CaseIterable, Identifiable, Sendable {
    /// No data changed in a long time, according to a backup.
    case quiet
    /// A big app holding almost nothing of its own, so it has probably seen little use.
    case barelyUsed
    /// Mostly data, so offloading wouldn't help.
    case heavyData
    /// Mostly the app itself, so offloading frees nearly all of it.
    case offloadable
    public var id: String { rawValue }
}

public struct IPhoneInsights: Equatable, Sendable {
    public let apps: [IPhoneAppRow]
    /// Bundle ID to the newest change to that app's data in a backup. Empty without a backup.
    public let lastChanged: [String: Date]
    public let now: Date

    public static let quietAfter: TimeInterval = 180 * 86_400
    static let minimumBytes: UInt64 = 100_000_000

    public init(apps: [IPhoneAppRow], lastChanged: [String: Date] = [:], now: Date = Date()) {
        self.apps = apps
        self.lastChanged = lastChanged
        self.now = now
    }

    /// Largest first, except quiet apps: the longest quiet come first.
    public func apps(in group: IPhoneAppGroup) -> [IPhoneAppRow] {
        // WhatsApp's data is people's chats, so it's never suggested as something to delete or offload.
        let candidates = apps.filter { $0.advice != .cleanInWhatsApp && $0.measured && $0.totalBytes >= Self.minimumBytes }
        switch group {
        case .quiet:
            return candidates.filter { app in lastChanged[app.bundleID].map { now.timeIntervalSince($0) >= Self.quietAfter } ?? false }
                .sorted { (lastChanged[$0.bundleID] ?? now) < (lastChanged[$1.bundleID] ?? now) }
        case .barelyUsed: return candidates.filter { $0.dataBytes < $0.appBytes / 10 }
        case .heavyData: return candidates.filter { $0.advice == .offloadKeepsData }
        case .offloadable: return candidates.filter { $0.advice == .offloadHelps }
        }
    }

    public func bytes(in group: IPhoneAppGroup) -> UInt64 {
        apps(in: group).reduce(0) { $0 + (group == .barelyUsed || group == .offloadable ? $1.appBytes : $1.totalBytes) }
    }
}
