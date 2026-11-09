import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration
import CoreAudio

public struct CPUCounters: Sendable {
    public let user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) { self.user = user; self.system = system; self.idle = idle; self.nice = nice }
    /// Every core's ticks added up. The whole-Mac counter (HOST_CPU_LOAD_INFO) adds idle time late on Apple silicon:
    /// over a second or two it barely moves, so a busy-but-not-full Mac read as 100 %. The per-core counters keep up, like `top`.
    public static func perCore() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var cpus: natural_t = 0, info: processor_info_array_t?, count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        func ticks(_ core: Int, _ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + Int(state)])) }
        for core in 0..<Int(cpus) {
            user += ticks(core, CPU_STATE_USER); system += ticks(core, CPU_STATE_SYSTEM); idle += ticks(core, CPU_STATE_IDLE); nice += ticks(core, CPU_STATE_NICE)
        }
        return (user, system, idle, nice)
    }
    /// Kept to 32 bits so `usage` and `split` handle a wrap the same way as before; a sample's change never comes near that size.
    public static func read() -> CPUCounters? {
        perCore().map { CPUCounters(user: UInt32(truncatingIfNeeded: $0.user), system: UInt32(truncatingIfNeeded: $0.system), idle: UInt32(truncatingIfNeeded: $0.idle), nice: UInt32(truncatingIfNeeded: $0.nice)) }
    }
    public func usage(since previous: CPUCounters) -> Double? {
        func delta(_ current: UInt32, _ old: UInt32) -> UInt64 { current >= old ? UInt64(current - old) : UInt64(UInt32.max) - UInt64(old) + UInt64(current) + 1 }
        let busy = delta(user, previous.user) + delta(system, previous.system) + delta(nice, previous.nice)
        let total = busy + delta(idle, previous.idle)
        return total > 0 ? min(100, Double(busy) / Double(total) * 100) : nil
    }
    /// User, system and idle shares in percent between two samples.
    public func split(since previous: CPUCounters) -> (user: Double, system: Double, idle: Double)? {
        func delta(_ current: UInt32, _ old: UInt32) -> Double { Double(current >= old ? UInt64(current - old) : UInt64(UInt32.max) - UInt64(old) + UInt64(current) + 1) }
        let user = delta(user, previous.user) + delta(nice, previous.nice), system = delta(system, previous.system), idle = delta(idle, previous.idle)
        let total = user + system + idle
        return total > 0 ? (user / total * 100, system / total * 100, idle / total * 100) : nil
    }
}
public struct NetworkCounters: Sendable {
    public let interface: String, kind: String
    public let received: UInt64, sent: UInt64
    public init(interface: String, kind: String, received: UInt64, sent: UInt64) { self.interface = interface; self.kind = kind; self.received = received; self.sent = sent }
    public func rates(since previous: NetworkCounters, interval: TimeInterval) -> (download: Double, upload: Double)? {
        guard interface == previous.interface, interval > 0, interval <= 30, received >= previous.received, sent >= previous.sent else { return nil }
        return (Double(received - previous.received) / interval, Double(sent - previous.sent) / interval)
    }
}
public struct MacBattery: Sendable {
    public let percent: Int?
    public let charging: Bool
    public let externalPower: Bool
    public var cycleCount: Int? = nil
    /// Full-charge capacity against design capacity, as macOS's own battery health figure does.
    public var healthPercent: Int? = nil
    public var minutesRemaining: Int? = nil
    static func health(nominal: Int?, design: Int?) -> Int? {
        guard let nominal, let design, design > 0, nominal > 0 else { return nil }
        return min(100, nominal * 100 / design)
    }
}
public struct ConnectedMacDevice: Identifiable, Sendable {
    public var id: String { transport + ":" + name.lowercased() }
    public let name: String, transport: String
    /// `transport` is an identifier; this is what people see.
    public var transportTitle: String {
        switch transport {
        case "Bluetooth audio": return String(localized: "Bluetooth audio")
        case "Bluetooth Low Energy": return String(localized: "Bluetooth Low Energy")
        default: return transport
        }
    }
}
public struct MacDashboardSample: Sendable {
    public let uptime: TimeInterval
    public let cpu: CPUCounters?
    public let network: NetworkCounters?
    public let battery: MacBattery?
    /// An identifier, compared by the views. People see `thermalTitle`.
    public let thermalState: String
    public var thermalTitle: String { MacDashboard.thermalTitle(thermalState) }
    public let disk: DiskSpace
    /// nil means this inexpensive sample did not re-enumerate device names.
    public let devices: [ConnectedMacDevice]?
}

