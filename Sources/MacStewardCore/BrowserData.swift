import Foundation
import AppKit

/// Regenerable browser storage, named by browser, profile, type and website.
/// Cookies, history, logins, bookmarks and extension data are never listed.
public struct BrowserItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let browser: String
    public let profile: String
    public let kind: String
    /// Website for site-specific data, nil for shared caches.
    public let site: String?
    public let bytes: UInt64
    /// Caches start ticked; website data and models need a person's choice.
    public let recommended: Bool
    /// Site storage (IndexedDB, Firefox site storage) can keep a sign-in or offline session; caches never do.
    public var mayHoldSignIn: Bool { site != nil }
    /// `kind` and the shared `profile` value stay English identifiers; these are what a person reads.
    public var kindTitle: String {
        switch kind {
        case "Code cache": return String(localized: "Code cache")
        case "GPU cache": return String(localized: "GPU cache")
        case "Graphics cache": return String(localized: "Graphics cache")
        case "WebGPU cache": return String(localized: "WebGPU cache")
        case "Shader cache": return String(localized: "Shader cache")
        case "Graphite shader cache": return String(localized: "Graphite shader cache")
        case "Component downloads": return String(localized: "Component downloads")
        case "On-device AI model": return String(localized: "On-device AI model")
        case "Web cache": return String(localized: "Web cache")
        case "Offline site cache": return String(localized: "Offline site cache")
        case "Website database": return String(localized: "Website database")
        default: return kind
        }
    }
    public var profileTitle: String { profile == "All profiles" ? String(localized: "All profiles") : profile }
}
public struct BrowserReport: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let bundleID: String
    public let items: [BrowserItem]
    /// false when macOS privacy settings hide the browser's folders (needs Full Disk Access).
    public let readable: Bool
}

