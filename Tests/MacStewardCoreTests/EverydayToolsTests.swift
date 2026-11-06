import XCTest
@testable import MacStewardCore

final class EverydayToolsTests: XCTestCase {
    func testAgentRhythmsAndWhichRunOften() {
        func item(_ schedule: BackgroundSchedule) -> BackgroundItem { var value = BackgroundItem(url: URL(fileURLWithPath: "/tmp/a.plist"), label: "com.a.b", program: "/bin/a", scope: "Your account"); value.schedule = schedule; return value }
        XCTAssertEqual(item(.alwaysRunning).rhythm, "Always running")
        XCTAssertEqual(item(.every(seconds: 21600)).rhythm, "On a schedule")
        XCTAssertEqual(item(.daily("05:00")).rhythm, "On a schedule")
        XCTAssertEqual(item(.atLogin(restarting: true)).rhythm, "At login")
        XCTAssertEqual(item(.whenNeeded).rhythm, "When needed")
        XCTAssertTrue(item(.every(seconds: 60)).runsOften)
        XCTAssertTrue(item(.every(seconds: 30)).runsOften)
        XCTAssertTrue(item(.every(seconds: 300)).runsOften)
        XCTAssertFalse(item(.every(seconds: 600)).runsOften)
        XCTAssertFalse(item(.every(seconds: 3600)).runsOften)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testSingleInstanceLeaseBlocksSecondLaunchAndReleasesOnExit() throws {
        let root = try fixture(), lock = root.appendingPathComponent("instance.lock")
        var first = try AppInstanceLease(at: lock)
        XCTAssertNotNil(first)
        XCTAssertNil(try AppInstanceLease(at: lock))
        first = nil
        XCTAssertNotNil(try AppInstanceLease(at: lock))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: lock)
        XCTAssertThrowsError(try AppInstanceLease(at: alias))
    }
    func testReviewCollapsesOverlappingSelectionsAndMoveRechecksIdentity() throws {
        let home = try fixture(), folder = home.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sample"); try Data([1,2,3]).write(to: file)
        let plan = try ReviewedTrash.review([folder,file,folder], home: home)
        XCTAssertEqual(plan.count, 1)
        var moved = [URL]()
        let result = ReviewedTrash.move(plan, home: home) { moved.append($0); return "/fixture-trash/Project" }
        XCTAssertEqual(moved.map(\.path), [folder.path]); XCTAssertNil(result.first?.error)
        let filePlan = try ReviewedTrash.review([file], home: home)
        try Data([4,5,6,7]).write(to: file, options: .atomic)
        let blocked = ReviewedTrash.move(filePlan, home: home) { _ in XCTFail("Changed file reached Trash"); return nil }
        XCTAssertNotNil(blocked.first?.error)
    }
    func testUnattendedReviewKeepsCloudAndProtectedItemsOnly() throws {
        let home = try fixture(), folder = home.appendingPathComponent("Copies"), cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        for directory in [folder, cloud] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let local = folder.appendingPathComponent("copy"), synced = cloud.appendingPathComponent("copy")
        for file in [local, synced] { try Data([1]).write(to: file) }
        let result = ReviewedTrash.reviewUnattended([local, synced, home.appendingPathComponent("Documents"), folder.appendingPathComponent("gone")], home: home)
        XCTAssertEqual(result.ready.map(\.url.path), [local.standardizedFileURL.path])
        XCTAssertEqual(result.kept, 3)
    }
    func testMoveReportsProgressAndStopsBetweenItems() throws {
        let home = try fixture(), folder = home.appendingPathComponent("Copies")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try (1...3).map { index -> URL in let url = folder.appendingPathComponent("copy\(index)"); try Data(repeating: 7, count: 4096).write(to: url); return url }
        let plan = try ReviewedTrash.review(files, home: home)
        var updates = [Int](), bytes: UInt64 = 0
        let all = ReviewedTrash.move(plan, home: home, progress: { done, moved, _ in updates.append(done); bytes = moved }) { _ in "/fixture-trash" }
        XCTAssertEqual(all.count, 3); XCTAssertEqual(updates, [1, 2, 3]); XCTAssertGreaterThan(bytes, 0)
        var asked = 0
        let stopped = ReviewedTrash.move(plan, home: home, shouldStop: { asked += 1; return asked > 1 }) { _ in "/fixture-trash" }
        XCTAssertEqual(stopped.count, 1, "items after Stop are left where they are")
    }
    func testProtectedRootsAndSymlinkAncestorsCannotReachTrash() throws {
        let home = try fixture(), protected = [home,home.appendingPathComponent("Documents"),home.appendingPathComponent("Library"),URL(fileURLWithPath:"/System"),URL(fileURLWithPath:"/Applications"),URL(fileURLWithPath:"/Volumes/Disk")]
        for url in protected { XCTAssertFalse(ReviewedTrash.allowed(url, home: home, allowApplication: false), url.path) }
        let real = home.appendingPathComponent("real"); try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ReviewedTrash.review([link], home: home))
        XCTAssertFalse(ReviewedTrash.allowed(link.appendingPathComponent("file"), home: home, allowApplication: false))
        XCTAssertFalse(ReviewedTrash.allowed(home.appendingPathComponent("Library/CloudStorage/Provider"), home: home, allowApplication: false))
        XCTAssertTrue(ReviewedTrash.allowed(home.appendingPathComponent("Library/CloudStorage/Provider/file"), home: home, allowApplication: false))
        // Hidden tool folders: a file inside may go, the folders and credential stores may not.
        let disk = home.appendingPathComponent(".android/avd/Pixel.avd/userdata-qemu.img.qcow2"), key = home.appendingPathComponent(".ssh/id_ed25519")
        for file in [disk, key] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([1]).write(to: file) }
        XCTAssertTrue(ReviewedTrash.allowed(disk, home: home, allowApplication: false))
        XCTAssertFalse(ReviewedTrash.allowed(disk.deletingLastPathComponent(), home: home, allowApplication: false))
        XCTAssertFalse(ReviewedTrash.allowed(home.appendingPathComponent(".android"), home: home, allowApplication: false))
        XCTAssertFalse(ReviewedTrash.allowed(key, home: home, allowApplication: false))
    }
    func testSymlinkReplacementAndPerItemFailureAreReported() throws {
        let home = try fixture(), a = home.appendingPathComponent("a"), b = home.appendingPathComponent("b")
        try Data([1]).write(to:a); try Data([2]).write(to:b)
        let plan = try ReviewedTrash.review([a,b],home:home)
        try FileManager.default.removeItem(at:a);try FileManager.default.createSymbolicLink(at:a,withDestinationURL:b)
        var calls = 0
        let results = ReviewedTrash.move(plan,home:home) { _ in calls += 1; throw NSError(domain:"Fixture",code:1) }
        XCTAssertEqual(calls,1);XCTAssertEqual(results.filter { $0.error != nil }.count,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:b.path))
    }
    func testLargeFilesUseMetadataDeduplicateAndApplyAgeFilters() throws {
        let root = try fixture(), old = root.appendingPathComponent("old.bin"), recent = root.appendingPathComponent("recent.bin")
        try Data(repeating:1,count:8192).write(to:old);try Data(repeating:2,count:16384).write(to:recent)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1000)],ofItemAtPath:old.path)
        try FileManager.default.linkItem(at:old,to:root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:recent)
        let hidden = root.appendingPathComponent(".hidden");try FileManager.default.createDirectory(at:hidden,withIntermediateDirectories:true);try Data(repeating:3,count:32768).write(to:hidden.appendingPathComponent("ignored"))
        let all = try LargeFileAudit.scan(root:root,minimumBytes:4096)
        XCTAssertEqual(all.files.count,2);XCTAssertFalse(all.limited)
        let aged = try LargeFileAudit.scan(root:root,minimumBytes:4096,modifiedBefore:Date(timeIntervalSince1970:2000))
        XCTAssertEqual(aged.files.count,1);XCTAssertEqual(aged.files[0].logicalBytes,8192)
        XCTAssertTrue(try LargeFileAudit.scan(root:root,maximumEntries:1).limited)
    }
    func testLargeFileSearchCancellation() async throws {
        let root = try fixture()
        let task = Task.detached { try Task.checkCancellation();return try LargeFileAudit.scan(root:root) };task.cancel()
        do { _ = try await task.value;XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testAppInventoryAndBackgroundConfigurationParsing() throws {
        let home = try fixture(), app = home.appendingPathComponent("Applications/Fixture.app/Contents")
        try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleIdentifier":"fixture.example","CFBundleDisplayName":"Fixture App","CFBundleShortVersionString":"1.2","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Info.plist"))
        XCTAssertTrue(ReviewedTrash.allowed(app.deletingLastPathComponent(), home: home, allowApplication: true))
        XCTAssertFalse(ReviewedTrash.allowed(app, home: home, allowApplication: false))
        XCTAssertTrue(ApplicationInventory.scan(home:home).contains { $0.identifier == "fixture.example" && $0.name == "Fixture App" })
        let agents = home.appendingPathComponent("Library/LaunchAgents");try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let launch:[String:Any] = ["Label":"fixture.agent","ProgramArguments":["/fixture/agent","--run"]]
        try PropertyListSerialization.data(fromPropertyList:launch,format:.xml,options:0).write(to:agents.appendingPathComponent("fixture.plist"))
        try Data("invalid".utf8).write(to:agents.appendingPathComponent("invalid.plist"))
        XCTAssertTrue(BackgroundInventory.scan(home:home).contains { $0.label == "fixture.agent" && $0.program == "/fixture/agent" && $0.scope == "Your account" })
    }

    func testAppUsageAgeGroupsByLastUse() {
        let now = Date(), day = 86400.0
        XCTAssertEqual(AppUsageAge(lastUsed: nil, now: now), .overYear)
        XCTAssertEqual(AppUsageAge(lastUsed: now.addingTimeInterval(-400 * day), now: now), .overYear)
        XCTAssertEqual(AppUsageAge(lastUsed: now.addingTimeInterval(-200 * day), now: now), .sixMonths)
        XCTAssertEqual(AppUsageAge(lastUsed: now.addingTimeInterval(-60 * day), now: now), .months)
        XCTAssertEqual(AppUsageAge(lastUsed: now.addingTimeInterval(-3 * day), now: now), .recent)
    }

    func testBackgroundItemMakerReadsTheLabel() {
        func item(_ label: String, _ program: String = "/bin/sh") -> BackgroundItem { BackgroundItem(url: URL(fileURLWithPath: "/tmp/x.plist"), label: label, program: program, scope: "Your account") }
        XCTAssertEqual(item("com.adobe.ARMDC.Communicator").maker.name, "Adobe")
        XCTAssertEqual(item("com.adobe.ARMDC.Communicator").maker.rest, "ARMDC.Communicator")
        XCTAssertEqual(item("backup-job").maker.name, "backup-job")
        XCTAssertEqual(item("x", "/Applications/OneDrive.app/Contents/Updater.app/Contents/MacOS/u").appPath, "/Applications/OneDrive.app")
        XCTAssertNil(item("x").appPath)
        XCTAssertNil(item("x", "/Library/PrivilegedHelperTools/com.apphousekitchen.helper").appPath)
    }

    func testBackgroundItemSummaryExplainsWhatAndWhen() {
        func item(_ label: String, _ arguments: [String], _ plist: [String: Any], scope: String = "Your account") -> BackgroundItem {
            BackgroundItem(url: URL(fileURLWithPath: "/tmp/x.plist"), label: label, program: arguments[0], scope: scope, arguments: arguments, schedule: BackgroundItem.schedule(plist, scope: scope))
        }
        XCTAssertEqual(item("homebrew.mxcl.mysql", ["/opt/homebrew/opt/mysql/bin/mysqld_safe"], ["RunAtLoad": true, "KeepAlive": true]).summary, "MySQL database server · Always running")
        XCTAssertEqual(item("ch.a.team", ["/n/bin/node", "/Users/someone/Documents/projects/status-server/server.mjs"], ["StartInterval": 3600]).summary, "Runs server.mjs from status-server · Every hour")
        XCTAssertEqual(item("ch.a.b", ["/bin/bash", "/Users/someone/Library/Application Support/Example Backups/runtime/scripts/backup.sh"], ["StartCalendarInterval": ["Hour": 5, "Minute": 0]]).summary, "Runs backup.sh from Example Backups · Daily at 05:00")
        XCTAssertEqual(item("ch.a.b", ["/usr/bin/env", "python3", "-B", "/Users/someone/.local/share/planner/runtime/sync.py"], ["StartInterval": 60]).summary, "Runs sync.py from planner · Every minute")
        XCTAssertEqual(item("com.setapp.DesktopClient.SetappUpdater", ["/x/SetappUpdater.app/Contents/MacOS/u"], ["StartInterval": 21600]).summary, "Keeps Setapp up to date · Every 6 hours")
        XCTAssertEqual(item("com.setapp.DesktopClient.SetappLauncher", ["/x/l"], ["RunAtLoad": true, "KeepAlive": ["Crashed": true]]).summary, "Starts Setapp apps · At login, restarts if it stops")
        XCTAssertEqual(item("com.docker.vmnetd", ["/x/vmnetd"], [:], scope: "System service").summary, "Background program from Docker · Only when needed")
    }
}
