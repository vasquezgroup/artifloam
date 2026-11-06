import Foundation

/// One thing worth fixing right now. Shown as a flag on its dashboard card, a row on the Overview and, once, a notification.
public struct MacIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case storage, memory, cpu, heat, battery, restart, network }
    public enum Fix: Equatable, Sendable { case quit(pid: Int32), forceQuit(pid: Int32), freeSpace, quitIdleApps, batterySettings, networkSettings, none }
    public var id: String { kind.rawValue }
    public let kind: Kind
    /// A sentence for the Overview and notifications: "Claude is busy for 8 min".
    public let title: String
    /// A few words for the card: "Claude 60% · 8 min".
    public let flag: String
    public let fix: Fix
    /// Health points this issue costs, and so wins back when fixed.
    public let points: Int
    public var fixLabel: String? {
        switch fix {
        case .quit: return String(localized: "Quit", comment: "Button: quit the app that is slowing the Mac")
        case .forceQuit: return String(localized: "Force quit", comment: "Button: force quit the app that is slowing the Mac")
        case .freeSpace: return String(localized: "Free up", comment: "Button: free up disk space")
        case .quitIdleApps: return String(localized: "Quit idle", comment: "Button: quit apps that are not being used")
        case .batterySettings, .networkSettings: return String(localized: "Settings", comment: "Button: open System Settings")
        case .none: return nil
        }
    }
    /// The notification's text: whole sentences, since `fixLabel` can't be placed inside one in every language.
    public var notificationBody: String {
        switch fix {
        case .quit: return String(localized: "Open Artifloam from the leaf in the menu bar to quit.")
        case .forceQuit: return String(localized: "Open Artifloam from the leaf in the menu bar to force quit.")
        case .freeSpace: return String(localized: "Open Artifloam from the leaf in the menu bar to free up.")
        case .quitIdleApps: return String(localized: "Open Artifloam from the leaf in the menu bar to quit idle.")
        case .batterySettings, .networkSettings: return String(localized: "Open Artifloam from the leaf in the menu bar to settings.")
        case .none: return String(localized: "Open Artifloam from the leaf in the menu bar for details.")
        }
    }
}

/// Readings the health check needs. Durations are how long a condition has lasted, so short spikes never count.
public struct MacHealthInput: Sendable {
    public struct BusyApp: Sendable {
        public let pid: Int32, name: String, percent: Double, seconds: TimeInterval
        /// The app was asked to quit and is still running 10 s later.
        public let ignoredQuit: Bool
        public init(pid: Int32, name: String, percent: Double, seconds: TimeInterval, ignoredQuit: Bool = false) { self.pid = pid; self.name = name; self.percent = percent; self.seconds = seconds; self.ignoredQuit = ignoredQuit }
    }
    public var diskFree: UInt64 = 0, diskTotal: UInt64 = 0
    public var daysUntilFull: Int?
    public var pressure: MemoryPressure = .normal
    public var pressureHighFor: TimeInterval = 0
    public var swap: UInt64?
    public var ram: UInt64 = 0
    public var busyApp: BusyApp?
    public var thermal = "Normal"
    public var batteryHealth: Int?, batteryPercent: Int?
    public var onBattery = false
    public var uptime: TimeInterval = 0
    public var online = true
    public init() {}
}

public struct MacHealth: Equatable, Sendable {
    public let score: Int
    public let issues: [MacIssue]
    public var level: String { score >= 90 ? String(localized: "Smooth", comment: "Mac health level") : score >= 70 ? String(localized: "Busy", comment: "Mac health level") : String(localized: "Struggling", comment: "Mac health level") }
    static let sustained: TimeInterval = 300

