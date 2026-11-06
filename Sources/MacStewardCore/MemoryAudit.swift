import Foundation
import Darwin

public enum MemoryPressure: String, Sendable {
    case normal = "Normal", warning = "Elevated", critical = "High", unknown = "Unavailable"
    public init(dispatchLevel: Int32?) {
        switch dispatchLevel { case 1: self = .normal; case 2: self = .warning; case 4: self = .critical; default: self = .unknown }
    }
    public var title: String {
        switch self {
        case .normal: return String(localized: "Normal", comment: "Status: thermal state or memory pressure")
        case .warning: return String(localized: "Elevated", comment: "Status: memory pressure")
        case .critical: return String(localized: "High", comment: "Status: thermal state or memory pressure")
        case .unknown: return String(localized: "Unavailable", comment: "Status: thermal state or memory pressure could not be read")
        }
    }
}
public struct MemoryAppDescriptor: Sendable {
    public let pid: Int32
    public let name: String
    public let bundlePath: String
    public init(pid: Int32, name: String, bundlePath: String) { self.pid = pid; self.name = name; self.bundlePath = bundlePath }
}
public struct MemoryAppUsage: Identifiable, Sendable {
    public var id: Int32 { app.pid }
    public let app: MemoryAppDescriptor
    public let bytes: UInt64
    public let processCount: Int
    /// CPU time used since launch by the app and its helpers, in nanoseconds. Two readings give a CPU rate.
    public var cpuNanoseconds: UInt64 = 0
    public static func cpuPercent(now: UInt64, before: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds > 0, seconds <= 30, now >= before else { return nil }
        return Double(now - before) / (seconds * 1_000_000_000) * 100
    }
}
public struct MemoryReading: Sendable {
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64
    public let cached: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let swap: UInt64?
    public let pressure: MemoryPressure
    public let apps: [MemoryAppUsage]
    public let unreadableProcesses: Int
    public static func accounting(total: UInt64, free: UInt64, inactive: UInt64, speculative: UInt64, purgeable: UInt64, external: UInt64) -> (used: UInt64, available: UInt64, cached: UInt64) {
        // File-backed pages are reclaimable; avoid counting them twice with inactive pages.
        let cached = min(total, external + purgeable)
        let available = min(total, free + speculative + cached)
        return (total - available, available, cached)
    }
    /// This app's own memory, by the same measure as the list. nil if macOS doesn't say.
    public static func ownFootprint() -> UInt64? {
        var usage = rusage_info_v2()
        let code = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        return code == 0 ? usage.ri_phys_footprint : nil
    }
    public static func capture(apps: [MemoryAppDescriptor]) throws -> MemoryReading {
        // NSWorkspace can list one app twice; a repeated pid would show as two identical rows.
        var seen = Set<Int32>()
        let apps = apps.filter { seen.insert($0.pid).inserted }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw StewardError.blocked(String(localized: "macOS memory statistics are unavailable.")) }
        let page = UInt64(vm_kernel_page_size), total = ProcessInfo.processInfo.physicalMemory
        let values = accounting(total: total, free: UInt64(vm.free_count) * page, inactive: UInt64(vm.inactive_count) * page, speculative: UInt64(vm.speculative_count) * page, purgeable: UInt64(vm.purgeable_count) * page, external: UInt64(vm.external_page_count) * page)
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? MemoryPressure(dispatchLevel: level) : .unknown
        var swap = xsw_usage(); size = MemoryLayout<xsw_usage>.size
        let swapBytes: UInt64? = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : nil
        var pids = [Int32](repeating: 0, count: max(4096, Int(proc_listallpids(nil, 0)) + 256))
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let ticksToNanoseconds = Double(timebase.numer) / Double(max(1, timebase.denom))
        var totals = [Int32: (UInt64, Int, UInt64)](), unreadable = 0
        for pid in pids.prefix(max(0, Int(listed))) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { unreadable += 1; continue }
            let executable = String(cString: path)
            guard let owner = apps.first(where: { $0.pid == pid || executable.hasPrefix($0.bundlePath + "/") }) else { continue }
            var usage = rusage_info_v2()
            let code = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard code == 0 else { unreadable += 1; continue }
            let previous = totals[owner.pid] ?? (0, 0, 0)
            let cpu = UInt64(Double(usage.ri_user_time + usage.ri_system_time) * ticksToNanoseconds)
            totals[owner.pid] = (previous.0 + usage.ri_phys_footprint, previous.1 + 1, previous.2 + cpu)
        }
        let rows = apps.compactMap { app -> MemoryAppUsage? in
            guard let (bytes, processes, cpu) = totals[app.pid], bytes > 0 else { return nil }
            return MemoryAppUsage(app: app, bytes: bytes, processCount: processes, cpuNanoseconds: cpu)
        }.sorted { $0.bytes > $1.bytes }
        return MemoryReading(total: total, used: values.used, available: values.available, cached: values.cached, wired: UInt64(vm.wire_count) * page, compressed: UInt64(vm.compressor_page_count) * page, swap: swapBytes, pressure: pressure, apps: rows, unreadableProcesses: unreadable)
    }
}

/// One answer for the Performance page: is there room, and how healthy is the Mac overall.
public struct MemoryVerdict: Equatable, Sendable {
    public enum State: Sendable { case fine, busy, tight }
    public let state: State
    /// 0–100. Pressure weighs most, then swap, then how much launches at login.
    public let score: Int
    public static func evaluate(pressure: MemoryPressure, swap: UInt64?, total: UInt64, loginItems: Int?) -> MemoryVerdict {
        let swapRatio = Double(swap ?? 0) / Double(max(1, total))
        var score = 100
        switch pressure { case .warning: score -= 30; case .critical: score -= 55; default: break }
        score -= swapRatio > 0.5 ? 20 : swapRatio > 0.25 ? 10 : 0
        score -= (loginItems ?? 0) > 10 ? 10 : (loginItems ?? 0) > 5 ? 5 : 0
        let state: State = pressure == .warning || pressure == .critical ? .tight : swapRatio > 0.25 ? .busy : .fine
        return MemoryVerdict(state: state, score: max(0, min(100, score)))
    }
    /// The largest apps worth quitting: quittable, not used recently, and big enough to matter. `apps` is sorted largest first.
    public static func suggestions(_ apps: [MemoryAppUsage], recentlyUsed: Set<Int32>, canQuit: (MemoryAppUsage) -> Bool, limit: Int = 3, minimum: UInt64 = 300 << 20) -> [MemoryAppUsage] {
        Array(apps.filter { $0.bytes >= minimum && !recentlyUsed.contains($0.id) && canQuit($0) }.prefix(limit))
    }
}
