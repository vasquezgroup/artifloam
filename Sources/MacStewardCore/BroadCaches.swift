import Foundation
import AppKit

/// Standard cache locations: ~/Library/Caches (which macOS itself may purge), ~/.cache, and
/// iOS Simulator downloads. Each item is still rechecked: owner closed, nothing open, untouched lately.
public enum BroadCaches {
    /// Browsers have their own tool; the rest hold data that is slow or impossible to rebuild,
    /// or belong to the system and its sync services.
    static let skippedAppCaches: Set<String> = ["Arc", "Google", "BraveSoftware", "Microsoft Edge", "Dia", "Comet", "Firefox", "Vivaldi", "com.operasoftware.Opera",
                                                "CloudKit", "FamilyCircle", "Homebrew", "pip", "pnpm", "ms-playwright", "ms-playwright-go", "JetBrains", "Cypress", StewardPreferences.domain, StewardPreferences.legacyDomain, "MacSteward"]
    static let skippedXDGCaches: Set<String> = ["huggingface", "torch", "lm-studio", "ms-playwright", "mole", "whisper"]

    /// Caches their own tools document as disposable. The broad scan offers any folder for review, because it can't know
    /// what an unknown tool keeps there; only these go without asking. Add one only after checking that tool.
    static let knownAppCaches: Set<String> = ["org.swift.swiftpm", "CocoaPods", "Yarn", "go-build", "node-gyp", "typescript", "electron", "electron-builder", "org.carthage.CarthageKit"]
    static let knownXDGCaches: Set<String> = ["pre-commit", "uv", "black", "ruff", "node-gyp", "yarn", "typescript", "go-build"]
    static func knownRebuildable(rule: String, name: String) -> Bool {
        switch rule {
        case "app-cache": return knownAppCaches.contains(name) || name.hasSuffix(".ShipIt") // Update downloads kept by Electron's updater.
        case "xdg-cache": return knownXDGCaches.contains(name)
        default: return false
        }
    }
    static func appCacheCandidates(home: URL) -> [URL] {
        children(home.appendingPathComponent("Library/Caches")).filter { allowedAppCache($0.lastPathComponent) }
    }
    static func allowedAppCache(_ name: String) -> Bool {
        // A bare "com" or "com.apple" names no app: it would match every app under that prefix.
        let lower = name.lowercased()
        return !name.hasPrefix(".") && !lower.hasPrefix("com.apple.") && !["com", "com.apple", "org", "net", "io"].contains(lower) && !skippedAppCaches.contains(name)
    }
    static func xdgCandidates(home: URL) -> [URL] {
        children(home.appendingPathComponent(".cache")).filter { !$0.lastPathComponent.hasPrefix(".") && !skippedXDGCaches.contains($0.lastPathComponent) }
    }
    /// Downloaded assets and app caches inside each simulator, with a readable device label.
    static func simulatorCandidates(home: URL) -> [(url: URL, label: String)] {
        children(home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")).flatMap { device -> [(URL, String)] in
            let info = BoundedFile.read(device.appendingPathComponent("device.plist")).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let name = info?["name"] as? String ?? device.lastPathComponent
            let runtime = (info?["runtime"] as? String)?.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "iOS.", with: "iOS ") ?? ""
            let label = runtime.isEmpty ? name : "\(name) · \(runtime)"
            return [("data/private/var/MobileAsset/AssetsV2", "downloaded assets"), ("data/Library/Caches", "app caches")].compactMap { relative, kind in
                let url = device.appendingPathComponent(relative)
                return FileManager.default.fileExists(atPath: url.path) ? (url, "\(label) · \(kind)") : nil
            }
        }
    }
    static func validSimulatorPath(_ url: URL, home: URL) -> Bool {
        let base = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices").path + "/"
        guard url.path.hasPrefix(base) else { return false }
        let rest = String(url.path.dropFirst(base.count)).split(separator: "/").map(String.init)
        guard let device = rest.first, UUID(uuidString: device) != nil else { return false }
        return Array(rest.dropFirst()) == ["data", "private", "var", "MobileAsset", "AssetsV2"] || Array(rest.dropFirst()) == ["data", "Library", "Caches"]
    }
    /// The app that owns a ~/Library/Caches folder is running: matched by bundle identifier or app name.
    static func ownerRunning(_ name: String, running: [(id: String, name: String)]) -> Bool { running.contains { owns(cache: name, bundleID: $0.id, appName: $0.name) } }
    /// The running app (its name) that owns the cache folder `name`, if any.
    static func owner(of name: String, running: [(id: String, name: String)]) -> String? {
        running.first { quitsFor(cache: name, bundleID: $0.id, appName: $0.name) }?.name
    }
    /// Stricter than `owns`: the exact app, or a family named by whole word ("Adobe" for "Adobe Photoshop"), since the confirmation
    /// names every app that quits. A bare prefix ("com", "com.microsoft") still counts as in use, but quits nothing.
    public static func quitsFor(cache: String, bundleID: String, appName: String) -> Bool {
        let key = cache.lowercased(), id = bundleID.lowercased()
        guard !key.isEmpty else { return false }
        let specific = key.split(separator: ".").count >= 3
        return (!id.isEmpty && (id == key || key.hasPrefix(id + ".") || (specific && id.hasPrefix(key + ".")))) || appName.lowercased() == key || appName.lowercased().hasPrefix(key + " ")
    }
    /// Whether an app with this bundle identifier or name owns the ~/Library/Caches folder `cache`.
    public static func owns(cache: String, bundleID: String, appName: String) -> Bool {
        let key = cache.lowercased(), id = bundleID.lowercased(), title = appName.lowercased()
        guard !key.isEmpty, !id.isEmpty || !title.isEmpty else { return false }
        return (!id.isEmpty && (id == key || id.hasPrefix(key + ".") || key.hasPrefix(id + "."))) || title == key || (key.count >= 4 && title.hasPrefix(key))
    }
    static func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier ?? "", $0.localizedName ?? "") }
    }
    static func simulatorRunning(_ activity: ActivitySnapshot) -> Bool {
        ["launchd_sim", "Simulator.app/", "simctl"].contains { activity.commandsContain($0) }
    }

    // MARK: Old Homebrew versions

    public static let brewOldVersionsRule = "homebrew-old-versions"
    /// Measured by reading the Cellar, never by running `brew`: that binary is writable by any process of this user,
    /// and a child of this app would inherit its access. `brew cleanup` runs in Terminal instead, with Terminal's access, in plain view.
    static let cellars = ["/opt/homebrew/Cellar", "/usr/local/Cellar"]
    /// Every installed version but the newest of each formula, except pinned ones, which Homebrew leaves alone too.
    static func oldVersions(cellar: URL) -> [URL] {
        let pinned = cellar.deletingLastPathComponent().appendingPathComponent("var/homebrew/pinned")
        return children(cellar).flatMap { formula -> [URL] in
            guard !FileManager.default.fileExists(atPath: pinned.appendingPathComponent(formula.lastPathComponent).path) else { return [] }
            let versions = children(formula).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
            guard versions.count > 1, let newest = versions.max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }) else { return [] }
            return versions.filter { $0 != newest }
        }
    }
    /// A Terminal script for a known Cellar only; the path comes from a finding, so nothing else can end up in the script.
    public static func brewCleanupScript(cellar: String) -> String? {
        guard cellars.contains(cellar) else { return nil }
        return "#!/bin/zsh\necho 'Artifloam asked Homebrew to remove old versions:'\n\((cellar as NSString).deletingLastPathComponent)/bin/brew cleanup --prune=30\n"
    }
}
