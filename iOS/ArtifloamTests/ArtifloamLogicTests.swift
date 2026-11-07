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
