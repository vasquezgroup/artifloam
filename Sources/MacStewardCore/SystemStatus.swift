import Foundation
import Darwin
import IOKit
import IOKit.ps

/// One reading of the Status page. Rates are per second since the previous reading.
public struct SystemStatusReading: Sendable {
    public let cpuPercent: Double
    public let cores: Int
    public let load: Double
    public let diskFree: UInt64
    public let diskTotal: UInt64
    public let diskReadPerSecond: UInt64
    public let diskWritePerSecond: UInt64
    public let networkInPerSecond: UInt64
    public let networkOutPerSecond: UInt64
    public let battery: Battery?
    public let thermal: String
    public let uptime: TimeInterval
    public let processes: [ProcessUsage]
    public struct Battery: Sendable {
        public let percent: Int
        public let charging: Bool
        public let onPower: Bool
        /// Full-charge capacity as a share of design capacity, when the battery reports it.
        public let health: Int?
        public let cycles: Int?
    }
}
public struct ProcessUsage: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let memory: UInt64
}

/// Keeps the previous counters so each reading can report rates. No admin rights needed.
public final class SystemStatusSampler: @unchecked Sendable {
    private var lastCPU: (busy: Double, total: Double)?
    private var lastDisk: (read: UInt64, write: UInt64, at: Date)?
    private var lastNetwork: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    public init() {}

    public func read() -> SystemStatusReading {
        let now = Date()
        let cpu = cpuTicks(), disk = diskBytes(), network = networkBytes()
        var cpuPercent = 0.0
        if let last = lastCPU, cpu.total > last.total { cpuPercent = (cpu.busy - last.busy) / (cpu.total - last.total) * 100 }
        lastCPU = cpu
        func rate(_ value: UInt64, _ previous: UInt64?, _ since: Date?) -> UInt64 {
            guard let previous, let since, value >= previous, now.timeIntervalSince(since) > 0 else { return 0 }
            return UInt64(Double(value - previous) / now.timeIntervalSince(since))
        }
        let reading = SystemStatusReading(
            cpuPercent: max(0, min(100, cpuPercent)), cores: ProcessInfo.processInfo.activeProcessorCount, load: loadAverage(),
            diskFree: DiskSpace.read().free, diskTotal: DiskSpace.read().total,
            diskReadPerSecond: rate(disk.read, lastDisk?.read, lastDisk?.at), diskWritePerSecond: rate(disk.write, lastDisk?.write, lastDisk?.at),
            networkInPerSecond: rate(network.inBytes, lastNetwork?.inBytes, lastNetwork?.at), networkOutPerSecond: rate(network.outBytes, lastNetwork?.outBytes, lastNetwork?.at),
            battery: Self.battery(), thermal: Self.thermal(), uptime: ProcessInfo.processInfo.systemUptime, processes: Self.processes())
        lastDisk = (disk.read, disk.write, now); lastNetwork = (network.inBytes, network.outBytes, now)
        return reading
    }

    func cpuTicks() -> (busy: Double, total: Double) {
        var info = host_cpu_load_info(), count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = Double(info.cpu_ticks.0), system = Double(info.cpu_ticks.1), idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }
    func loadAverage() -> Double { var values = [Double](repeating: 0, count: 3); return getloadavg(&values, 3) > 0 ? values[0] : 0 }
    /// Cumulative bytes from every block storage driver's statistics.
    func diskBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return (read, write)
    }
    /// Cumulative bytes on physical interfaces (loopback excluded).
    func networkBytes() -> (inBytes: UInt64, outBytes: UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes += UInt64(stats.ifi_ibytes); outBytes += UInt64(stats.ifi_obytes)
        }
        return (inBytes, outBytes)
    }
    static func battery() -> SystemStatusReading.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.lazy.compactMap({ IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else { return nil }
        let current = source[kIOPSCurrentCapacityKey] as? Int ?? 0, maximum = max(1, source[kIOPSMaxCapacityKey] as? Int ?? 100)
        var health: Int?, cycles: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Int? { (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
            if let full = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"), let design = value("DesignCapacity"), design > 0 { health = min(100, full * 100 / design) }
            cycles = value("CycleCount")
        }
        return .init(percent: current * 100 / maximum, charging: source[kIOPSIsChargingKey] as? Bool ?? false, onPower: source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue, health: health, cycles: cycles)
    }
    /// macOS's own thermal pressure; actual temperatures and fans need a privileged helper.
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    static func processes(limit: Int = 40) -> [ProcessUsage] {
        let output = run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="], timeout: 5).output
        return output.split(separator: "\n").compactMap { line -> ProcessUsage? in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { return nil }
            return ProcessUsage(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024)
        }.sorted { $0.memory > $1.memory }.prefix(limit).map { $0 }
    }
}

/// Full Disk Access cannot be queried directly; reading a protected folder tells us.
public enum FullDiskAccess {
    public enum Status: Sendable { case granted, denied, unknown }
    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        // No API reports this. One readable folder proves access; one blocked folder alone doesn't disprove it,
        // since a folder can be unreadable for other reasons.
        var blocked = false
        for relative in ["Library/Safari", "Library/Mail", "Library/Messages", ".Trash"] {
            let url = home.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return .granted }
            blocked = true
        }
        return blocked ? .denied : .unknown
    }
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// Lifetime totals from the cleanup receipts Artifloam already writes, for the Status page.
public struct CleanupHistory: Sendable {
    public let totalFreed: UInt64
    public let lastThirtyDays: UInt64
    public let cleanups: Int
    /// Freed bytes by kind of item, largest first.
    public let byKind: [(name: String, bytes: UInt64)]
    public static let empty = CleanupHistory(totalFreed: 0, lastThirtyDays: 0, cleanups: 0, byKind: [])
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> CleanupHistory {
        let folder = home.appendingPathComponent("Library/Application Support/MacSteward/Receipts")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let receipts = children(folder).filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(CleanupReceipt.self, from: Data(contentsOf: $0)) }
        var total: UInt64 = 0, recent: UInt64 = 0, kinds = [String: UInt64]()
        for receipt in receipts {
            for item in receipt.items where item.outcome == "removed" {
                total += item.bytes
                if now.timeIntervalSince(receipt.date) < 30 * 86400 { recent += item.bytes }
                kinds[kind(item.path), default: 0] += item.bytes
            }
        }
        return CleanupHistory(totalFreed: total, lastThirtyDays: recent, cleanups: receipts.count, byKind: kinds.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 })
    }
    static func kind(_ path: String) -> String {
        if path.contains("/CoreSimulator/") { return "Simulators" }
        if path.contains("/node_modules") || path.hasSuffix("/target") || path.hasSuffix("/.build") { return "Dependencies" }
        if path.contains("__pycache__") || path.contains("/.nx/") || path.contains("/.next/") || path.contains("/.angular/") { return "Project caches" }
        if path.contains("/Xcode/") || path.contains("/.gradle/") || path.contains("brew") { return "Developer caches" }
        if path.contains("/Library/Caches/") || path.contains("/.cache/") { return "App caches" }
        if path.contains("/Logs/") { return "Logs" }
        return "Other"
    }
}
