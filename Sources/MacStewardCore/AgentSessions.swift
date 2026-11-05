import Foundation

/// When a Claude Code or Codex session last wrote its transcript, keyed by the session's working folder.
/// Reads file dates and the first Codex line only; conversation content is never parsed.
private extension Character { var isLetterOrNumberASCII: Bool { isASCII && (isLetter || isNumber) } }
public struct AgentSessionIndex: Sendable {
    var claude: [String: Date] = [:]
    var codex: [String: Date] = [:]
    public init() {}

    public static func load(claudeHome: URL, codexHome: URL, now: Date = Date(), days: Int = 90) -> AgentSessionIndex {
        var index = AgentSessionIndex()
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        // Claude Code stores ~/.claude/projects/<folder with every non-alphanumeric character as "-">/<session>.jsonl.
        for folder in children(claudeHome.appendingPathComponent("projects")) {
            let newest = children(folder).filter { $0.pathExtension == "jsonl" }.compactMap(modified).max()
            if let newest, newest > cutoff { index.claude[folder.lastPathComponent] = newest }
        }
        // Codex stores ~/.codex/sessions/YYYY/MM/DD/*.jsonl; the first line is session_meta with the cwd.
        let sessions = codexHome.appendingPathComponent("sessions")
        if let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files where file.pathExtension == "jsonl" {
                guard let date = modified(file), date > cutoff, let cwd = firstLineCwd(file) else { continue }
                let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
                index.codex[path] = max(index.codex[path] ?? .distantPast, date)
            }
        }
        return index
    }
    static func firstLineCwd(_ file: URL) -> String? {
        guard BoundedFile.isRegular(file), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }
    static func claudeKey(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
    /// The latest session that ran in this folder or anywhere inside it.
    public func lastUsed(_ folder: URL) -> Date? {
        let path = folder.standardizedFileURL.path
        // Emoji and decomposed accents may count as several characters in Claude Code's folder name; accept either, so a busy project never looks idle.
        let keys = [AgentSessionIndex.claudeKey(path), String(String.UnicodeScalarView(path.utf16.map { $0 < 128 && Character(UnicodeScalar(UInt8($0))).isLetterOrNumberASCII ? UnicodeScalar(UInt8($0)) : "-" }))]
        let claudeDates = claude.filter { entry in keys.contains { entry.key == $0 || entry.key.hasPrefix($0 + "-") } }.map(\.value)
        let codexDates = codex.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.map(\.value)
        return (claudeDates + codexDates).max()
    }
}
