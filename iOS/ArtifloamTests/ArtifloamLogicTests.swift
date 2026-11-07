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

    func testPinchMovesOneColumnAtATimeAndStaysInRange() {
        XCTAssertEqual(columns(from: 3, pinch: 1.5), 2)
        XCTAssertEqual(columns(from: 3, pinch: 0.6), 4)
        XCTAssertEqual(columns(from: 3, pinch: 1.05), 3)
        XCTAssertEqual(columns(from: 1, pinch: 3), 1)
        XCTAssertEqual(columns(from: 7, pinch: 0.2), 7)
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

}
