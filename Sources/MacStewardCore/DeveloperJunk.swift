import Foundation

/// Fixed producer-owned locations only. No whole-disk cache-name heuristics.
enum DeveloperJunk {
    static func minimumAge(rule: String, configured: Int) -> Int {
        if ["app-cache", "xdg-cache"].contains(rule) { return 2 }
        return ["old-user-log", "gradle-generated-cache", "xcode-module-cache", "npm-cache", "homebrew-cache", "inactive-dependencies"].contains(rule) ? max(30, configured) : configured
    }
    static func producerActive(rule: String, path: String, activity: ActivitySnapshot) -> Bool {
        func running(_ names: [String]) -> Bool { names.contains { activity.commandsContain($0, ignoringCase: true) } }
        if rule == "gradle-generated-cache" { return running(["gradledaemon", "org.gradle", "kotlincompiledaemon"]) }
        if rule == "homebrew-cache" { return running(["homebrew/brew."]) }
        if rule == "xcode-module-cache" { return running(["xcodebuild", "swift-frontend", "/clang", "sourcekit"]) }
        if rule == "old-user-log" && path.contains("/Logs/NGL/") { return running(["adobe", "coresync", "cclibrary", "creative cloud", "acrobat"]) }
        if rule == "old-user-log" && path.contains("/Logs/Diagnostics/") { return running(["microsoft word", "microsoft excel", "microsoft powerpoint"]) }
        return false
    }
    static func hasGradleMarker(home: URL) -> Bool {
        let marker = home.appendingPathComponent(".gradle/caches/CACHEDIR.TAG")
        guard (try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              BoundedFile.isRegular(marker), let handle = try? FileHandle(forReadingFrom: marker) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 80), let text = String(data: data, encoding: .utf8) else { return false }
        return text.hasPrefix("Signature: 8a477f597d28d172789f06886806bc55")
    }
    static func validGradlePath(_ url: URL, home: URL) -> Bool {
        let base = home.appendingPathComponent(".gradle/caches").path + "/"
        guard url.path.hasPrefix(base) else { return false }
        let parts = String(url.path.dropFirst(base.count)).split(separator: "/").map(String.init)
        func hash(_ value: String) -> Bool { value.count == 32 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        func version(_ value: String) -> Bool {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            return (2...3).contains(pieces.count) && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
        if parts.count == 2 { return ["transforms-3", "transforms-4"].contains(parts[0]) && hash(parts[1]) }
        guard parts.count == 3, version(parts[0]) else { return false }
        if parts[1] == "transforms" { return hash(parts[2]) }
        return parts[1] == "generated-gradle-jars" && parts[2].hasSuffix(".jar") && ["gradle-api-", "gradle-kotlin-dsl-extensions-"].contains { parts[2].hasPrefix($0) }
    }
    static func gradleCandidates(home: URL) -> [URL] {
        guard hasGradleMarker(home: home) else { return [] }
        let base = home.appendingPathComponent(".gradle/caches")
        var candidates = [URL]()
        for folder in children(base) {
            if ["transforms-3", "transforms-4"].contains(folder.lastPathComponent) { candidates += children(folder) }
            else {
                candidates += children(folder.appendingPathComponent("transforms"))
                candidates += children(folder.appendingPathComponent("generated-gradle-jars"))
            }
        }
        return candidates.filter { validGradlePath($0, home: home) }
    }
    static func validLog(relative: String) -> Bool {
        guard relative.hasSuffix(".log") else { return false }
        if relative.hasPrefix("Library/Logs/CoreSimulator/") { return true }
        if relative.hasPrefix("Library/Logs/NGL/") {
            return relative.split(separator: "/").count == 4 && URL(fileURLWithPath: relative).lastPathComponent.hasPrefix("NGLClient_")
        }
        return ["com.microsoft.Word": "WORD", "com.microsoft.Excel": "EXCEL", "com.microsoft.Powerpoint": "POWERPNT"].contains { bundle, app in
            relative.hasPrefix("Library/Containers/\(bundle)/Data/Library/Logs/Diagnostics/\(app)/")
        }
    }

    /// Folders where AI tools keep one sub-folder per installed version.
    static func agentVersionRoots(home: URL) -> [URL] {
        ["Library/Application Support/Claude/claude-code", "Library/Application Support/Claude/claude-code-vm", ".local/share/claude/versions", ".local/share/cursor-agent/versions"].map { home.appendingPathComponent($0) }
    }
    /// Every version except the newest; the newest is what the tool runs next.
    static func oldAgentVersions(in root: URL) -> [URL] {
        let versions = children(root).filter { $0.lastPathComponent.first?.isNumber == true }
        guard versions.count > 1 else { return [] }
        let newest = versions.max { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }!
        return versions.filter { $0 != newest }
    }
}

