import Foundation
import SQLite3

/// A Finder backup of an iPhone on this Mac.
public struct IPhoneBackup: Identifiable, Hashable, Sendable {
    public let url: URL
    public let deviceName: String
    public let date: Date?
    public let deviceIDs: [String]
    public let encrypted: Bool
    public var id: String { url.path }
    /// A backup can write the identifier with or without its dash.
    public func belongs(toDevice deviceID: String) -> Bool {
        let wanted = Self.normalized(deviceID)
        return deviceIDs.contains { Self.normalized($0) == wanted }
    }
    private static func normalized(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").uppercased() }
}

public enum WhatsAppMediaKind: String, CaseIterable, Sendable {
    case photos, videos, audio, documents, other
    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "gif": self = .photos
        case "mp4", "mov", "m4v", "3gp": self = .videos
        case "opus", "m4a", "mp3", "aac", "ogg", "caf", "amr", "wav": self = .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "rtf", "zip", "pages", "numbers", "key": self = .documents
        default: self = .other
        }
    }
}

public struct WhatsAppChat: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let isGroup: Bool
    public let bytes: UInt64
    public let kinds: [WhatsAppMediaKind: UInt64]
}

public struct WhatsAppReport: Equatable, Sendable {
    public let chats: [WhatsAppChat]
    public var totalBytes: UInt64 { chats.reduce(0) { $0 + $1.bytes } }
}

public enum WhatsAppBackupError: Error, Equatable, Sendable {
    case noAccess, encrypted, noWhatsApp, unsupportedVersion, unreadable
}

public enum WhatsAppBackup {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    static let domain = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
    /// Everything this file ever asks WhatsApp's database. Message text is never selected; a test holds this list to that.
    static let chatsQuery = "SELECT Z_PK, ZPARTNERNAME, ZCONTACTJID FROM ZWACHATSESSION"
    static func mediaQuery(link: String) -> String {
        "SELECT m.ZCHATSESSION, i.ZFILESIZE, i.ZMEDIALOCALPATH FROM ZWAMEDIAITEM i JOIN ZWAMESSAGE m ON \(link) WHERE i.ZMEDIALOCALPATH IS NOT NULL AND i.ZMEDIALOCALPATH != ''"
    }
    static let linkThroughMessage = "m.ZMEDIAITEM = i.Z_PK", linkThroughItem = "i.ZMESSAGE = m.Z_PK"

