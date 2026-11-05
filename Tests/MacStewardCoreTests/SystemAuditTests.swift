import XCTest
@testable import MacStewardCore

final class SystemAuditTests: XCTestCase {
    func testSettingsReadOnOffAndUnknownApart() {
        XCTAssertEqual(SystemAudit.firewall("Firewall is enabled. (State = 1)"), true)
        XCTAssertEqual(SystemAudit.firewall("Firewall is disabled. (State = 0)"), false)
        XCTAssertNil(SystemAudit.firewall(""))
        XCTAssertEqual(SystemAudit.fileVault("FileVault is Off."), false)
        XCTAssertEqual(SystemAudit.gatekeeper("assessments enabled"), true)
        XCTAssertEqual(SystemAudit.integrity("System Integrity Protection status: disabled."), false)
        XCTAssertNil(SystemAudit.integrity("System Integrity Protection status: unknown (Custom Configuration)."))
        XCTAssertEqual(SystemAudit.screenLock("2026 sysadminctl[1:2] screenLock delay is immediate"), true)
        XCTAssertEqual(SystemAudit.screenLock("screenLock delay is 300 seconds"), true)
        XCTAssertEqual(SystemAudit.screenLock("screenLock delay is 3600 seconds"), false)
        XCTAssertEqual(SystemAudit.screenLock("screenLock is off"), false)
        XCTAssertEqual(SystemAudit.service(code: 0, text: ""), true)
        XCTAssertEqual(SystemAudit.service(code: 113, text: "Could not find service"), false)
        XCTAssertNil(SystemAudit.service(code: 1, text: "Permission denied"))
    }
    func testOnlyNetworkListenersCount() {
        let lsof = "p1\ncGoogle\\x20Chrome\nf3\nn*:7000\np2\ncpostgres\nf4\nn127.0.0.1:5432\nf5\nn[::1]:5432\n"
        XCTAssertEqual(SystemAudit.networkListeners(lsof: lsof), ["Google Chrome"])
    }
    func testUpdatesNeedExplicitOffAndCanStayUnknown() {
        let unknown = SystemAudit.updateChecks(nil)
        XCTAssertTrue(unknown.allSatisfy { $0.status == .unknown })
        let pending = SystemAudit.updateChecks(["LastRecommendedUpdatesAvailable": 2])
        XCTAssertEqual(pending[0].status, .review)
        XCTAssertNotNil(pending[0].settings)
        XCTAssertEqual(pending[1].status, .good)
        let off = SystemAudit.updateChecks(["LastRecommendedUpdatesAvailable": 0, "CriticalUpdateInstall": false])
        XCTAssertEqual(off[0].status, .good)
        XCTAssertEqual(off[1].status, .review)
    }
    func testBackupStates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd-HHmmss"; format.locale = Locale(identifier: "en_US_POSIX")
        func last(_ days: Double) -> String { "/Volumes/.timemachine/x/" + format.string(from: now.addingTimeInterval(-days * 86400)) + ".backup" }
        XCTAssertEqual(SystemAudit.backupCheck(destinations: "tmutil: No destinations configured.", latest: { "" }, now: now).status, .review)
        XCTAssertEqual(SystemAudit.backupCheck(destinations: "Name : Disk\nID : 1", latest: { last(2) }, now: now).status, .good)
        XCTAssertEqual(SystemAudit.backupCheck(destinations: "Name : Disk\nID : 1", latest: { last(30) }, now: now).status, .review)
        XCTAssertEqual(SystemAudit.backupCheck(destinations: "Name : Disk\nID : 1", latest: { "Failed to mount" }, now: now).status, .info)
        XCTAssertEqual(SystemAudit.backupCheck(destinations: "", latest: { "" }, now: now).status, .unknown)
    }
    func testFirewallFixIsAFixedCommandAndCancelIsNotAFailure() {
        let script = SystemAudit.script(for: .firewall)
        XCTAssertTrue(script.contains("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertEqual(SystemAudit.outcome(code: 0, text: ""), .done)
        XCTAssertEqual(SystemAudit.outcome(code: 1, text: "execution error: User canceled. (-128)"), .cancelled)
        XCTAssertEqual(SystemAudit.outcome(code: 1, text: "execution error: other (-60008)"), .failed)
    }
    func testEveryWarningSaysWhatToDo() {
        let warnings = SystemAudit.updateChecks(["LastRecommendedUpdatesAvailable": 1, "CriticalUpdateInstall": false]) + [SystemAudit.backupCheck(destinations: "No destinations", latest: { "" }), SystemAudit.remoteCheck("r", "Remote Login", true, on: "on", off: "off")]
        for warning in warnings {
            XCTAssertEqual(warning.status, .review)
            XCTAssertNotNil(warning.action, warning.id)
            XCTAssertNotNil(warning.settings, warning.id)
            XCTAssertNotNil(warning.nextStep, warning.id)
        }
    }
    func testFinderListingBecomesASummaryWithoutClaimingUnknownSizes() throws {
        let json = #"{"files":[["movie.mp4",3000,"2020-01-02T03:04:05.000Z"],["a‮b.pdf",1000,"2026-01-02T03:04:05.000Z"]],"folders":["Project"],"folderDates":["2024-05-06T00:00:00.000Z"]}"#
        let items = try XCTUnwrap(TrashBins.parseFinder(json))
        XCTAssertEqual(items.map(\.isFolder), [false, false, true])
        XCTAssertFalse(items[1].name.unicodeScalars.contains("\u{202E}"))
        let report = TrashBinsReport(bytes: nil, items: 3, volumes: [], contents: items)
        XCTAssertEqual(report.measuredBytes, 4000)
        XCTAssertEqual(report.unmeasured, 1)
        XCTAssertEqual(report.kinds.first?.name, "Videos")
        XCTAssertEqual(report.largest(1).first?.name, "movie.mp4")
        XCTAssertEqual(report.oldest, items[0].modified)
        let now = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        XCTAssertEqual(report.unchanged(sinceDays: 365, now: now).map(\.name), ["movie.mp4", "Project"])
        XCTAssertNil(TrashBins.parseFinder("not json"))
    }
    func testGatekeeperReasonsStayApart() {
        XCTAssertNil(AppTrust.classify(code: 0, text: "accepted"))
        XCTAssertEqual(AppTrust.classify(code: 3, text: "X.app: rejected"), .notNotarized)
        XCTAssertEqual(AppTrust.classify(code: 1, text: "X.app: a sealed resource is missing or invalid"), .modified)
        XCTAssertEqual(AppTrust.classify(code: 1, text: "X.app: CSSMERR_TP_CERT_REVOKED"), .revoked)
        XCTAssertEqual(AppTrust.classify(code: 1, text: "X.app: code object is not signed at all"), .unsigned)
        XCTAssertEqual(AppTrust.classify(code: 1, text: "something new"), .unverified)
        XCTAssertEqual(AppTrust.classify(code: 3, text: ": rejected\nsource=No Usable Signature"), .unsigned)
        XCTAssertEqual(AppTrust.classify(code: 3, text: ": rejected\nsource=Unnotarized Developer ID"), .notNotarized)
        // A real unsigned bundle, named to try to pick a softer verdict.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["sealed resource", "ad hoc"] {
            let bundle = folder.appendingPathComponent(name + ".app"), binary = bundle.appendingPathComponent("Contents/MacOS/x")
            try? FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!/bin/sh\n".utf8).write(to: binary)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try? PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": "test.x", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        XCTAssertEqual(MacStewardCore.run("/usr/bin/codesign", ["--sign", "-", folder.appendingPathComponent("ad hoc.app").path]).code, 0)
        XCTAssertEqual(AppTrust.audit(folders: [folder]).findings.map(\.kind), [.unsigned, .unsigned])
    }
}
