import Foundation

/// When launchd starts an agent, read from its plist. Logic reads the case; only `title` is for people.
public enum BackgroundSchedule: Sendable, Equatable {
    case alwaysRunning, onSchedule, whenFilesChange, whenNeeded, whenNeededRestarting
    case every(seconds: Int)
    /// The time is "05:00", as launchd has it.
    case daily(String), weekly(String), monthly(String)
    case atLogin(restarting: Bool), atStartup(restarting: Bool)

    public var title: String {
        switch self {
        case .alwaysRunning: return String(localized: "Always running")
        case .onSchedule: return String(localized: "On a schedule")
        case .whenFilesChange: return String(localized: "When certain files change")
        case .whenNeeded: return String(localized: "Only when needed")
        case .whenNeededRestarting: return String(localized: "When needed, restarts if it stops")
        case .every(let seconds):
            if seconds % 86400 == 0 { return seconds == 86400 ? String(localized: "Every day") : String(localized: "Every \(seconds / 86400) days") }
            if seconds % 3600 == 0 { return seconds == 3600 ? String(localized: "Every hour") : String(localized: "Every \(seconds / 3600) hours") }
            if seconds % 60 == 0 { return seconds == 60 ? String(localized: "Every minute") : String(localized: "Every \(seconds / 60) minutes") }
            return String(localized: "Every \(seconds) seconds")
        case .daily(let clock): return String(localized: "Daily at \(clock)")
        case .weekly(let clock): return String(localized: "Weekly at \(clock)")
        case .monthly(let clock): return String(localized: "Monthly at \(clock)")
        case .atLogin(let restarting): return restarting ? String(localized: "At login, restarts if it stops") : String(localized: "At login")
        case .atStartup(let restarting): return restarting ? String(localized: "At startup, restarts if it stops") : String(localized: "At startup")
        }
    }
}

/// Plain-language descriptions of launch agents, read from their plist: what they run and when. No network and no AI.
/// The "what" for app agents is a keyword match on the label, so it can be generic.
extension BackgroundItem {
    /// Labels name their maker: com.adobe.ARMDC.Communicator is ("Adobe", "ARMDC.Communicator").
    public var maker: (name: String, rest: String) {
        if label.hasPrefix("homebrew.mxcl.") { return ("Homebrew", String(label.dropFirst(14))) }
        if label.hasPrefix("sh.brew.") { return ("Homebrew", String(label.dropFirst(8))) }
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 3, parts[0].count <= 3 else { return (label, "") }
        return (parts[1].prefix(1).uppercased() + parts[1].dropFirst(), parts.dropFirst(2).joined(separator: "."))
    }
    /// The app this item belongs to, when it lives inside one.
    public var appPath: String? {
        let parts = program.components(separatedBy: "/")
        return parts.firstIndex { $0.hasSuffix(".app") }.map { parts[...$0].joined(separator: "/") }
    }
    /// Which of four rhythms it keeps, for "when your agents run". An identifier: people see `rhythmTitle(_:)`.
    public var rhythm: String {
        switch schedule {
        case .alwaysRunning: return "Always running"
        case .every, .daily, .weekly: return "On a schedule"
        case .atLogin: return "At login"
        default: return "When needed"
        }
    }
    public static func rhythmTitle(_ rhythm: String) -> String {
        switch rhythm {
        case "Always running": return String(localized: "Always running")
        case "On a schedule": return String(localized: "On a schedule")
        case "At login": return String(localized: "At login")
        case "When needed": return String(localized: "When needed")
        default: return rhythm
        }
    }
    /// `scope` is an identifier; this is what people see.
    public var scopeTitle: String {
        switch scope {
        case "Your account": return String(localized: "Your account")
        case "All users": return String(localized: "All users")
        case "System service": return String(localized: "System service")
        default: return scope
        }
    }
    /// Wakes the Mac over and over: every few minutes or more often.
    public var runsOften: Bool {
        guard case .every(let seconds) = schedule, seconds % 3600 != 0 else { return false }
        return seconds % 60 != 0 || seconds / 60 <= 5
    }
    /// What it does and when it runs: "Runs server.mjs from teams-presence · Always running".
    public var summary: String { what + " · " + schedule.title }

