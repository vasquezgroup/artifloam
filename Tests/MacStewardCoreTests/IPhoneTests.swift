import SQLite3
import XCTest
@testable import MacStewardCore

final class IPhoneAppsTests: XCTestCase {
    private func row(app: UInt64, data: UInt64) -> IPhoneAppRow { IPhoneAppRow(name: "A", bundleID: "a", appBytes: app, dataBytes: data, measured: true) }

    func testRowsAreSortedByTotalAndFallBackToTheBundleID() {
        let rows = IPhoneApps.rows(from: [
            "small": ["CFBundleIdentifier": "small", "CFBundleDisplayName": "Small", "StaticDiskUsage": NSNumber(value: 10), "DynamicDiskUsage": NSNumber(value: 5)],
            "big": ["CFBundleIdentifier": "big", "StaticDiskUsage": NSNumber(value: 100), "DynamicDiskUsage": NSNumber(value: 900)],
            "odd": ["CFBundleIdentifier": "odd", "CFBundleDisplayName": "Odd", "StaticDiskUsage": NSNumber(value: -1)],
            "junk": "not a dictionary",
        ])
        XCTAssertEqual(rows.map(\.name), ["big", "Small", "Odd"])
        XCTAssertEqual(rows[0].appBytes, 100)
        XCTAssertEqual(rows[0].dataBytes, 900)
        XCTAssertEqual(rows[0].totalBytes, 1000)
        XCTAssertEqual(rows[2].totalBytes, 0)
    }

    func testNamesLoseInvisibleCharactersButKeepEmoji() {
        let rows = IPhoneApps.rows(from: ["a": ["CFBundleDisplayName": "\u{200E}WA Business", "StaticDiskUsage": 1, "DynamicDiskUsage": 1]])
        XCTAssertEqual(rows.first?.name, "WA Business")
        XCTAssertEqual("👨‍👩‍👧 Family\u{202E}".cleanedName, "👨‍👩‍👧 Family")
    }

    func testAppsWithNoSizesAreMarked() {
        let rows = IPhoneApps.rows(from: ["a": ["CFBundleIdentifier": "a", "CFBundleDisplayName": "A"]])
        XCTAssertFalse(rows[0].measured)
        XCTAssertTrue(IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: rows).sizesMissing)
    }

    func testAdviceFollowsWhatOffloadingFrees() {
        XCTAssertEqual(row(app: 100, data: 10).advice, .offloadHelps)
        XCTAssertEqual(row(app: 100, data: 1000).advice, .offloadKeepsData)
        XCTAssertEqual(row(app: 100, data: 200).advice, .offloadKeepsData)
        XCTAssertEqual(row(app: 100, data: 150).advice, .offloadFreesAppOnly)
        XCTAssertEqual(IPhoneApps.rows(from: ["net.whatsapp.WhatsAppSMB": ["StaticDiskUsage": 1, "DynamicDiskUsage": 900]]).first?.advice, .cleanInWhatsApp)
    }

    func testDeviceLabelShowsOnlyTheEndOfTheIdentifier() {
        XCTAssertEqual(IPhoneDevice(id: "00000000-0000000000001234").label, "iPhone 1234")
    }
}