/// Read-only public system APIs. No SMC/private temperature reader, Bluetooth
/// scan, microphone stream, HID event tap, privileged helper or external request.
public enum MacDashboard {
    /// Display name of a thermal state from `MacDashboardSample` or `SystemStatusReading`.
    public static func thermalTitle(_ state: String) -> String {
        switch state {
        case "Normal": return String(localized: "Normal", comment: "Status: thermal state or memory pressure")
        case "Warm": return String(localized: "Warm", comment: "Status: thermal state")
        case "High": return String(localized: "High", comment: "Status: thermal state or memory pressure")
        case "Hot": return String(localized: "Hot", comment: "Status: thermal state")
        case "Critical": return String(localized: "Critical", comment: "Status: thermal state")
        case "Unavailable": return String(localized: "Unavailable", comment: "Status: thermal state or memory pressure could not be read")
        case "Unknown": return String(localized: "Unknown", comment: "Status: thermal state could not be read")
        default: return state
        }
    }
    public static func sample(includeDevices: Bool = true) -> MacDashboardSample {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Normal"
        case .fair: thermal = "Warm"
        case .serious: thermal = "High"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unavailable"
        }
        return MacDashboardSample(uptime: ProcessInfo.processInfo.systemUptime, cpu: CPUCounters.read(), network: networkCounters(), battery: battery(), thermalState: thermal, disk: .read(), devices: includeDevices ? connectedDevices() : nil)
    }
    private static func battery() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(), let values = raw as? [String: Any], values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = (values[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let max = (values[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Int? = current.flatMap { current in guard let max, max > 0 else { return nil }; return min(100, Swift.max(0, Int(current / max * 100))) }
            var battery = MacBattery(percent: percent, charging: (values[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false, externalPower: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            let minutes = (values[battery.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
            battery.minutesRemaining = minutes.flatMap { $0 > 0 && $0 < 6000 ? $0 : nil }
            // Cycle count and capacities live on the public AppleSmartBattery registry entry.
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var unmanaged: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS, let registry = unmanaged?.takeRetainedValue() as? [String: Any] {
                    let data = registry["BatteryData"] as? [String: Any] ?? [:]
                    func number(_ key: String) -> Int? { (registry[key] as? NSNumber ?? data[key] as? NSNumber)?.intValue }
                    battery.cycleCount = number("CycleCount")
                    battery.healthPercent = MacBattery.health(nominal: number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"), design: number("DesignCapacity"))
                }
            }
            return battery
        }
        return nil
    }
    private static func networkCounters() -> NetworkCounters? {
        var primary: String?
        for family in ["IPv4", "IPv6"] {
            if let values = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any], let name = values["PrimaryInterface"] as? String { primary = name; break }
        }
        guard let primary else { return nil }
        var kind = String(localized: "Network", comment: "Kind of network connection, when not Wi-Fi or Ethernet")
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == primary {
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                kind = type == kSCNetworkInterfaceTypeIEEE80211 as String ? String(localized: "Wi-Fi") : type == kSCNetworkInterfaceTypeEthernet as String ? String(localized: "Ethernet") : String(localized: "Network", comment: "Kind of network connection, when not Wi-Fi or Ethernet")
            }
        }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0, length < 16_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &bytes, &length, nil, 0) == 0 else { return nil }
        return bytes.withUnsafeBytes { buffer -> NetworkCounters? in
            var offset = 0
            while offset + 4 <= length {
                let size = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard size >= 4, offset + size <= length else { break }
                if buffer[offset + 3] == UInt8(RTM_IFINFO2), size >= MemoryLayout<if_msghdr2>.size {
                    let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.ifm_index), &name) != nil, String(cString: name) == primary {
                        return NetworkCounters(interface: primary, kind: kind, received: header.ifm_data.ifi_ibytes, sent: header.ifm_data.ifi_obytes)
                    }
                }
                offset += size
            }
            return nil
        }
    }
    private static func connectedDevices() -> [ConnectedMacDevice] {
        var result = bluetoothAudioDevices(), iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return uniqueDevices(result) }
        defer { IOObjectRelease(iterator) }
        var inspected = 0
        while inspected < 500 {
            let service = IOIteratorNext(iterator); if service == 0 { break }; inspected += 1
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let product = property("Product") as? String, let transport = property("Transport") as? String, ["USB", "Bluetooth", "Bluetooth Low Energy"].contains(transport), !product.localizedCaseInsensitiveContains("internal"), !(property("Built-In") as? Bool ?? false), !product.localizedCaseInsensitiveContains("keyboard backlight") else { continue }
            result.append(ConnectedMacDevice(name: product, transport: transport))
        }
        return uniqueDevices(result)
    }
    private static func uniqueDevices(_ devices: [ConnectedMacDevice]) -> [ConnectedMacDevice] {
        Array(Dictionary(devices.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private static func bluetoothAudioDevices() -> [ConnectedMacDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0, size < 64_000 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        var result = [ConnectedMacDevice]()
        for device in devices {
            var transport: UInt32 = 0, alive: UInt32 = 0, length = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioDevicePropertyTransportType
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &length, &transport) == noErr, [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport) else { continue }
            address.mSelector = kAudioDevicePropertyDeviceIsAlive; length = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &length, &alive) == noErr, alive != 0 else { continue }
            address.mSelector = kAudioObjectPropertyName
            var name: Unmanaged<CFString>?
            length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &length, &name) == noErr, let name {
                result.append(ConnectedMacDevice(name: name.takeRetainedValue() as String, transport: "Bluetooth audio"))
            }
        }
        return result
    }
}
