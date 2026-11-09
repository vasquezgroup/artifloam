import Contacts
import XCTest
@testable import Artifloam

final class ArtifloamLogicTests: XCTestCase {

    private func picture(_ draw: (CGContext) -> Void) -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { draw($0.cgContext) }.cgImage!
    }

    func testDifferenceHashMatchesNearCopiesOnly() {
        func scene(_ shift: CGFloat, _ context: CGContext) {
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.setFillColor(UIColor.black.cgColor); context.fill(CGRect(x: 30 + shift, y: 40, width: 70, height: 110))
            context.setFillColor(UIColor.gray.cgColor); context.fill(CGRect(x: 120 + shift, y: 20, width: 40, height: 160))
        }
        let shot = differenceHash(of: picture { scene(0, $0) })
        let next = differenceHash(of: picture { scene(2, $0) })
        let other = differenceHash(of: picture { context in
            for i in 0..<10 {
                context.setFillColor(UIColor(white: CGFloat(i) / 10, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: CGFloat(i) * 20, width: 200, height: 20))
                context.setFillColor(UIColor(white: CGFloat(9 - i) / 10, alpha: 1).cgColor)
                context.fill(CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 200))
            }
        })
        XCTAssertLessThanOrEqual((shot ^ next).nonzeroBitCount, LibraryScan.similarBits)
        XCTAssertGreaterThan((shot ^ other).nonzeroBitCount, LibraryScan.similarBits)
    }

    func testLaplacianVarianceSeparatesDetailFromFlat() {
        let flat = [UInt8](repeating: 120, count: 2500)
        let checker: [UInt8] = (0..<2500).map { (i: Int) -> UInt8 in (i % 50 + i / 50) % 2 == 0 ? 0 : 255 }
        XCTAssertEqual(laplacianVariance(flat, width: 50, height: 50), 0)
        XCTAssertGreaterThan(laplacianVariance(checker, width: 50, height: 50), 1000)
    }

    func testTimeClustersSplitOnGapsAndDropSingles() {
        let dates = [0.0, 5, 10, 100, 200, 205].map(Date.init(timeIntervalSince1970:))
        XCTAssertEqual(timeClusters(dates, gap: 30), [[0, 1, 2], [4, 5]])
    }

    func testCompressedCopyMustSaveAtLeastTenPercent() {
        XCTAssertTrue(MediaChanges.isWorthKeeping(original: 100, compressed: 90))
        XCTAssertFalse(MediaChanges.isWorthKeeping(original: 100, compressed: 91))
        XCTAssertFalse(MediaChanges.isWorthKeeping(original: 100, compressed: 0))
    }

    func testSpaceHistoryKeepsOnePointADay() {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let one = SpaceHistory.adding(SpacePoint(date: day, free: 1), to: [])
        let same = SpaceHistory.adding(SpacePoint(date: day.addingTimeInterval(60), free: 2), to: one)
        XCTAssertEqual(same.map(\.free), [2])
        XCTAssertEqual(SpaceHistory.adding(SpacePoint(date: day.addingTimeInterval(200_000), free: 3), to: same).map(\.free), [2, 3])
    }

    private func contact(_ given: String, phones: [String] = [], emails: [String] = [], org: String = "") -> CNContact {
        let c = CNMutableContact()
        c.givenName = given
        c.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        c.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        c.organizationName = org
        return c
    }

    func testMergeKeepsEverythingWithoutRepeats() throws {
        let full = contact("Ana", phones: ["+41 79 123 45 67", "044 111 22 33", "044 222 33 44"], emails: ["a@b.ch"])
        let extra = contact("Ana", phones: ["079 123 45 67"], emails: ["A@B.CH", "work@b.ch"], org: "Acme")
        let merged = try XCTUnwrap(ContactsCleanup.merged([extra, full]))
        XCTAssertEqual(merged.identifier, full.identifier)
        XCTAssertEqual(merged.phoneNumbers.count, 3)
        XCTAssertEqual(merged.emailAddresses.map { $0.value as String }, ["a@b.ch", "work@b.ch"])
        XCTAssertEqual(merged.organizationName, "Acme")
    }

    func testHealthScoreFallsOnlyForRealIssues() {
        var reading = DeviceReading(free: 50, total: 100, purgeable: 0, passcode: true, biometrics: "Face ID", iosVersion: "27", model: "x", lowPower: true, heat: .nominal, battery: 0.9, charging: false, memory: 1, cores: 1, uptime: 90_000_000)
        XCTAssertEqual(HealthReport(reading: reading).score, 100)
        reading.free = 8
        XCTAssertEqual(HealthReport(reading: reading).score, 90)
        reading.free = 3
        reading.passcode = false
        XCTAssertEqual(HealthReport(reading: reading).score, 40)
    }

    func testDaysUntilFullNeedsAWeekAndShrinkingSpace() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func point(_ day: Double, _ free: Int64) -> SpacePoint { SpacePoint(date: start.addingTimeInterval(day * 86_400), free: free) }
        XCTAssertEqual(SpaceHistory.daysUntilFull([point(0, 100), point(10, 90)]), 90)
        XCTAssertNil(SpaceHistory.daysUntilFull([point(0, 100), point(3, 90)]))
        XCTAssertNil(SpaceHistory.daysUntilFull([point(0, 90), point(10, 100)]))
    }

    func testSwipeSelectsTheRangeAndLeavesTheRestAlone() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(swipeSelection(base: ["e"], ids: ids, anchor: 1, current: 3, selecting: true), ["b", "c", "d", "e"])
        XCTAssertEqual(swipeSelection(base: ["e"], ids: ids, anchor: 3, current: 1, selecting: true), ["b", "c", "d", "e"])
        XCTAssertEqual(swipeSelection(base: ["a", "b", "c"], ids: ids, anchor: 1, current: 2, selecting: false), ["a"])
    }


    func testLowSpaceIsUnderTenPercent() {
        XCTAssertTrue(SpaceReminder.isLow(free: 9, total: 100))
        XCTAssertFalse(SpaceReminder.isLow(free: 10, total: 100))
        XCTAssertFalse(SpaceReminder.isLow(free: 0, total: 0))
    }

    func testContactsMergeOnlyWithSameNameAndSharedDetail() {
        let contacts = [
            ContactKey(id: "1", name: "Ana Silva", phones: ["791234567"], emails: []),
            ContactKey(id: "2", name: "ana silva", phones: ["791234567"], emails: ["a@b.ch"]),
            ContactKey(id: "3", name: "Ana Silva", phones: [], emails: ["a@b.ch"]),
            ContactKey(id: "4", name: "Ana Silva", phones: ["700000000"], emails: []),
            ContactKey(id: "5", name: "Ben", phones: ["791234567"], emails: []),
            ContactKey(id: "6", name: "", phones: ["791234567"], emails: []),
        ]
        XCTAssertEqual(duplicateContactGroups(contacts).map { Set($0) }, [["1", "2", "3"]])
        XCTAssertEqual(normalizedPhone("+41 79 123 45 67"), normalizedPhone("079 123 45 67"))
    }

    func testLargestFilesFirstAcrossFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 500_000).write(to: root.appendingPathComponent("a/big.bin"))
        try Data(count: 50_000).write(to: root.appendingPathComponent("small.bin"))
        XCTAssertEqual(largestFiles(in: root, limit: 1).map(\.url.lastPathComponent), ["big.bin"])
    }

    func testBucketsFromVisionLabels() {
        XCTAssertEqual(LibraryBucket.bucket(for: ["dog", "outdoor"]), .pets)
        XCTAssertEqual(LibraryBucket.bucket(for: ["document"]), .documents)
        XCTAssertEqual(LibraryBucket.bucket(for: []), .other)
    }

    func testAdviceDoesNotMatchInsideOtherNames() {
        XCTAssertNil(StorageAdvice.lookup("Toca Studios").scheme)
        XCTAssertNotNil(StorageAdvice.lookup("Toca Studios").warning)
        XCTAssertEqual(StorageAdvice.lookup("Netflix").scheme, "nflx://")
        XCTAssertNotNil(StorageAdvice.lookup("Roblox").warning)
        XCTAssertEqual(StorageAdvice.lookup("WhatsApp").scheme, "whatsapp://")
    }

    func testScanCacheForgetsEditedItems() {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let date = Date(timeIntervalSince1970: 1000)
        let facts = ScanFacts(modified: date, bytes: 5, local: nil, pairedVideo: 0, name: "a")
        let cache = ScanCache(file: file)
        cache.store(facts, id: "x")
        cache.save()
        let reopened = ScanCache(file: file)
        XCTAssertEqual(reopened.facts(id: "x", modified: date), facts)
        XCTAssertNil(reopened.facts(id: "x", modified: date.addingTimeInterval(1)))
        XCTAssertNil(reopened.facts(id: "y", modified: date))
    }

    func testEdgeDirectionOnlyScrollsAtTheEdges() {
        XCTAssertTrue(swipeStarts(CGSize(width: 15, height: 4)))
        XCTAssertFalse(swipeStarts(CGSize(width: 6, height: 14)))
        XCTAssertEqual(edgeDirection(y: 50, height: 800), -1)
        XCTAssertEqual(edgeDirection(y: 400, height: 800), 0)
        XCTAssertEqual(edgeDirection(y: 700, height: 800), 1)
    }

    func testLibrarySizesLandInTheRightRows() {
        var counts = LibraryCounts()
        counts.add(ScanFacts(modified: nil, bytes: 10, local: nil, pairedVideo: 3, name: nil), video: false, screenshot: false)
        counts.add(ScanFacts(modified: nil, bytes: 20, local: nil, pairedVideo: 0, name: nil), video: true, screenshot: false)
        counts.add(ScanFacts(modified: nil, bytes: 5, local: nil, pairedVideo: 0, name: nil), video: false, screenshot: true)
        XCTAssertEqual(counts.photoBytes, 10)
        XCTAssertEqual(counts.videoBytes, 20)
        XCTAssertEqual(counts.screenshotBytes, 5)
        XCTAssertEqual(counts.livePhotoBytes, 3)
    }

    func testMacAppListDecodesWhatTheMacWrites() throws {
        let json = #"{"readAt":"2026-11-07T12:00:00Z","apps":[{"name":"Netflix","appBytes":10,"dataBytes":20}]}"#
        let list = try XCTUnwrap(MacAppList.decode(Data(json.utf8)))
        XCTAssertEqual(list.apps.first?.name, "Netflix")
        XCTAssertEqual(list.apps.first?.dataBytes, 20)
        XCTAssertNil(MacAppList.decode(Data("nonsense".utf8)))
    }

    func testRoomCheckNeedsTwiceTheSize() {
        XCTAssertTrue(MediaChanges.hasRoom(for: 100, free: 200))
        XCTAssertFalse(MediaChanges.hasRoom(for: 100, free: 199))
    }

    func testAppListOnlyOpensWithTheSameContainer() throws {
        let path = "/private/var/mobile/Containers/Data/Application/6E1F0E2A-3B4C-4D5E-8F90-1A2B3C4D5E6F"
        let secret = try XCTUnwrap(AppListLink.secret(fromContainer: path))
        let other = try XCTUnwrap(AppListLink.secret(fromContainer: "/x/11111111-2222-4333-8444-555555555555"))
        let sealed = try XCTUnwrap(AppListLink.seal(Data("list".utf8), secret: secret))
        XCTAssertEqual(AppListLink.open(sealed, secret: secret), Data("list".utf8))
        XCTAssertNil(AppListLink.open(sealed, secret: other))
        XCTAssertNotEqual(AppListLink.serviceName(secret: secret), AppListLink.serviceName(secret: other))
        XCTAssertNil(AppListLink.secret(fromContainer: "/not/an/id"))
    }

    func testZoomLevelsCrossFadeBetweenNeighbours() {
        let width: CGFloat = 400
        let three = ZoomLevels.side(columns: 3, width: width), two = ZoomLevels.side(columns: 2, width: width)
        XCTAssertEqual(ZoomLevels.between(side: three, width: width).from, 5)
        XCTAssertEqual(ZoomLevels.between(side: three, width: width).to, 3)
        XCTAssertEqual(ZoomLevels.between(side: three, width: width).progress, 1, accuracy: 0.001)
        let middle = ZoomLevels.between(side: (three + two) / 2, width: width)
        XCTAssertEqual(middle.from, 3)
        XCTAssertEqual(middle.to, 2)
        XCTAssertEqual(ZoomLevels.nearest(side: three * 1.05, width: width), 3)
        XCTAssertLessThan(ZoomLevels.resisted(side: width * 2, width: width), width * 2)
        XCTAssertGreaterThan(ZoomLevels.resisted(side: width * 2, width: width), width)
    }

    func testWideScreensGetMoreColumnsAndKeepTheLevelWhenResized() {
        XCTAssertEqual(ZoomLevels.columns(402), [7, 5, 3, 2, 1])
        let iPad = ZoomLevels.columns(1100)
        XCTAssertEqual(iPad, [18, 13, 8, 5, 2])
        XCTAssertTrue(ZoomLevels.large(5, width: 1100))
        XCTAssertFalse(ZoomLevels.large(8, width: 1100))
        // Unfolding: three iPhone columns become the iPad's middle level, and folding brings them back.
        XCTAssertEqual(ZoomLevels.fitted(3, from: 402, to: 1100), 8)
        XCTAssertEqual(ZoomLevels.fitted(8, from: 1100, to: 402), 3)
        XCTAssertEqual(ZoomLevels.fitted(3, from: 0, to: 1100), 8)
    }

    func testZoomRectsMatchTheRealGridSpacing() {
        let rects = ZoomLevels.rects(groups: [4, 1], ratios: [1, 1, 1, 1, 1], columns: 3, width: 304)
        XCTAssertEqual(rects[0], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rects[2], CGRect(x: 204, y: 0, width: 100, height: 100))
        XCTAssertEqual(rects[3], CGRect(x: 0, y: 102, width: 100, height: 100))
        // The next group starts after both rows.
        XCTAssertEqual(rects[4].minY, 204)
        let whole = ZoomLevels.rects(groups: [2], ratios: [2, 1], columns: 1, width: 100)
        XCTAssertEqual(whole[0].height, 50)
        XCTAssertEqual(whole[1].minY, 52)
    }

    func testZoomStopsAtTheEndsOfTheList() {
        // Free to move in the middle of a long list.
        XCTAssertEqual(ZoomLevels.offset(wanted: -500, contentHeight: 5000, top: 100, bottom: 800), -500)
        // Not past the top, which would leave a gap above it.
        XCTAssertEqual(ZoomLevels.offset(wanted: 300, contentHeight: 5000, top: 100, bottom: 800), 100)
        // Not past the bottom either.
        XCTAssertEqual(ZoomLevels.offset(wanted: -9000, contentHeight: 5000, top: 100, bottom: 800), -4200)
        // A short list stays at the top.
        XCTAssertEqual(ZoomLevels.offset(wanted: -50, contentHeight: 300, top: 100, bottom: 800), 100)
    }

    func testTwoFingersBlockSelectionUntilAllHaveLifted() {
        var fingers = FingerCount()
        fingers.began(1)
        XCTAssertFalse(fingers.sawTwo)
        fingers.began(1)
        XCTAssertTrue(fingers.sawTwo)
        // One finger left, still moving on the screen: that's the case that selected photos.
        fingers.ended(1)
        XCTAssertEqual(fingers.down, 1)
        XCTAssertTrue(fingers.sawTwo)
        fingers.ended(1)
        XCTAssertEqual(fingers.down, 0)
        // The next touch starts fresh.
        fingers.began(1)
        XCTAssertFalse(fingers.sawTwo)
    }
}
