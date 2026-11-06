import Foundation

/// Groups that help someone decide what to remove. An app can be in more than one.
public enum IPhoneAppGroup: String, CaseIterable, Identifiable, Sendable {
    /// No data changed in a long time, according to a backup.
    case quiet
    /// A big app holding almost nothing of its own. Not proof of little use: real tests showed Gmail and X here, which keep their data online.
    case barelyUsed
    /// Mostly data, so offloading wouldn't help.
    case heavyData
    /// Mostly the app itself, so offloading frees nearly all of it.
    case offloadable
    public var id: String { rawValue }
}

/// Real change dates from a backup win. Without them this only says how much data an app holds, and the view must not call that use.
public enum IPhoneAppUse: Int, CaseIterable, Identifiable, Sendable {
    case more, some, less
    public var id: Int { rawValue }
}

public struct IPhoneAppSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let apps: [IPhoneAppRow]
    public var totalBytes: UInt64 { apps.reduce(0) { $0 + $1.totalBytes } }
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

    public func use(of app: IPhoneAppRow) -> IPhoneAppUse {
        if let changed = lastChanged[app.bundleID] {
            let age = now.timeIntervalSince(changed)
            return age < 30 * 86_400 ? .more : age < Self.quietAfter ? .some : .less
        }
        if app.dataBytes >= app.appBytes || app.dataBytes >= 500_000_000 { return .more }
        return app.dataBytes < app.appBytes / 10 ? .less : .some
    }

    public func apps(use: IPhoneAppUse) -> [IPhoneAppRow] { apps.filter { self.use(of: $0) == use } }

    /// Biggest category first. Apps without one go last, under an empty id for the view to name.
    public var categories: [IPhoneAppSection] {
        Dictionary(grouping: apps) { $0.category ?? "" }.map { IPhoneAppSection(id: $0.key, apps: $0.value) }
            .sorted { ($0.id.isEmpty ? 0 : 1, $0.totalBytes, $1.id) > ($1.id.isEmpty ? 0 : 1, $1.totalBytes, $0.id) }
    }

    public func bytes(in group: IPhoneAppGroup) -> UInt64 {
        apps(in: group).reduce(0) { $0 + (group == .barelyUsed || group == .offloadable ? $1.appBytes : $1.totalBytes) }
    }
}
