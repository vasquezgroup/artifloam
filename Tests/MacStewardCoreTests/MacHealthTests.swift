import XCTest
@testable import MacStewardCore

final class MacHealthTests: XCTestCase {
    private let gb: UInt64 = 1 << 30
    func testHealthyMacHasNoIssues() {
        var input = MacHealthInput(); input.diskFree = 200 * gb; input.diskTotal = 1000 * gb; input.ram = 32 * gb; input.swap = 1 * gb
        let health = MacHealth.evaluate(input)
        XCTAssertEqual(health.score, 100); XCTAssertEqual(health.level, "Smooth"); XCTAssertTrue(health.issues.isEmpty)
    }
    func testShortSpikesDoNotCountButSustainedProblemsDo() {
        var input = MacHealthInput(); input.diskFree = 50 * gb; input.diskTotal = 1000 * gb; input.ram = 32 * gb
        input.busyApp = .init(pid: 7, name: "Claude", percent: 120, seconds: 60)
        input.pressure = .critical; input.pressureHighFor = 30
        XCTAssertEqual(MacHealth.evaluate(input).issues.map(\.kind), [.storage])
        input.busyApp = .init(pid: 7, name: "Claude", percent: 120, seconds: 480); input.pressureHighFor = 400
        let health = MacHealth.evaluate(input)
        XCTAssertEqual(health.issues.map(\.kind), [.memory, .storage, .cpu])
        XCTAssertEqual(health.score, 100 - 15 - 12 - 6); XCTAssertEqual(health.level, "Struggling")
        XCTAssertEqual(health.issues.last?.fix, .quit(pid: 7)); XCTAssertEqual(health.issues.last?.title, "Claude is busy for 8 min")
    }
    func testFrozenAppsAndIgnoredQuitOfferForceQuit() {
        var input = MacHealthInput(); input.diskFree = 200 * gb; input.diskTotal = 1000 * gb
        input.busyApp = .init(pid: 9, name: "Artifloam", percent: 99, seconds: 700)
        let pinned = MacHealth.evaluate(input).issues.first
        XCTAssertEqual(pinned?.title, "Artifloam may not be responding"); XCTAssertEqual(pinned?.fix, .quit(pid: 9))
        input.busyApp = .init(pid: 9, name: "Artifloam", percent: 99, seconds: 700, ignoredQuit: true)
        XCTAssertEqual(MacHealth.evaluate(input).issues.first?.fix, .forceQuit(pid: 9))
        XCTAssertEqual(MacHealth.evaluate(input).issues.first?.fixLabel, "Force quit")
        input.busyApp = .init(pid: 9, name: "Xcode", percent: 340, seconds: 700)
        XCTAssertEqual(MacHealth.evaluate(input).issues.first?.title, "Xcode is busy for 11 min", "many cores busy is work, not a freeze")
    }
    func testForecastRestartAndBattery() {
        var input = MacHealthInput(); input.diskFree = 200 * gb; input.diskTotal = 1000 * gb; input.daysUntilFull = 9
        input.ram = 32 * gb; input.swap = 10 * gb; input.uptime = 9 * 86_400; input.batteryHealth = 75
        XCTAssertEqual(MacHealth.evaluate(input).issues.map(\.kind), [.storage, .restart, .battery])
        input.onBattery = true; input.batteryPercent = 12
        XCTAssertEqual(MacHealth.evaluate(input).issues.first { $0.kind == .battery }?.flag, "12% left")
    }
    func testDiskForecastNeedsASteadyFall() {
        let day: TimeInterval = 86_400, start = Date(timeIntervalSince1970: 1_800_000_000)
        var samples = [DiskForecast.Sample]()
        for (offset, free) in [100, 96, 92, 88].enumerated() { samples = DiskForecast.record(free: UInt64(free) * gb, at: start.addingTimeInterval(Double(offset) * day), into: samples) }
        XCTAssertEqual(DiskForecast.daysUntilFull(samples, now: start.addingTimeInterval(3 * day)), 22)
        samples = DiskForecast.record(free: 90 * gb, at: start.addingTimeInterval(3 * day + 3600), into: samples)
        XCTAssertEqual(samples.count, 4, "a second reading on the same day replaces the first")
        XCTAssertNil(DiskForecast.daysUntilFull(Array(samples.prefix(2)), now: start.addingTimeInterval(day)), "two days is too short a trend")
        let growing = [100, 110].enumerated().map { DiskForecast.Sample(day: start.addingTimeInterval(Double($0.offset) * 5 * day), free: UInt64($0.element) * gb) }
        XCTAssertNil(DiskForecast.daysUntilFull(growing, now: start.addingTimeInterval(5 * day)))
    }
}