public enum BrowserData {
    struct Chromium { let name: String; let bundleID: String; let support: String; let caches: String }
    static let chromium = [
        Chromium(name: "Arc", bundleID: "company.thebrowser.Browser", support: "Arc/User Data", caches: "Arc/User Data"),
        Chromium(name: "Dia", bundleID: "company.thebrowser.dia", support: "Dia/User Data", caches: "Dia/User Data"),
        Chromium(name: "Comet", bundleID: "ai.perplexity.comet", support: "Comet", caches: "Comet"),
        Chromium(name: "Google Chrome", bundleID: "com.google.Chrome", support: "Google/Chrome", caches: "Google/Chrome"),
        Chromium(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", support: "Microsoft Edge", caches: "Microsoft Edge"),
        Chromium(name: "Brave", bundleID: "com.brave.Browser", support: "BraveSoftware/Brave-Browser", caches: "BraveSoftware/Brave-Browser"),
        Chromium(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", support: "Vivaldi", caches: "Vivaldi")
    ]
    /// Shared, rebuilt-on-demand caches inside a profile (support folder) or the browser root.
    static let profileCaches = [("Code Cache", "Code cache"), ("GPUCache", "GPU cache"), ("DawnGraphiteCache", "Graphics cache"), ("DawnWebGPUCache", "WebGPU cache")]
    static let rootCaches = [("GrShaderCache", "Shader cache", true), ("GraphiteDawnCache", "Graphite shader cache", true), ("component_crx_cache", "Component downloads", true), ("OptGuideOnDeviceModel", "On-device AI model", false)]

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserReport] {
        let support = home.appendingPathComponent("Library/Application Support"), caches = home.appendingPathComponent("Library/Caches")
        var reports = chromium.compactMap { browser -> BrowserReport? in
            let data = support.appendingPathComponent(browser.support)
            guard FileManager.default.fileExists(atPath: data.path) else { return nil }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: data.path) else { return BrowserReport(name: browser.name, bundleID: browser.bundleID, items: [], readable: false) }
            let names = profileNames(data.appendingPathComponent("Local State"))
            var items = [BrowserItem]()
            func add(_ url: URL, profile: String, kind: String, site: String? = nil, recommended: Bool) {
                guard isRealDirectory(url) else { return }
                let bytes = allocatedSize(url)
                if bytes >= 100_000 { items.append(BrowserItem(url: url, browser: browser.name, profile: profile, kind: kind, site: site, bytes: bytes, recommended: recommended)) }
            }
            for (folder, kind, recommended) in rootCaches { add(data.appendingPathComponent(folder), profile: "All profiles", kind: kind, recommended: recommended) }
            let profiles = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            for profile in profiles {
                // Two profiles may share a name; the folder tells them apart.
                let name = names[profile] ?? profile
                let label = profiles.filter({ names[$0] == name }).count > 1 ? "\(name) (\(profile))" : name
                let directory = data.appendingPathComponent(profile)
                add(caches.appendingPathComponent(browser.caches).appendingPathComponent(profile).appendingPathComponent("Cache"), profile: label, kind: "Web cache", recommended: true)
                add(caches.appendingPathComponent(browser.caches).appendingPathComponent(profile).appendingPathComponent("Code Cache"), profile: label, kind: "Code cache", recommended: true)
                for (folder, kind) in profileCaches { add(directory.appendingPathComponent(folder), profile: label, kind: kind, recommended: true) }
                // Offline copies sites saved with Service Workers. ScriptCache is skipped: removing it can break extensions.
                add(directory.appendingPathComponent("Service Worker/CacheStorage"), profile: label, kind: "Offline site cache", recommended: false)
                for entry in children(directory.appendingPathComponent("IndexedDB")) {
                    guard let site = site(fromChromium: entry.lastPathComponent) else { continue }
                    add(entry, profile: label, kind: "Website database", site: site, recommended: false)
                }
            }
            return BrowserReport(name: browser.name, bundleID: browser.bundleID, items: items.sorted { $0.bytes > $1.bytes }, readable: true)
        }
        if let firefox = firefoxReport(support: support, caches: caches) { reports.append(firefox) }
        let safari = caches.appendingPathComponent("com.apple.Safari")
        if FileManager.default.fileExists(atPath: safari.path) {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: safari.path)) != nil
            let bytes = readable ? allocatedSize(safari) : 0
            reports.append(BrowserReport(name: "Safari", bundleID: "com.apple.Safari", items: bytes > 100_000 ? [BrowserItem(url: safari, browser: "Safari", profile: "All profiles", kind: "Web cache", site: nil, bytes: bytes, recommended: true)] : [], readable: readable))
        }
        return reports
    }
    static func firefoxReport(support: URL, caches: URL) -> BrowserReport? {
        let profiles = support.appendingPathComponent("Firefox/Profiles")
        guard FileManager.default.fileExists(atPath: profiles.path) else { return nil }
        var items = [BrowserItem]()
        for profile in children(profiles) {
            let label = profile.lastPathComponent.split(separator: ".").dropFirst().joined(separator: ".")
            let cache = caches.appendingPathComponent("Firefox/Profiles").appendingPathComponent(profile.lastPathComponent).appendingPathComponent("cache2")
            if isRealDirectory(cache) { items.append(BrowserItem(url: cache, browser: "Firefox", profile: label, kind: "Web cache", site: nil, bytes: allocatedSize(cache), recommended: true)) }
            for entry in children(profile.appendingPathComponent("storage/default")) {
                guard let site = site(fromFirefox: entry.lastPathComponent), isRealDirectory(entry) else { continue }
                let bytes = allocatedSize(entry)
                if bytes >= 100_000 { items.append(BrowserItem(url: entry, browser: "Firefox", profile: label, kind: "Website database", site: site, bytes: bytes, recommended: false)) }
            }
        }
        return BrowserReport(name: "Firefox", bundleID: "org.mozilla.firefox", items: items.sorted { $0.bytes > $1.bytes }, readable: true)
    }
    static func profileNames(_ localState: URL) -> [String: String] {
        guard let data = BoundedFile.read(localState, limit: 16 << 20), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }
    /// `https_mail.google.com_0.indexeddb.leveldb` → `mail.google.com`. Extensions are not websites and are skipped.
    static func site(fromChromium name: String) -> String? {
        let parts = name.components(separatedBy: "_")
        guard parts.count >= 3, ["http", "https"].contains(parts[0]) else { return nil }
        return parts[1...(parts.count - 2)].joined(separator: "_")
    }
    /// `https+++www.example.com` (optionally `^userContextId…`) → `www.example.com`.
    static func site(fromFirefox name: String) -> String? {
        guard name.hasPrefix("https+++") || name.hasPrefix("http+++") else { return nil }
        let host = name.components(separatedBy: "+++").last?.components(separatedBy: "^").first ?? ""
        return host.isEmpty ? nil : host.components(separatedBy: "+").first
    }
    static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
    public static func isRunning(_ bundleID: String) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID } }

    /// Permanently removes the chosen items. Each must still be in a fresh scan, and its browser must be closed.
    public static func clean(_ paths: Set<String>, home: URL = FileManager.default.homeDirectoryForCurrentUser, activity: ActivitySnapshot = .capture(), ignoredPaths: [String] = []) -> (removed: [String], skipped: [String]) {
        var removed = [String](), skipped = [String]()
        let current = scan(home: home)
        for report in current {
            let chosen = report.items.filter { paths.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            if isRunning(report.bundleID) { skipped += chosen.map { String(localized: "\($0.browser) is open: \($0.kindTitle)") }; continue }
            for item in chosen {
                if ignoredPaths.contains(where: { item.id == $0 || item.id.hasPrefix($0 + "/") }) { skipped.append(String(localized: "\(item.browser) \(item.kindTitle): on your keep list")); continue }
                // A browser under another bundle identifier, or a helper still running, shows up here.
                guard activity.reliable, !activity.isActive(item.url) else { skipped.append(String(localized: "\(item.browser) \(item.kindTitle): still in use")); continue }
                do { try SecureRemoval.remove(item.url, tree: try TreeInventory.read(item.url, dependencies: true)); removed.append(item.id) }
                catch { skipped.append(String(localized: "\(item.browser) \(item.kindTitle): \(error.localizedDescription)")) }
            }
        }
        let known = Set(current.flatMap(\.items).map(\.id))
        skipped += paths.subtracting(known).map { path in let name = URL(fileURLWithPath: path).lastPathComponent; return String(localized: "No longer present: \(name)") }
        return (removed, skipped)
    }
}
