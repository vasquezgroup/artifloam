import Foundation

public struct KnownProject: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let sources: [String]
}

/// Reads path fields from bounded, known metadata files only. No conversations,
/// shell profiles, SQLite databases or recursive home-directory search.
public enum KnownProjectDiscovery {
    private static func object(_ url: URL) -> [String: Any] {
        guard BoundedFile.isRegular(url), let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        let limit = 8 * 1024 * 1024
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public static func discover(home: URL, claudeHome: URL, codexHome: URL) -> [KnownProject] {
        var paths: [String: Set<String>] = [:]
        func add(_ value: String, source: String) {
            guard value.hasPrefix("/"), !value.contains("\n"), !value.contains("\0") else { return }
            let url = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
            // Never turn a broad personal/system root into a suggested scan location.
            guard url.pathComponents.count > 2, url != home.resolvingSymlinksInPath(),
                  !["Documents", "Desktop", "Downloads", "Library"].contains(where: { url == home.appendingPathComponent($0).resolvingSymlinksInPath() }) else { return }
            paths[url.path, default: []].insert(source)
        }
        let state = object(codexHome.appendingPathComponent(".codex-global-state.json"))
        for key in ["electron-saved-workspace-roots", "active-workspace-roots"] {
            for path in state[key] as? [String] ?? [] { add(path, source: "Codex") }
        }
        for project in (state["local-projects"] as? [String: [String: Any]] ?? [:]).values {
            for path in project["rootPaths"] as? [String] ?? [] { add(path, source: "Codex") }
        }
        // Claude's legacy default config sits beside .claude; custom homes keep
        // their config inside the selected directory. Only project keys are used.
        var configs = [claudeHome.appendingPathComponent(".claude.json")]
        if claudeHome.standardizedFileURL == home.appendingPathComponent(".claude").standardizedFileURL {
            configs.append(home.appendingPathComponent(".claude.json"))
        }
        for config in configs {
            for path in (object(config)["projects"] as? [String: Any] ?? [:]).keys { add(path, source: "Claude Code") }
        }
        // Older Claude versions also expose explicit projectPath fields in indexes.
        let projects = claudeHome.appendingPathComponent("projects")
        let directories = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        for directory in directories.sorted(by: { $0.path < $1.path }).prefix(1000) {
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let index = object(directory.appendingPathComponent("sessions-index.json"))
            if let path = index["originalPath"] as? String { add(path, source: "Claude Code") }
            for entry in index["entries"] as? [[String: Any]] ?? [] {
                if let path = entry["projectPath"] as? String { add(path, source: "Claude Code") }
            }
        }
        let candidates = paths.keys.sorted().prefix(1000).filter { path in
            let url = URL(fileURLWithPath: path)
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.isReadableFile(atPath: path)
                && FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        }
        if Task.isCancelled { return [] }
        // Each Git check is its own process; they run side by side.
        return parallelMap(candidates) { path -> KnownProject? in
            let validation = git(URL(fileURLWithPath: path), ["rev-parse", "--is-inside-work-tree"])
            guard validation.code == 0, validation.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
            return KnownProject(url: URL(fileURLWithPath: path), sources: paths[path]!.sorted())
        }.compactMap { $0 }
    }
}
