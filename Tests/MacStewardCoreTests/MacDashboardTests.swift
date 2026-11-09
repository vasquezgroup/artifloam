import XCTest
@testable import MacStewardCore

final class MacDashboardTests: XCTestCase {
    func testCPUUsesCounterDeltasAndHandlesTickRollover() {
        let previous = CPUCounters(user: 10, system: 20, idle: 100, nice: 0)
        XCTAssertEqual(CPUCounters(user: 20, system: 30, idle: 180, nice: 0).usage(since: previous)!, 20, accuracy: 0.001)
        XCTAssertNil(previous.usage(since: previous))
        let rollover = CPUCounters(user: UInt32.max - 4, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(CPUCounters(user: 5, system: 0, idle: 10, nice: 0).usage(since: rollover)!, 50, accuracy: 0.001)
    }
    /// The per-core counters move every half second, idle included; the whole-Mac counter often didn't, which read as 100 %.
    func testCPUReadingMovesWithinHalfASecond() throws {
        let before = try XCTUnwrap(CPUCounters.perCore())
        Thread.sleep(forTimeInterval: 0.5)
        let after = try XCTUnwrap(CPUCounters.perCore())
        XCTAssertGreaterThan(after.user + after.system + after.idle, before.user + before.system + before.idle)
        XCTAssertNotNil(CPUCounters.read())
    }
    func testCPUSplitBatteryHealthAndAppCPURate() {
        let split = CPUCounters(user: 30, system: 20, idle: 150, nice: 0).split(since: CPUCounters(user: 10, system: 10, idle: 80, nice: 0))!
        XCTAssertEqual(split.user, 20, accuracy: 0.001); XCTAssertEqual(split.system, 10, accuracy: 0.001); XCTAssertEqual(split.idle, 70, accuracy: 0.001)
        XCTAssertEqual(MacBattery.health(nominal: 7354, design: 8579), 85)
        XCTAssertNil(MacBattery.health(nominal: 7354, design: 0))
        XCTAssertEqual(MemoryAppUsage.cpuPercent(now: 3_000_000_000, before: 1_000_000_000, seconds: 2)!, 100, accuracy: 0.001)
        XCTAssertNil(MemoryAppUsage.cpuPercent(now: 1, before: 2, seconds: 2))
    }
    func testNetworkRatesRejectResetsInterfaceChangesAndStaleSamples() {
        let before = NetworkCounters(interface: "en0", kind: "Wi-Fi", received: 1000, sent: 500)
        let after = NetworkCounters(interface: "en0", kind: "Wi-Fi", received: 5000, sent: 1500)
        XCTAssertEqual(after.rates(since: before, interval: 2)?.download, 2000)
        XCTAssertEqual(after.rates(since: before, interval: 2)?.upload, 500)
        XCTAssertNil(after.rates(since: before, interval: 0))
        XCTAssertNil(after.rates(since: before, interval: 60))
        XCTAssertNil(before.rates(since: after, interval: 2))
        XCTAssertNil(NetworkCounters(interface: "en1", kind: "Ethernet", received: 6000, sent: 2500).rates(since: before, interval: 2))
    }
    func testLiveReadIsBoundedAndDoesNotInventUnavailableSensors() {
        let start = Date(), sample = MacDashboard.sample(includeDevices: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertGreaterThan(sample.uptime, 0)
        XCTAssertGreaterThan(sample.disk.total, 0)
        XCTAssertTrue(["Normal", "Warm", "High", "Critical", "Unavailable"].contains(sample.thermalState))
        if let percent = sample.battery?.percent { XCTAssertTrue((0...100).contains(percent)) }
        let devices = sample.devices ?? []
        XCTAssertEqual(devices.count, Set(devices.map(\.id)).count)
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty && !$0.transport.isEmpty })
        XCTAssertNil(MacDashboard.sample(includeDevices: false).devices)
    }
}
