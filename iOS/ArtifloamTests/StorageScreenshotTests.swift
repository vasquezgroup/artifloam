import XCTest
@testable import Artifloam

final class StorageScreenshotTests: XCTestCase {
    private func line(_ text: String, y: Double, x: Double = 0.2) -> OCRLine { OCRLine(text: text, midY: y, minX: x, height: 0.02) }

    func testIPhoneStorageRowsIgnoreLastUsedAndHeader() {
        let rows = StorageScreenshot.rows(from: [
            line("iPhone Storage", y: 0.95),
            line("45 GB of 128 GB Used", y: 0.9),
            line("Netflix", y: 0.81),
            line("Last Used: Yesterday", y: 0.78),
            line("3.2 GB", y: 0.79, x: 0.8),
            line("Genshin Impact", y: 0.71),
            line("Last Used: 01/10/26", y: 0.68),
            line("28,5 GB", y: 0.69, x: 0.8),
        ])
        XCTAssertEqual(rows, [SizedRow(name: "Netflix", bytes: 3_200_000_000), SizedRow(name: "Genshin Impact", bytes: 28_500_000_000)])
    }

    func testSizeUnderChatNameAndOnOneLine() {
        let rows = StorageScreenshot.rows(from: [
            line("Family group", y: 0.8),
            line("1.024 MB", y: 0.77),
            line("Ana 512 MB", y: 0.7),
        ])
        XCTAssertEqual(rows, [SizedRow(name: "Family group", bytes: 1_024_000_000), SizedRow(name: "Ana", bytes: 512_000_000)])
    }

    func testSizeWithNothingNearbyIsDropped() {
        XCTAssertEqual(StorageScreenshot.rows(from: [line("Far away", y: 0.9), line("2 GB", y: 0.5)]), [])
    }

    func testMergeKeepsLargestPerNameAndSorts() {
        let merged = StorageScreenshot.merged([SizedRow(name: "A", bytes: 1), SizedRow(name: "a", bytes: 5), SizedRow(name: "B", bytes: 9)])
        XCTAssertEqual(merged.map(\.bytes), [9, 5])
    }

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

    func testVisionReadsRenderedStorageScreen() async throws {
        let apps = [("Roblox", "11.4 GB"), ("Netflix", "6.2 GB"), ("WhatsApp", "4.8 GB"), ("Genshin Impact", "28.5 GB"), ("Instagram", "2.1 GB")]
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1206, height: 2622)).pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
            func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: UIColor) {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color])
            }
            draw("iPhone Storage", x: 420, y: 150, size: 50, color: .white)
            for (index, app) in apps.enumerated() {
                let y = 320 + CGFloat(index) * 190
                draw(app.0, x: 180, y: y, size: 50, color: .white)
                draw("Last Used: Yesterday", x: 180, y: y + 62, size: 36, color: .gray)
                draw(app.1, x: 930, y: y + 28, size: 46, color: .gray)
            }
        }
        let lines = await AppsStorageView.recognize(data)
        let rows = StorageScreenshot.merged(StorageScreenshot.rows(from: try XCTUnwrap(lines)))
        XCTAssertEqual(rows.map(\.name), ["Genshin Impact", "Roblox", "Netflix", "WhatsApp", "Instagram"])
        XCTAssertEqual(rows.first?.bytes, 28_500_000_000)
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
        XCTAssertNil(StorageAdvice.lookup("Toca Studios", source: .apps).scheme)
        XCTAssertNotNil(StorageAdvice.lookup("Toca Studios", source: .apps).warning)
        XCTAssertEqual(StorageAdvice.lookup("Netflix", source: .apps).scheme, "nflx://")
        XCTAssertNotNil(StorageAdvice.lookup("Roblox", source: .apps).warning)
        XCTAssertEqual(StorageAdvice.lookup("Family group", source: .whatsapp).scheme, "whatsapp://")
    }

    func testDuplicateExtrasKeepOldest() {
        let items = [("x", 2.0), ("x", 1.0), ("x", 3.0), ("y", 1.0)]
        let extras = duplicateExtras(items, key: \.0, date: { Date(timeIntervalSince1970: $0.1) })
        XCTAssertEqual(extras.map(\.1).sorted(), [2, 3])
    }
}
