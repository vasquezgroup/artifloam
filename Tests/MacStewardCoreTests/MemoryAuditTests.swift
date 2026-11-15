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
        XCTAssertEqual(value.apps.first { !$0.app.isVirtualMachine }?.id, getpid(), "a running VM gets its own row")
        XCTAssertGreaterThan(value.apps.first?.bytes ?? 0, 0)
    }
    func testLiveReadingIsBoundedAndDoesNotManageProcesses() throws {
        let value = try MemoryReading.capture(apps: [])
        XCTAssertGreaterThan(value.total, 0)
        XCTAssertEqual(value.used + value.available, value.total)
        XCTAssertLessThanOrEqual(value.cached, value.total)
        XCTAssertTrue(value.apps.allSatisfy(\.app.isVirtualMachine), "only VMs, listed without being asked for")
    }
    func testRepeatedAppIsMeasuredOnce() throws {
        let app = MemoryAppDescriptor(pid: getpid(), name: "Fixture", bundlePath: "/fixture")
        XCTAssertEqual(try MemoryReading.capture(apps: [app, app]).apps.filter { !$0.app.isVirtualMachine }.count, 1)
    }
    func testVerdictAndSuggestions() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .normal, swap: 0, total: 32 * gb, loginItems: 2), MemoryVerdict(state: .fine, score: 100))
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .normal, swap: 10 * gb, total: 32 * gb, loginItems: 6), MemoryVerdict(state: .busy, score: 85))
        XCTAssertEqual(MemoryVerdict.evaluate(pressure: .critical, swap: 20 * gb, total: 32 * gb, loginItems: 12).state, .tight)
        let rows = [(1, 5 * gb), (2, 4 * gb), (3, 3 * gb), (4, 2 * gb), (5, 100 << 20)].map { MemoryAppUsage(app: MemoryAppDescriptor(pid: Int32($0.0), name: "", bundlePath: ""), bytes: $0.1, processCount: 1) }
        XCTAssertEqual(MemoryVerdict.suggestions(rows, recentlyUsed: [2], canQuit: { $0.id != 3 }).map(\.id), [1, 4])
    }
    func testOverloadedProcessorLowersScoreAndNamesBusiestProcesses() {
        let gb: UInt64 = 1 << 30
        let ps = " 98.0 /Applications/Android Studio.app/Contents/MacOS/studio\n 450.5 /Users/a/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64\n 60.0 /usr/libexec/Helper\n 70.0 /usr/libexec/Helper\n  0.5 /bin/zsh\n garbage\n"
        XCTAssertEqual(CPULoad.busiest(ps: ps), ["qemu-system-aarch64", "Helper", "studio"])
        let calm = MemoryVerdict.evaluate(pressure: .normal, swap: 0, total: 32 * gb, loginItems: 2, load: CPULoad(oneMinute: 3, fiveMinutes: 4, cores: 12))
        let busy = MemoryVerdict.evaluate(pressure: .normal, swap: 0, total: 32 * gb, loginItems: 2, load: CPULoad(oneMinute: 300, fiveMinutes: 250, cores: 12, busiest: CPULoad.busiest(ps: ps)))
        XCTAssertEqual(calm.state, .fine); XCTAssertEqual(calm.score, 100); XCTAssertFalse(calm.cpuOverloaded)
        XCTAssertLessThan(busy.score, calm.score); XCTAssertNotEqual(busy.state, .fine)
        XCTAssertEqual(busy.busiest, ["qemu-system-aarch64", "Helper", "studio"])
        // A one-minute spike alone isn't "staying" overloaded.
        XCTAssertFalse(MemoryVerdict.evaluate(pressure: .normal, swap: 0, total: 32 * gb, loginItems: 0, load: CPULoad(oneMinute: 80, fiveMinutes: 6, cores: 12)).cpuOverloaded)
    }
    func testRestartIsSuggestedForLargeSwapAfterDaysOn() {
        let gb: UInt64 = 1 << 30, day: TimeInterval = 86_400
        XCTAssertTrue(MemoryVerdict.suggestsRestart(swap: 24 * gb, total: 36 * gb, uptime: 7 * day))
        XCTAssertFalse(MemoryVerdict.suggestsRestart(swap: 24 * gb, total: 36 * gb, uptime: 2 * day))
        XCTAssertFalse(MemoryVerdict.suggestsRestart(swap: 4 * gb, total: 36 * gb, uptime: 7 * day))
        XCTAssertFalse(MemoryVerdict.suggestsRestart(swap: nil, total: 36 * gb, uptime: 7 * day))
    }
    func testEmulatorsAndVirtualMachinesAreNamed() {
        let qemu = "/Users/a/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"
        XCTAssertEqual(MemoryReading.virtualMachineName(path: qemu, arguments: ["-netdelay", "none", "-avd", "Pixel_8_API_35"]), "Android emulator · Pixel_8_API_35")
        XCTAssertEqual(MemoryReading.virtualMachineName(path: qemu, arguments: []), "Android emulator")
        XCTAssertNil(MemoryReading.virtualMachineName(path: "/opt/homebrew/bin/qemu-system-aarch64", arguments: []))
        XCTAssertEqual(MemoryReading.virtualMachineName(path: "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher", arguments: []), "UTM virtual machine")
        XCTAssertEqual(MemoryReading.virtualMachineName(path: "/Applications/Docker.app/Contents/MacOS/com.docker.krun", arguments: []), "Docker virtual machine")
        XCTAssertNil(MemoryReading.virtualMachineName(path: "/Applications/Safari.app/Contents/MacOS/Safari", arguments: []))
        let vm = MemoryAppUsage(app: MemoryAppDescriptor(pid: 9, name: "Android emulator", bundlePath: qemu, isVirtualMachine: true), bytes: 4 << 30, processCount: 1)
        XCTAssertTrue(MemoryVerdict.suggestions([vm], recentlyUsed: [], canQuit: { _ in true }).isEmpty, "A VM is never ticked as an idle app")
    }
    func testOwnArgumentsAreRead() {
        XCTAssertEqual(MemoryReading.arguments(getpid()), Array(CommandLine.arguments.dropFirst()))
    }
    func testOwnFootprintIsMeasured() {
        XCTAssertGreaterThan(MemoryReading.ownFootprint() ?? 0, 0)
    }
}

