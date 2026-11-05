import Foundation

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
    /// Which of four rhythms it keeps, for "when your agents run".
    public var rhythm: String {
        if schedule == "Always running" { return "Always running" }
        if schedule.hasPrefix("Every") || schedule.hasPrefix("Daily") || schedule.hasPrefix("Weekly") { return "On a schedule" }
        if schedule.hasPrefix("At login") { return "At login" }
        return "When needed"
    }
    /// Wakes the Mac over and over: every few minutes or more often.
    public var runsOften: Bool {
        schedule.hasSuffix("second") || schedule.hasSuffix("seconds") || schedule == "Every minute" || (schedule.hasSuffix("minutes") && (Int(schedule.split(separator: " ").dropFirst().first ?? "") ?? 99) <= 5)
    }
    /// What it does and when it runs: "Runs server.mjs from teams-presence · Always running".
    public var summary: String { what + " · " + schedule }

    private var what: String {
        let name = URL(fileURLWithPath: program).lastPathComponent
        let servers = ["mysqld": "MySQL database server", "mysqld_safe": "MySQL database server", "redis-server": "Redis database server", "postgres": "PostgreSQL database server", "pg_ctl": "PostgreSQL database server", "mongod": "MongoDB database server", "php-fpm": "PHP server for local websites", "nginx": "Nginx web server", "httpd": "Apache web server", "dnsmasq": "Local DNS server", "ollama": "Ollama, runs AI models locally"]
        if let server = servers[name] { return server }
        if let script = scriptPath { return "Runs \(URL(fileURLWithPath: script).lastPathComponent) from \(Self.home(ofScript: script))" }
        let who = maker.name
        if who == "Homebrew" { return "\(maker.rest) service, installed with Homebrew" }
        let text = label.lowercased()
        if text.contains("uninstall") { return "Part of the \(who) uninstaller" }
        if text.contains("updat") { return "Keeps \(who) up to date" }
        if text.contains("licens") { return "Checks your \(who) license" }
        if text.contains("install") { return "Installs \(who) components" }
        if text.contains("report") { return "Sends reports to \(who)" }
        if text.contains("sync") { return "Syncs files for \(who)" }
        if text.contains("launcher") { return "Starts \(who) apps" }
        if text.contains("helper") { return scope == "Your account" ? "Helper for \(who)" : "Lets \(who) do tasks that need admin rights" }
        if ["agent", "daemon", "service", "assistant"].contains(where: text.contains) { return "Runs \(who) in the background" }
        return label == who ? "Background program" : "Background program from \(who)"
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
    static func schedule(_ info: [String: Any], scope: String) -> String {
        if info["KeepAlive"] as? Bool == true { return "Always running" }
        if let seconds = info["StartInterval"] as? Int { return every(seconds) }
        if let time = info["StartCalendarInterval"] as? [String: Int] {
            guard let hour = time["Hour"] else { return "On a schedule" }
            let clock = String(format: "%02d:%02d", hour, time["Minute"] ?? 0)
            return time["Weekday"] != nil ? "Weekly at \(clock)" : time["Day"] != nil ? "Monthly at \(clock)" : "Daily at \(clock)"
        }
        if info["StartCalendarInterval"] != nil { return "On a schedule" }
        if info["WatchPaths"] != nil { return "When certain files change" }
        let start = scope == "Your account" ? "At login" : "At startup"
        let starts = info["RunAtLoad"] as? Bool == true
        if info["KeepAlive"] != nil { return (starts ? start : "When needed") + ", restarts if it stops" }
        return starts ? start : "Only when needed"
    }
    private static func every(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return seconds == 86400 ? "Every day" : "Every \(seconds / 86400) days" }
        if seconds % 3600 == 0 { return seconds == 3600 ? "Every hour" : "Every \(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "Every minute" : "Every \(seconds / 60) minutes" }
        return "Every \(seconds) seconds"
    }
}
