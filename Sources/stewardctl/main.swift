import Foundation
import MacStewardCore

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let usage = """
Artifloam — local, conservative storage care

stewardctl scan [--json] [--days N] [--developer-caches] [--diagnostic-logs] [--verbose]
stewardctl clean-safe [--days N]
stewardctl duplicates [--json]
stewardctl status

scan is read-only. clean-safe removes only allowlisted, ignored, untracked,
closed caches older than at least seven days, after fresh filesystem checks.
Worktrees, chat history, databases, source, original assets and release archives
are never automatically deleted. Receipts: ~/Library/Application Support/MacSteward/Receipts
"""
func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    print(String(data: try encoder.encode(value), encoding: .utf8)!)
}
do {
    var days = 7
    if let i = args.firstIndex(of: "--days") { guard i+1 < args.count, let n = Int(args[i+1]), n >= 7 else { throw StewardError.blocked("--days must be at least 7") }; days = n }
    var configuration = Configuration(minimumAgeDays: days, ignoredPaths: StewardPreferences.ignoredPaths, includeApplicationCaches: !args.contains("--scheduled") && args.contains("--app-caches"), includeDeveloperCaches: !args.contains("--scheduled") && args.contains("--developer-caches"), includeAdditionalLogs: !args.contains("--scheduled") && args.contains("--diagnostic-logs"), projectRoots: StewardPreferences.projectPaths.map { URL(fileURLWithPath: $0) }, claudeHome: StewardPreferences.defaults.string(forKey: "claudeHome").map { URL(fileURLWithPath: $0) }, codexHome: StewardPreferences.defaults.string(forKey: "codexHome").map { URL(fileURLWithPath: $0) })
    // An unattended run stays inside folders the person selected; discovered projects need them present.
    if ["scan", "clean-safe"].contains(command), !args.contains("--scheduled") {
        let known = KnownProjectDiscovery.discover(home: configuration.home, claudeHome: configuration.claudeHome, codexHome: configuration.codexHome)
        configuration.projectRoots = Configuration.canonicalProjectRoots(configuration.projectRoots + known.map(\.url))
    }
    switch command {
    case "scan", "clean-safe":
        let scanner = Scanner(configuration: configuration)
        let report = try scanner.scan { message in if args.contains("--verbose") { FileHandle.standardError.write(Data((message + "\n").utf8)) } }
        if command == "scan" {
            if args.contains("--json") { try emit(report) }
            else {
                print("Free: \(formattedBytes(report.disk.free)) • Eligible cache contents: \(formattedBytes(report.eligibleBytes))")
                for f in report.findings { print("\(f.safety.rawValue.uppercased()) \(formattedBytes(f.bytes)) \(f.path)\n  \(f.reason)") }
                for n in report.notices { print("NOTICE: \(n)") }
            }
        } else {
            // Scheduled jobs independently verify that the user enabled the LaunchAgent.
            if args.contains("--scheduled") && !Scheduler.isInstalled { throw StewardError.blocked("Automatic cleanup has not been enabled") }
            // Project dependencies need a person's choice; scheduled and CLI cleanup skip them.
            // Broad cache rules and tool commands need a person's choice in the app; the schedule keeps to the narrow allowlist.
            let eligible = Set(report.findings.filter { $0.safety == .automatic && $0.group != .inactiveDependencies && !["app-cache", "xdg-cache", "simulator-cache", "homebrew-cache"].contains($0.rule) }.map(\.id))
            let receipt = try Cleaner(configuration: configuration).clean(report, selectedIDs: eligible)
            try emit(receipt)
        }
    case "duplicates": try emit(DuplicateFinder.scan())
    case "status": try emit(DiskSpace.read())
    case "browsers":
        // Read-only: what each browser stores, by profile, type and website.
        for report in BrowserData.scan() {
            print("\(report.name)\(report.readable ? "" : " (needs Full Disk Access)") · \(formattedBytes(report.items.reduce(0) { $0 + $1.bytes }))")
            for item in report.items.prefix(12) { print("  \(item.recommended ? "[x]" : "[ ]") \(formattedBytes(item.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.profile) · \(item.kind)\(item.site.map { " · " + $0 } ?? "")") }
        }
    case "leftovers":
        // Read-only: lists support files of apps that are no longer installed.
        let known = AppLeftovers.knownIdentifiers()
        for item in AppLeftovers.scan(installed: known.installed, referenced: known.referenced, activity: .capture()) { print("\(item.bytes)\t\(item.vendorInstalled ? "shared?" : "ticked")\t\(item.kind)\t\(item.url.path)") }
    case "help", "--help", "-h": print(usage)
    default: throw StewardError.blocked("Unknown command.\n\(usage)")
    }
} catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
