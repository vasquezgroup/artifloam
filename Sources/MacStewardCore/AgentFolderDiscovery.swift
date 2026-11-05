import Foundation

/// Resolve known tool locations without reading shell profiles or searching personal files.
public struct AgentFolderDiscovery: Sendable {
    public enum State: Sendable { case found, missing, inaccessible, notDirectory }
    public enum Source: Sendable { case selected, environment, standard }
    public let url: URL
    public let state: State
    public let source: Source

    public static func location(home: URL, directoryName: String, environmentKey: String, environment: [String: String], selected: URL? = nil) -> (URL, Source) {
        resolve(home: home, directoryName: directoryName, environmentKey: environmentKey, environment: environment, selected: selected)
    }

    private static func resolve(home: URL, directoryName: String, environmentKey: String,
                               environment: [String: String], selected: URL? = nil) -> (URL, Source) {
        let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = override.flatMap { value -> URL? in
            guard !value.isEmpty else { return nil }
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            // Relative environment paths are not stable for a GUI app's working directory.
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value)
        }
        let url = selected ?? configured ?? home.appendingPathComponent(directoryName)
        let source: Source = selected != nil ? .selected : (configured != nil ? .environment : .standard)
        return (url, source)
    }

    public static func inspect(home: URL, directoryName: String, environmentKey: String, environment: [String: String], selected: URL? = nil) -> Self {
        let (url, source) = resolve(home: home, directoryName: directoryName, environmentKey: environmentKey, environment: environment, selected: selected)
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return Self(url: url, state: .notDirectory, source: source) }
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return Self(url: url, state: .found, source: source)
        } catch {
            let error = error as NSError
            let missing = error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            return Self(url: url, state: missing ? .missing : .inaccessible, source: source)
        }
    }
}
