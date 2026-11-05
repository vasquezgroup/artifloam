import Foundation

/// Producer-owned web caches only; personal app data and unknown cache layouts stay out.
enum ApplicationWebCaches {
    static let locations: [(path: String, producer: String)] = [
        ("Library/Caches/Google/Chrome/Default/Cache/Cache_Data", "Google Chrome.app/"),
        ("Library/Caches/Microsoft Edge/Default/Cache/Cache_Data", "Microsoft Edge.app/"),
        ("Library/Application Support/Claude/Cache/Cache_Data", "Claude.app/"),
        ("Library/Application Support/ChatGPT/Cache/Cache_Data", "ChatGPT.app/")
    ]
    static func valid(_ url: URL, home: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("index"), url.pathExtension != "lock",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return locations.contains { url.deletingLastPathComponent().path == home.appendingPathComponent($0.path).path }
    }
    static func producerActive(_ url: URL, home: URL, activity: ActivitySnapshot) -> Bool {
        locations.contains { url.deletingLastPathComponent().path == home.appendingPathComponent($0.path).path && activity.commandsContain($0.producer) }
    }
}
