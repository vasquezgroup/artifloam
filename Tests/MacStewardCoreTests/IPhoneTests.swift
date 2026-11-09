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

    func testGroupsHelpDecideAndNeverSuggestWhatsApp() {
        func app(_ id: String, _ a: UInt64, _ d: UInt64) -> IPhoneAppRow { IPhoneAppRow(name: id, bundleID: id, appBytes: a, dataBytes: d, measured: true) }
        let now = Date(timeIntervalSince1970: 1_800_000_000), old = now.addingTimeInterval(-300 * 86_400), recent = now.addingTimeInterval(-3 * 86_400)
        let apps = [app("game", 900_000_000, 1_000), app("video", 50_000_000, 900_000_000), app("net.whatsapp.WhatsApp", 100_000_000, 4_000_000_000), app("tiny", 1_000, 1_000), app("used", 300_000_000, 100_000_000)]
        let insights = IPhoneInsights(apps: apps, lastChanged: ["game": old, "used": recent, "net.whatsapp.WhatsApp": old, "tiny": old], now: now)
        XCTAssertEqual(insights.apps(in: .quiet).map(\.bundleID), ["game"])
        XCTAssertEqual(insights.apps(in: .barelyUsed).map(\.bundleID), ["game"])
        XCTAssertEqual(insights.apps(in: .heavyData).map(\.bundleID), ["video"])
        XCTAssertEqual(insights.apps(in: .offloadable).map(\.bundleID), ["game", "used"])
        XCTAssertEqual(insights.bytes(in: .barelyUsed), 900_000_000)
        XCTAssertEqual(IPhoneInsights(apps: apps).apps(in: .quiet), [])
    }

    func testOnlyOneIPhoneOnACableIsReadByItself() {
        let cabled = IPhoneDevice(id: "a", cabled: true), other = IPhoneDevice(id: "b", cabled: true), wireless = IPhoneDevice(id: "c")
        // One iPhone, on a cable or Wi-Fi, is chosen in advance but never read until Read is pressed.
        XCTAssertEqual(IPhoneDevice.preselected(from: [wireless]), wireless)
        XCTAssertNil(IPhoneDevice.preselected(from: [cabled, other]))
        XCTAssertNil(IPhoneDevice.preselected(from: []))
    }

    func testBackupNeedsRoomForTheIPhonePlusAMargin() {
        XCTAssertTrue(IPhoneBackupMaker.hasRoom(free: 70_000_000_000, phoneUses: 65_000_000_000))
        XCTAssertFalse(IPhoneBackupMaker.hasRoom(free: 69_000_000_000, phoneUses: 65_000_000_000))
    }

    func testAnOldBackupIsNoticedUsingTheNewestOfBoth() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), recent = now.addingTimeInterval(-86_400), old = now.addingTimeInterval(-100 * 86_400)
        XCTAssertFalse(IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: [], lastCloudBackup: recent, lastMacBackup: old).backupIsOld(now: now))
        XCTAssertTrue(IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: [], lastCloudBackup: old).backupIsOld(now: now))
        XCTAssertTrue(IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: []).backupIsOld(now: now))
        XCTAssertEqual(IPhoneApps.backupDate(NSNumber(value: 815_624_239)), Date(timeIntervalSinceReferenceDate: 815_624_239))
        XCTAssertNil(IPhoneApps.backupDate(NSNumber(value: 0)))
    }

    func testTheBackupToolIsOnlyEverAskedToBackUp() {
        let arguments = IPhoneBackupMaker.arguments(deviceID: "ABC")
        XCTAssertEqual(arguments, ["--backup", "--target", "ABC", "--no-pass-prompt"])
        for dangerous in ["--restore", "-r", "--erase", "-E", "--remove", "-R", "--change", "-C"] { XCTAssertFalse(arguments.contains(dangerous)) }
    }

    func testStoreRecordGivesCategoryAndDateAndNothingElse() throws {
        let record: [String: Any] = ["genre": "Dienst\u{00AD}programme", "com.apple.iTunesStore.downloadInfo": ["purchaseDate": "2014-03-01T10:00:00Z", "accountInfo": ["AppleID": "secret@example.com"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let row = try XCTUnwrap(IPhoneApps.rows(from: ["a": ["StaticDiskUsage": 1, "DynamicDiskUsage": 1, "iTunesMetadata": data]]).first)
        XCTAssertEqual(row.category, "Dienstprogramme")
        XCTAssertEqual(row.firstDownloaded, ISO8601DateFormatter().date(from: "2014-03-01T10:00:00Z"))
        XCTAssertFalse(String(describing: row).contains("secret@example.com"))
        XCTAssertNil(IPhoneApps.rows(from: ["a": ["StaticDiskUsage": 1, "iTunesMetadata": "not data"]]).first?.category)
    }

    func testUseIsEstimatedFromDataUntilABackupGivesDates() {
        func app(_ id: String, _ a: UInt64, _ d: UInt64) -> IPhoneAppRow { IPhoneAppRow(name: id, bundleID: id, appBytes: a, dataBytes: d, measured: true) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let heavy = app("heavy", 100, 900), bare = app("bare", 1000, 1), middle = app("middle", 1000, 500)
        let estimate = IPhoneInsights(apps: [heavy, bare, middle], now: now)
        XCTAssertEqual([estimate.use(of: heavy), estimate.use(of: bare), estimate.use(of: middle)], [.more, .less, .some])
        let dated = IPhoneInsights(apps: [heavy, bare], lastChanged: ["heavy": now.addingTimeInterval(-400 * 86_400), "bare": now.addingTimeInterval(-86_400)], now: now)
        XCTAssertEqual(dated.use(of: heavy), .less)
        XCTAssertEqual(dated.use(of: bare), .more)
    }

    func testCategoriesAreBiggestFirstWithUnknownLast() {
        var a = IPhoneAppRow(name: "a", bundleID: "a", appBytes: 10, dataBytes: 0, measured: true); a.category = "Games"
        var b = IPhoneAppRow(name: "b", bundleID: "b", appBytes: 50, dataBytes: 0, measured: true); b.category = "Music"
        let c = IPhoneAppRow(name: "c", bundleID: "c", appBytes: 90, dataBytes: 0, measured: true)
        XCTAssertEqual(IPhoneInsights(apps: [a, b, c]).categories.map(\.id), ["Music", "Games", ""])
    }

    func testRemovalPlanSaysWhatGoesAndWhatNeedsAnAcknowledgement() {
        var game = IPhoneAppRow(name: "Game", bundleID: "game", appBytes: 100, dataBytes: 40, measured: true); game.storeID = "1"
        var chat = IPhoneAppRow(name: "WA Business", bundleID: "net.whatsapp.WhatsAppSMB", appBytes: 10, dataBytes: 90, measured: true); chat.storeID = "2"
        let beta = IPhoneAppRow(name: "Beta", bundleID: "beta", appBytes: 5, dataBytes: 5, measured: true)
        XCTAssertEqual(IPhoneRemovalPlan(apps: [game], backupIsOld: false).freedBytes, 140)
        XCTAssertFalse(IPhoneRemovalPlan(apps: [game], backupIsOld: false).needsAcknowledgement)
        XCTAssertTrue(IPhoneRemovalPlan(apps: [game], backupIsOld: true).needsAcknowledgement)
        XCTAssertTrue(IPhoneRemovalPlan(apps: [chat], backupIsOld: false).needsAcknowledgement)
        XCTAssertTrue(IPhoneRemovalPlan(apps: [beta], backupIsOld: false).needsAcknowledgement, "not from the App Store, so it may not come back")
    }

    func testSelectAllLeavesOutChatsAndLoginCodes() {
        let apps = [("Game", "game"), ("WA Business", "net.whatsapp.WhatsAppSMB"), ("Google Authenticator", "com.google.Authenticator")].map { IPhoneAppRow(name: $0.0, bundleID: $0.1, appBytes: 1, dataBytes: 1, measured: true) }
        XCTAssertEqual(apps.bulkSelectable.map(\.bundleID), ["game"])
    }

    func testRisksAreRecognised() {
        func risk(_ name: String, _ id: String) -> IPhoneAppRow.Risk? { IPhoneAppRow(name: name, bundleID: id, appBytes: 1, dataBytes: 1, measured: true).risk }
        XCTAssertEqual(risk("WhatsApp", "net.whatsapp.WhatsApp"), .chats)
        XCTAssertEqual(risk("Signal", "org.whispersystems.signal"), .chats)
        XCTAssertEqual(risk("Google Authenticator", "com.google.Authenticator"), .loginCodes)
        XCTAssertNil(risk("Netflix", "com.netflix.Netflix"))
    }

    func testResultTrustsTheNewListNotTheCall() {
        let gone = IPhoneAppRow(name: "Gone", bundleID: "gone", appBytes: 100, dataBytes: 0, measured: true)
        let stuck = IPhoneAppRow(name: "Stuck", bundleID: "stuck", appBytes: 100, dataBytes: 0, measured: true)
        let plan = IPhoneRemovalPlan(apps: [gone, stuck], backupIsOld: false)
        let result = IPhoneRemovalResult(plan: plan, usedBefore: 1_000, after: IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: [stuck], usedBytes: 900))
        XCTAssertEqual(result.removed.map(\.bundleID), ["gone"])
        XCTAssertEqual(result.stillThere.map(\.bundleID), ["stuck"])
        XCTAssertEqual(result.freedBytes, 100)
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

    func testReadsLastModifiedFromAFileRecord() throws {
        let record: [String: Any] = ["$objects": ["$null", ["LastModified": 1_700_000_000, "Size": 5], "name"], "$archiver": "NSKeyedArchiver"]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        XCTAssertEqual(WhatsAppBackup.modified(fromFileRecord: data), 1_700_000_000)
        XCTAssertNil(WhatsAppBackup.modified(fromFileRecord: Data("nope".utf8)))
    }

    func testRemovingABackupStaysInsideTheBackupsFolder() throws {
        let backup = try makeBackup()
        XCTAssertThrowsError(try WhatsAppBackup.remove(backup, root: root.appendingPathComponent("elsewhere")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.url.path))
        try WhatsAppBackup.remove(backup, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.url.path))
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

    func testAppListIsOnlySentWhenTheIPhoneAppIsThere() throws {
        let other = IPhoneAppRow(name: "Small", bundleID: "a.b", appBytes: 1, dataBytes: 1, measured: true)
        let big = IPhoneAppRow(name: "Big", bundleID: "c.d", appBytes: 5, dataBytes: 5, measured: true)
        let unmeasured = IPhoneAppRow(name: "Unknown", bundleID: "e.f", appBytes: 0, dataBytes: 0, measured: false)
        let ours = IPhoneAppRow(name: "Artifloam", bundleID: IPhoneAppList.bundleID, appBytes: 3, dataBytes: 0, measured: true)
        XCTAssertNil(IPhoneAppList(report: IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: [other, big])))
        let list = try XCTUnwrap(IPhoneAppList(report: IPhoneAppsReport(deviceID: "x", deviceName: nil, apps: [other, big, unmeasured, ours])))
        XCTAssertEqual(list.apps.map(\.name), ["Big", "Artifloam", "Small"])
    }
}