    public static func evaluate(_ input: MacHealthInput) -> MacHealth {
        var issues = [MacIssue]()
        func minutes(_ seconds: TimeInterval) -> Int { max(1, Int(seconds / 60)) }
        if input.diskTotal > 0 {
            let used = 100 - Int(Double(input.diskFree) / Double(input.diskTotal) * 100)
            if used >= 90 {
                issues.append(MacIssue(kind: .storage, title: String(localized: "Disk \(used)% full"), flag: String(localized: "\(formattedBytes(input.diskFree)) left"), fix: .freeSpace, points: 12))
            } else if let days = input.daysUntilFull, days <= 14 {
                issues.append(MacIssue(kind: .storage, title: String(localized: "Disk full in about \(days) days"), flag: String(localized: "Full in ~\(days) days"), fix: .freeSpace, points: 8))
            }
        }
        if (input.pressure == .warning || input.pressure == .critical) && input.pressureHighFor >= sustained {
            issues.append(MacIssue(kind: .memory, title: String(localized: "Memory is under pressure"), flag: String(localized: "Pressure high · \(minutes(input.pressureHighFor)) min"), fix: .quitIdleApps, points: input.pressure == .critical ? 15 : 8))
        } else if let swap = input.swap, input.ram > 0, swap > input.ram / 2 {
            issues.append(MacIssue(kind: .memory, title: String(localized: "Swap uses \(formattedBytes(swap)) of disk"), flag: String(localized: "Swap \(formattedBytes(swap))"), fix: .quitIdleApps, points: 5))
        }
        if let app = input.busyApp, app.percent >= 80, app.seconds >= sustained {
            let fix: MacIssue.Fix = app.ignoredQuit ? .forceQuit(pid: app.pid) : .quit(pid: app.pid)
            // One core pinned for 10+ minutes is how a frozen app looks from outside. a guess, not proof;
            // macOS has no public "not responding" check, and a busy render or build can look the same.
            if app.ignoredQuit || (app.percent >= 90 && app.percent <= 110 && app.seconds >= 2 * sustained) {
                issues.append(MacIssue(kind: .cpu, title: String(localized: "\(app.name) may not be responding"), flag: String(localized: "Not responding? · \(minutes(app.seconds)) min"), fix: fix, points: 8))
            } else {
                issues.append(MacIssue(kind: .cpu, title: String(localized: "\(app.name) is busy for \(minutes(app.seconds)) min"), flag: String(localized: "\(app.name) \(Int(app.percent))% · \(minutes(app.seconds)) min"), fix: fix, points: 6))
            }
        }
        if input.thermal == "High" || input.thermal == "Critical" {
            issues.append(MacIssue(kind: .heat, title: String(localized: "Your Mac is slowing down to cool off"), flag: String(localized: "Running hot"), fix: .none, points: 8))
        }
        if let percent = input.batteryPercent, input.onBattery, percent < 20 {
            issues.append(MacIssue(kind: .battery, title: String(localized: "Battery at \(percent)%"), flag: String(localized: "\(percent)% left"), fix: .batterySettings, points: 3))
        } else if let health = input.batteryHealth, health < 80 {
            issues.append(MacIssue(kind: .battery, title: String(localized: "Battery holds \(health)% of its charge"), flag: String(localized: "Health \(health)%"), fix: .batterySettings, points: 4))
        }
        if input.uptime >= 7 * 86_400, let swap = input.swap, input.ram > 0, swap > input.ram / 4 {
            issues.append(MacIssue(kind: .restart, title: String(localized: "Restart suggested after \(Int(input.uptime / 86_400)) days"), flag: String(localized: "Restart suggested"), fix: .none, points: 5))
        }
        if !input.online {
            issues.append(MacIssue(kind: .network, title: String(localized: "No network connection"), flag: String(localized: "Offline"), fix: .networkSettings, points: 2))
        }
        // Stable sort keeps the order above for equal points.
        issues = issues.enumerated().sorted { $0.element.points != $1.element.points ? $0.element.points > $1.element.points : $0.offset < $1.offset }.map(\.element)
        return MacHealth(score: max(0, 100 - issues.reduce(0) { $0 + $1.points }), issues: issues)
    }
}

/// One free-space reading per day; the trend says when the disk would be full.
public enum DiskForecast {
    public struct Sample: Codable, Equatable, Sendable { public let day: Date; public let free: UInt64 }
    /// Adds today's reading (replacing an earlier one from today) and keeps the last 30 days.
    public static func record(free: UInt64, at date: Date = Date(), into samples: [Sample], calendar: Calendar = .current) -> [Sample] {
        let day = calendar.startOfDay(for: date)
        return Array((samples.filter { $0.day != day } + [Sample(day: day, free: free)]).sorted { $0.day < $1.day }.suffix(30))
    }
    /// nil unless free space has fallen over at least three days of the last two weeks.
    /// first-vs-last slope, not a regression; a big one-off download skews it until it ages out.
    public static func daysUntilFull(_ samples: [Sample], now: Date = Date()) -> Int? {
        let recent = samples.filter { $0.day >= now.addingTimeInterval(-14 * 86_400) }
        guard let first = recent.first, let last = recent.last, first.free > last.free else { return nil }
        let days = last.day.timeIntervalSince(first.day) / 86_400
        guard days >= 3 else { return nil }
        return Int(Double(last.free) / (Double(first.free - last.free) / days))
    }
}