    private var what: String {
        let name = URL(fileURLWithPath: program).lastPathComponent
        let servers = ["mysqld": String(localized: "MySQL database server"), "mysqld_safe": String(localized: "MySQL database server"), "redis-server": String(localized: "Redis database server"), "postgres": String(localized: "PostgreSQL database server"), "pg_ctl": String(localized: "PostgreSQL database server"), "mongod": String(localized: "MongoDB database server"), "php-fpm": String(localized: "PHP server for local websites"), "nginx": String(localized: "Nginx web server"), "httpd": String(localized: "Apache web server"), "dnsmasq": String(localized: "Local DNS server"), "ollama": String(localized: "Ollama, runs AI models locally")]
        if let server = servers[name] { return server }
        if let script = scriptPath { return String(localized: "Runs \(URL(fileURLWithPath: script).lastPathComponent) from \(Self.home(ofScript: script))") }
        let who = maker.name
        if who == "Homebrew" { return String(localized: "\(maker.rest) service, installed with Homebrew") }
        let text = label.lowercased()
        if text.contains("uninstall") { return String(localized: "Part of the \(who) uninstaller") }
        if text.contains("updat") { return String(localized: "Keeps \(who) up to date") }
        if text.contains("licens") { return String(localized: "Checks your \(who) license") }
        if text.contains("install") { return String(localized: "Installs \(who) components") }
        if text.contains("report") { return String(localized: "Sends reports to \(who)") }
        if text.contains("sync") { return String(localized: "Syncs files for \(who)") }
        if text.contains("launcher") { return String(localized: "Starts \(who) apps") }
        if text.contains("helper") { return scope == "Your account" ? String(localized: "Helper for \(who)") : String(localized: "Lets \(who) do tasks that need admin rights") }
        if ["agent", "daemon", "service", "assistant"].contains(where: text.contains) { return String(localized: "Runs \(who) in the background") }
        return label == who ? String(localized: "Background program") : String(localized: "Background program from \(who)")
    }
    /// The script an interpreter was told to run, if this agent is one.
    private var scriptPath: String? {
        let interpreters = ["node", "python", "python3", "bash", "sh", "zsh", "ruby", "perl", "deno", "bun", "env"]
        guard interpreters.contains(URL(fileURLWithPath: program).lastPathComponent) else { return nil }
        return arguments.dropFirst().first { $0.hasPrefix("/") || $0.hasPrefix("~") }
    }
    /// Which project or app a script belongs to, rather than its immediate folder ("scripts", "dist"…).
    private static func home(ofScript path: String) -> String {
        let parts = path.components(separatedBy: "/")
        for marker in ["projects", "Application Support", "share"] {
            if let index = parts.firstIndex(of: marker), index + 2 < parts.count { return parts[index + 1] }
        }
        return parts.dropLast().last ?? path
    }
    /// When launchd starts it, from the plist's own keys.
    static func schedule(_ info: [String: Any], scope: String) -> BackgroundSchedule {
        if info["KeepAlive"] as? Bool == true { return .alwaysRunning }
        if let seconds = info["StartInterval"] as? Int { return .every(seconds: seconds) }
        if let time = info["StartCalendarInterval"] as? [String: Int] {
            guard let hour = time["Hour"] else { return .onSchedule }
            let clock = String(format: "%02d:%02d", hour, time["Minute"] ?? 0)
            return time["Weekday"] != nil ? .weekly(clock) : time["Day"] != nil ? .monthly(clock) : .daily(clock)
        }
        if info["StartCalendarInterval"] != nil { return .onSchedule }
        if info["WatchPaths"] != nil { return .whenFilesChange }
        let starts = info["RunAtLoad"] as? Bool == true, restarting = info["KeepAlive"] != nil
        if starts { return scope == "Your account" ? .atLogin(restarting: restarting) : .atStartup(restarting: restarting) }
        return restarting ? .whenNeededRestarting : .whenNeeded
    }
}