final class WhatsAppBackupTests: XCTestCase {
    private static let secret = "TOP-SECRET-MESSAGE-TEXT"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("artifloam-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func execute(_ database: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }
    private func withDatabase(_ url: URL, _ body: (OpaquePointer?) -> Void) {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        body(database)
        sqlite3_close(database)
    }
    private func standardChats(_ database: OpaquePointer?) {
        execute(database, """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZPARTNERNAME TEXT, ZCONTACTJID TEXT);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEDIAITEM INTEGER, ZTEXT TEXT);
        CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZFILESIZE INTEGER, ZMEDIALOCALPATH TEXT, ZMESSAGE INTEGER);
        INSERT INTO ZWACHATSESSION VALUES (1, 'Ana', '41790000000@s.whatsapp.net'), (2, 'Family', '1234-5678@g.us'), (3, 'No media', '41790000001@s.whatsapp.net'), (4, NULL, '41790000002@s.whatsapp.net');
        INSERT INTO ZWAMEDIAITEM VALUES (1, 100, 'Media/a/photo.JPG', 1), (2, 2000, 'Media/b/video.mp4', 2), (3, 30, 'Media/b/voice.opus', 3), (4, 400, 'Media/b/file.pdf', 4), (5, 5, 'Media/b/thing.xyz', 5), (6, 999999, NULL, 6), (7, 7, 'Media/d/photo.heic', 7);
        INSERT INTO ZWAMESSAGE VALUES (1, 1, 1, '\(Self.secret)'), (2, 2, 2, '\(Self.secret)'), (3, 2, 3, '\(Self.secret)'), (4, 2, 4, '\(Self.secret)'), (5, 2, 5, '\(Self.secret)'), (6, 1, 6, '\(Self.secret)'), (7, 4, 7, '\(Self.secret)'), (8, 3, NULL, '\(Self.secret)');
        """)
    }
    /// A backup folder laid out as Finder does: Info.plist, Manifest.plist, Manifest.db and hashed files.
    @discardableResult private func makeBackup(name: String = "backup", encrypted: Bool = false, chats: ((OpaquePointer?) -> Void)? = nil) throws -> IPhoneBackup {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info: [String: Any] = ["Device Name": "Test iPhone", "Last Backup Date": Date(timeIntervalSince1970: 1_800_000_000), "Unique Identifier": "00000000AAAAAAAAAAAAAAAA"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["IsEncrypted": encrypted], format: .xml, options: 0).write(to: folder.appendingPathComponent("Manifest.plist"))
        withDatabase(folder.appendingPathComponent("Manifest.db")) { manifest in
            execute(manifest, "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB);")
            if chats != nil { execute(manifest, "INSERT INTO Files VALUES ('abcdef', '\(WhatsAppBackup.domain)', 'ChatStorage.sqlite', 1, NULL), ('abothr', 'HomeDomain', 'ChatStorage.sqlite', 1, NULL);") }
        }
        if let chats {
            let store = folder.appendingPathComponent("ab/abcdef")
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            withDatabase(store, chats)
        }
        return try XCTUnwrap(WhatsAppBackup.backups(root: root).first { $0.url.lastPathComponent == name })
    }

    func testSumsMediaPerChatAndKind() throws {
        let report = try WhatsAppBackup.read(makeBackup(chats: standardChats))
        XCTAssertEqual(report.chats.map(\.name), ["Family", "Ana", "41790000002"])
        XCTAssertEqual(report.totalBytes, 2542)
        let family = report.chats[0], person = report.chats[1]
        XCTAssertTrue(family.isGroup)
        XCTAssertFalse(person.isGroup)
        XCTAssertEqual(family.bytes, 2435)
        XCTAssertEqual(family.kinds, [.videos: 2000, .audio: 30, .documents: 400, .other: 5])
        // Media that was never downloaded (no local path) isn't on the phone, so it doesn't count.
        XCTAssertEqual(person.bytes, 100)
        XCTAssertEqual(person.kinds, [.photos: 100])
    }

    func testWhatsAppBusinessIsReadAlongsideWhatsApp() throws {
        let backup = try makeBackup(chats: standardChats)
        let business = backup.url.appendingPathComponent("cd/cdefgh")
        try FileManager.default.createDirectory(at: business.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: backup.url.appendingPathComponent("ab/abcdef"), to: business)
        withDatabase(backup.url.appendingPathComponent("Manifest.db")) { manifest in
            execute(manifest, "INSERT INTO Files VALUES ('cdefgh', 'AppDomainGroup-group.net.whatsapp.WhatsAppSMB.shared', 'ChatStorage.sqlite', 1, NULL);")
        }
        let report = try WhatsAppBackup.read(backup)
        XCTAssertEqual(report.chats.count, 6)
        XCTAssertEqual(Set(report.chats.map(\.id)).count, 6)
        XCTAssertEqual(report.totalBytes, 2542 * 2)
    }

    func testMessageTextCanNotReachTheResults() throws {
        let report = try WhatsAppBackup.read(makeBackup(chats: standardChats))
        var dumped = ""
        dump(report, to: &dumped)
        XCTAssertFalse(dumped.isEmpty)
        XCTAssertFalse(dumped.contains(Self.secret))
        for query in [WhatsAppBackup.chatsQuery, WhatsAppBackup.mediaQuery(link: WhatsAppBackup.linkThroughMessage), WhatsAppBackup.mediaQuery(link: WhatsAppBackup.linkThroughItem)] {
            XCTAssertFalse(query.contains("ZTEXT"))
            XCTAssertFalse(query.contains("*"))
        }
    }

    func testFollowsTheLinkFromMediaToMessageWhenThatIsTheOneThere() throws {
        let report = try WhatsAppBackup.read(makeBackup { database in
            self.execute(database, """
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZPARTNERNAME TEXT, ZCONTACTJID TEXT);
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER);
            CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZFILESIZE INTEGER, ZMEDIALOCALPATH TEXT, ZMESSAGE INTEGER);
            INSERT INTO ZWACHATSESSION VALUES (1, 'Ana', 'a@s.whatsapp.net');
            INSERT INTO ZWAMESSAGE VALUES (9, 1);
            INSERT INTO ZWAMEDIAITEM VALUES (1, 50, 'x.jpg', 9);
            """)
        })
        XCTAssertEqual(report.totalBytes, 50)
    }

    func testAnUnknownSchemaIsReportedInsteadOfCrashing() throws {
        let backup = try makeBackup { database in
            self.execute(database, "CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY);")
        }
        XCTAssertThrowsError(try WhatsAppBackup.read(backup)) { XCTAssertEqual($0 as? WhatsAppBackupError, .unsupportedVersion) }
    }

    func testEncryptedAndMissingWhatsAppAreSaidPlainly() throws {
        let encrypted = try makeBackup(name: "locked", encrypted: true)
        XCTAssertTrue(encrypted.encrypted)
        XCTAssertThrowsError(try WhatsAppBackup.read(encrypted)) { XCTAssertEqual($0 as? WhatsAppBackupError, .encrypted) }
        XCTAssertThrowsError(try WhatsAppBackup.read(makeBackup(name: "plain"))) { XCTAssertEqual($0 as? WhatsAppBackupError, .noWhatsApp) }
    }

    func testChangesWaitingInTheWALAreReadFromACopyThatIsThenDeleted() throws {
        let backup = try makeBackup(chats: standardChats)
        let store = backup.url.appendingPathComponent("ab/abcdef")
        // Keep this connection open while copying, so SQLite leaves the -wal file in place.
        var live: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &live), SQLITE_OK)
        defer { sqlite3_close(live) }
        execute(live, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE ZWAMEDIAITEM SET ZFILESIZE = 111 WHERE Z_PK = 1;")
        let wal = backup.url.appendingPathComponent("ab/abcwal")
        try FileManager.default.copyItem(atPath: store.path + "-wal", toPath: wal.path)
        withDatabase(backup.url.appendingPathComponent("Manifest.db")) { manifest in
            execute(manifest, "INSERT INTO Files VALUES ('abcwal', '\(WhatsAppBackup.domain)', 'ChatStorage.sqlite-wal', 1, NULL);")
        }
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let report = try WhatsAppBackup.read(backup, temporaryDirectory: scratch)
        XCTAssertEqual(report.chats.first { $0.name == "Ana" }?.bytes, 111)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testBackupsListAndMatchTheDevice() throws {
        XCTAssertEqual(try WhatsAppBackup.backups(root: root.appendingPathComponent("missing")), [])
        let backup = try makeBackup()
        XCTAssertEqual(backup.deviceName, "Test iPhone")
        XCTAssertEqual(backup.date, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(backup.encrypted)
        XCTAssertTrue(backup.belongs(toDevice: "00000000-aaaaaaaaaaaaaaaa"))
        XCTAssertFalse(backup.belongs(toDevice: "11111111-AAAAAAAAAAAAAAAA"))
    }

    func testMediaKindsComeFromTheExtension() {
        XCTAssertEqual(WhatsAppMediaKind(path: "a/b.HEIC"), .photos)
        XCTAssertEqual(WhatsAppMediaKind(path: "a/b.mov"), .videos)
        XCTAssertEqual(WhatsAppMediaKind(path: "a/b.opus"), .audio)
        XCTAssertEqual(WhatsAppMediaKind(path: "a/b.docx"), .documents)
        XCTAssertEqual(WhatsAppMediaKind(path: "a/b"), .other)
    }
}