    /// Backups on this Mac, newest first. It reads only what describes each backup, not what is in it.
    public static func backups(root: URL = defaultRoot) throws -> [IPhoneBackup] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { throw WhatsAppBackupError.noAccess }
        return folders.compactMap { folder -> IPhoneBackup? in
            guard let info = plist(folder.appendingPathComponent("Info.plist")) else { return nil }
            let encrypted = plist(folder.appendingPathComponent("Manifest.plist"))?["IsEncrypted"] as? Bool ?? false
            let ids = [folder.lastPathComponent, info["Unique Identifier"] as? String, info["Target Identifier"] as? String].compactMap { $0 }
            return IPhoneBackup(url: folder, deviceName: (info["Device Name"] as? String ?? "iPhone").displaySafe, date: info["Last Backup Date"] as? Date, deviceIDs: ids, encrypted: encrypted)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// WhatsApp storage per chat, from this one backup. A copy is made only when the database has unmerged changes beside it, and it is deleted before this returns.
    public static func read(_ backup: IPhoneBackup, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> WhatsAppReport {
        let folder = backup.url
        guard let manifest = plist(folder.appendingPathComponent("Manifest.plist")) else {
            throw (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil ? WhatsAppBackupError.noAccess : .unreadable
        }
        guard manifest["IsEncrypted"] as? Bool != true else { throw WhatsAppBackupError.encrypted }
        let files = try chatStorageFiles(in: folder)
        guard let store = files[""] else { throw WhatsAppBackupError.noWhatsApp }
        let wal = files["-wal"]
        if let wal, (try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 {
            // A copy left by a crash goes first: it holds someone's messages.
            for old in (try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("artifloam-whatsapp-") { try? FileManager.default.removeItem(at: old) }
            let copies = temporaryDirectory.appendingPathComponent("artifloam-whatsapp-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: copies) }
            do {
                for (suffix, file) in files { try FileManager.default.copyItem(at: file, to: copies.appendingPathComponent("ChatStorage.sqlite" + suffix)) }
            } catch { throw WhatsAppBackupError.unreadable }
            return try report(from: Database(copies.appendingPathComponent("ChatStorage.sqlite"), immutable: false))
        }
        return try report(from: Database(store, immutable: true))
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    /// The database and its -wal and -shm, where the backup's Manifest.db says they are. Keyed by suffix; "" is the database.
    private static func chatStorageFiles(in folder: URL) throws -> [String: URL] {
        let manifest: Database
        do { manifest = try Database(folder.appendingPathComponent("Manifest.db"), immutable: true) } catch { throw WhatsAppBackupError.unreadable }
        var files = [String: URL]()
        do {
            try manifest.rows("SELECT fileID, relativePath FROM Files WHERE domain = ? AND relativePath IN ('ChatStorage.sqlite', 'ChatStorage.sqlite-wal', 'ChatStorage.sqlite-shm')", bind: domain) { row in
                guard let id = row.text(0), let path = row.text(1), id.count > 2, !id.contains("/") else { return }
                let file = folder.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
                if FileManager.default.fileExists(atPath: file.path) { files[String(path.dropFirst("ChatStorage.sqlite".count))] = file }
            }
        } catch { throw WhatsAppBackupError.unreadable }
        return files
    }

    private static func report(from database: Database) throws -> WhatsAppReport {
        // WhatsApp's tables aren't documented and can change, so check before asking.
        let sessions = database.columns("ZWACHATSESSION"), messages = database.columns("ZWAMESSAGE"), media = database.columns("ZWAMEDIAITEM")
        guard sessions.isSuperset(of: ["Z_PK", "ZPARTNERNAME", "ZCONTACTJID"]), messages.isSuperset(of: ["Z_PK", "ZCHATSESSION"]), media.isSuperset(of: ["Z_PK", "ZFILESIZE", "ZMEDIALOCALPATH"]),
              let link = messages.contains("ZMEDIAITEM") ? linkThroughMessage : media.contains("ZMESSAGE") ? linkThroughItem : nil
        else { throw WhatsAppBackupError.unsupportedVersion }
        var kinds = [Int64: [WhatsAppMediaKind: UInt64]]()
        var chats = [WhatsAppChat]()
        do {
            try database.rows(mediaQuery(link: link)) { row in
                guard let path = row.text(2) else { return }
                kinds[row.integer(0), default: [:]][WhatsAppMediaKind(path: path), default: 0] += UInt64(max(0, row.integer(1)))
            }
            try database.rows(chatsQuery) { row in
                let id = row.integer(0)
                guard let chatKinds = kinds[id] else { return }
                let jid = row.text(2) ?? ""
                let name = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? String(jid.prefix { $0 != "@" })
                chats.append(WhatsAppChat(id: id, name: name.displaySafe, isGroup: jid.hasSuffix("@g.us"), bytes: chatKinds.values.reduce(0, +), kinds: chatKinds))
            }
        } catch { throw WhatsAppBackupError.unsupportedVersion }
        return WhatsAppReport(chats: chats.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) })
    }
}

/// A read-only SQLite file. Immutable tells SQLite the file can't change, so it writes nothing beside it.
private final class Database {
    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    }
    private var handle: OpaquePointer?
    init(_ file: URL, immutable: Bool) throws {
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)
        if immutable { components?.queryItems = [URLQueryItem(name: "immutable", value: "1")] }
        guard let uri = components?.url?.absoluteString, sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { throw WhatsAppBackupError.unreadable }
    }
    deinit { sqlite3_close_v2(handle) }
    func rows(_ sql: String, bind: String? = nil, _ each: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw WhatsAppBackupError.unreadable }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite takes its own copy of the text.
        if let bind { sqlite3_bind_text(statement, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW { each(Row(statement: statement)); step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw WhatsAppBackupError.unreadable }
    }
    /// Empty when the table doesn't exist or the file isn't a database.
    func columns(_ table: String) -> Set<String> {
        var names = Set<String>()
        try? rows("PRAGMA table_info(\(table))") { row in if let name = row.text(1) { names.insert(name) } }
        return names
    }
}
