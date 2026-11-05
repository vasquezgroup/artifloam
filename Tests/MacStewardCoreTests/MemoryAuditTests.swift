import XCTest
@testable import MacStewardCore

final class MemoryAuditTests: XCTestCase {
    func testPressureUsesKernelDispatchLevels() {
        XCTAssertEqual(MemoryPressure(dispatchLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(dispatchLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(dispatchLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(dispatchLevel: nil), .unknown)
        XCTAssertEqual(MemoryPressure(dispatchLevel: 77), .unknown)
    }
    func testAccountingDoesNotDoubleCountInactiveFilePages() {
        let value = MemoryReading.accounting(total: 1000, free: 100, inactive: 400, speculative: 20, purgeable: 30, external: 300)
        XCTAssertEqual(value.available, 450)
        XCTAssertEqual(value.used, 550)
        XCTAssertEqual(value.cached, 330)
        let capped = MemoryReading.accounting(total: 100, free: 100, inactive: 400, speculative: 20, purgeable: 30, external: 300)
        XCTAssertEqual(capped.available, 100)
        XCTAssertEqual(capped.used, 0)
    }
    func testOwnProcessCanBeMeasuredWithoutTaskAccess() throws {
        let app = MemoryAppDescriptor(pid: getpid(), name: "Fixture", bundlePath: "/fixture")
        let value = try MemoryReading.capture(apps: [app])
        XCTAssertEqual(value.apps.first?.id, getpid())
        XCTAssertGreaterThan(value.apps.first?.bytes ?? 0, 0)
    }
    func testLiveReadingIsBoundedAndDoesNotManageProcesses() throws {
        let value = try MemoryReading.capture(apps: [])
        XCTAssertGreaterThan(value.total, 0)
        XCTAssertEqual(value.used + value.available, value.total)
        XCTAssertLessThanOrEqual(value.cached, value.total)
        XCTAssertTrue(value.apps.isEmpty)
    }
    func testRepeatedAppIsMeasuredOnce() throws {
        let app = MemoryAppDescriptor(pid: getpid(), name: "Fixture", bundlePath: "/fixture")
        XCTAssertEqual(try MemoryReading.capture(apps: [app, app]).apps.count, 1)
    }
    func testVerdictAndSuggestions() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .normal, swap: 0, total: 32 * gb, loginItems: 2), MemoryVerdict(state: .fine, score: 100))
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .normal, swap: 10 * gb, total: 32 * gb, loginItems: 6), MemoryVerdict(state: .busy, score: 85))
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .critical, swap: 20 * gb, total: 32 * gb, loginItems: 12).state, .tight)
        let rows = [(1, 5 * gb), (2, 4 * gb), (3, 3 * gb), (4, 2 * gb), (5, 100 << 20)].map { MemoryAppUsage(app: MemoryAppDescriptor(pid: Int32($0.0), name: "", bundlePath: ""), bytes: $0.1, processCount: 1) }
        XCTAssertEqual(MemoryVerdict.suggestions(rows, recentlyUsed: [2], canQuit: { $0.id != 3 }).map(\.id), [1, 4])
    }
    func testOwnFootprintIsMeasured() {
        XCTAssertGreaterThan(MemoryReading.ownFootprint() ?? 0, 0)
    }
}

