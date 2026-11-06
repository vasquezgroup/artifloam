import Foundation

/// A connected iPhone, known only by its identifier until the person picks it. Getting its name means connecting.
public struct IPhoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
    public var label: String { "iPhone " + id.suffix(4) }
}

public struct IPhoneAppRow: Identifiable, Equatable, Sendable {
    public enum Advice: Equatable, Sendable { case offloadHelps, offloadFreesAppOnly, offloadKeepsData }
    public let name: String
    public let bundleID: String
    public let appBytes: UInt64
    public let dataBytes: UInt64
    /// False when the iPhone reported no sizes for this app.
    public let measured: Bool
    public var id: String { bundleID }
    public var totalBytes: UInt64 { appBytes + dataBytes }
    /// Offloading removes the app and keeps its data, so what it frees is the app part only.
    public var advice: Advice {
        if appBytes > dataBytes { return .offloadHelps }
        return dataBytes / 2 >= appBytes ? .offloadKeepsData : .offloadFreesAppOnly
    }
}

public struct IPhoneAppsReport: Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String?
    public let apps: [IPhoneAppRow]
    public var sizesMissing: Bool { !apps.isEmpty && !apps.contains(where: \.measured) }
    public var totalBytes: UInt64 { apps.reduce(0) { $0 + $1.totalBytes } }
}

public enum IPhoneApps {
    /// The dictionary AMDeviceLookupApplications returns (bundle ID to attributes), biggest app first.
    public static func rows(from lookup: [String: Any]) -> [IPhoneAppRow] {
        lookup.compactMap { key, value -> IPhoneAppRow? in
            guard let attributes = value as? [String: Any] else { return nil }
            let bundleID = attributes["CFBundleIdentifier"] as? String ?? key
            let app = attributes["StaticDiskUsage"] as? NSNumber, data = attributes["DynamicDiskUsage"] as? NSNumber
            let name = (attributes["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
            return IPhoneAppRow(name: name.displaySafe, bundleID: bundleID.displaySafe, appBytes: UInt64(max(0, app?.int64Value ?? 0)), dataBytes: UInt64(max(0, data?.int64Value ?? 0)), measured: app != nil || data != nil)
        }.sorted { ($0.totalBytes, $1.name.lowercased()) > ($1.totalBytes, $0.name.lowercased()) }
    }
}

public enum IPhoneReadError: Error, Equatable, Sendable {
    case frameworkMissing, deviceGone, unreachable, needsTrust
    case failed(Int32)
}

/// Apple's private device framework, loaded at run time so a Mac without it just shows a message.
private struct MobileDevice {
    typealias Device = UnsafeMutableRawPointer
    /// The first argument is am_device_notification_callback_info: the device pointer, then the message as a UInt32.
    typealias Callback = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer?) -> Void
    let subscribe: @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let copyIdentifier: @convention(c) (Device) -> Unmanaged<CFString>
    let copyValue: @convention(c) (Device, CFString?, CFString) -> Unmanaged<CFTypeRef>?
    let retain: @convention(c) (Device) -> Device?
    let release: @convention(c) (Device) -> Void
    let connect: @convention(c) (Device) -> Int32
    let isPaired: @convention(c) (Device) -> Int32
    let validatePairing: @convention(c) (Device) -> Int32
    let startSession: @convention(c) (Device) -> Int32
    let stopSession: @convention(c) (Device) -> Int32
    let disconnect: @convention(c) (Device) -> Int32
    let lookup: @convention(c) (Device, CFDictionary, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32

    static let shared: MobileDevice? = {
        guard let handle = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let subscribe: @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = symbol("AMDeviceNotificationSubscribe"),
              let copyIdentifier: @convention(c) (Device) -> Unmanaged<CFString> = symbol("AMDeviceCopyDeviceIdentifier"),
              let copyValue: @convention(c) (Device, CFString?, CFString) -> Unmanaged<CFTypeRef>? = symbol("AMDeviceCopyValue"),
              let retain: @convention(c) (Device) -> Device? = symbol("AMDeviceRetain"),
              let release: @convention(c) (Device) -> Void = symbol("AMDeviceRelease"),
              let connect: @convention(c) (Device) -> Int32 = symbol("AMDeviceConnect"),
              let isPaired: @convention(c) (Device) -> Int32 = symbol("AMDeviceIsPaired"),
              let validatePairing: @convention(c) (Device) -> Int32 = symbol("AMDeviceValidatePairing"),
              let startSession: @convention(c) (Device) -> Int32 = symbol("AMDeviceStartSession"),
              let stopSession: @convention(c) (Device) -> Int32 = symbol("AMDeviceStopSession"),
              let disconnect: @convention(c) (Device) -> Int32 = symbol("AMDeviceDisconnect"),
              let lookup: @convention(c) (Device, CFDictionary, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32 = symbol("AMDeviceLookupApplications")
        else { return nil }
        return MobileDevice(subscribe: subscribe, copyIdentifier: copyIdentifier, copyValue: copyValue, retain: retain, release: release, connect: connect, isPaired: isPaired, validatePairing: validatePairing, startSession: startSession, stopSession: stopSession, disconnect: disconnect, lookup: lookup)
    }()
}

/// Lists iPhones by identifier without connecting to any. Only `read` connects, and only to the one it is given.
public final class IPhoneDeviceWatcher: @unchecked Sendable {
    private let lock = NSLock()
    /// One iPhone can appear twice, over USB and over Wi-Fi.
    private var handles = [String: [UnsafeMutableRawPointer]]()
    private var onChange: (@Sendable ([IPhoneDevice]) -> Void)?
    private var subscription: UnsafeMutableRawPointer?
    public init() {}

    /// Calls back with the current list whenever an iPhone comes or goes. False when the framework can't be used.
    public func start(onChange: @escaping @Sendable ([IPhoneDevice]) -> Void) -> Bool {
        guard let framework = MobileDevice.shared else { return false }
        lock.withLock { self.onChange = onChange }
        guard subscription == nil else { return true }
        let callback: MobileDevice.Callback = { info, context in
            guard let context, let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
            let message = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
            Unmanaged<IPhoneDeviceWatcher>.fromOpaque(context).takeUnretainedValue().handle(device, message: message)
        }
        // Retained on purpose: the framework can call back for as long as the app runs.
        return framework.subscribe(callback, 0, 0, Unmanaged.passRetained(self).toOpaque(), &subscription) == 0
    }

    private func handle(_ device: UnsafeMutableRawPointer, message: UInt32) {
        guard let framework = MobileDevice.shared else { return }
        let id = framework.copyIdentifier(device).takeRetainedValue() as String
        let (list, report): ([IPhoneDevice], (@Sendable ([IPhoneDevice]) -> Void)?) = lock.withLock {
            switch message {
            case 1:
                _ = framework.retain(device)
                handles[id, default: []].append(device)
            case 2:
                if let index = handles[id]?.firstIndex(of: device), let gone = handles[id]?.remove(at: index) { framework.release(gone) }
                if handles[id]?.isEmpty == true { handles[id] = nil }
            default: break
            }
            return (handles.keys.sorted().map(IPhoneDevice.init), onChange)
        }
        report?(list)
    }

    /// Connects to this one iPhone and asks for its apps. Blocks, so call it off the main thread. It asks only; it never pairs.
    public func read(deviceID: String) throws -> IPhoneAppsReport {
        guard let framework = MobileDevice.shared else { throw IPhoneReadError.frameworkMissing }
        let devices: [UnsafeMutableRawPointer] = lock.withLock {
            let devices = handles[deviceID] ?? []
            devices.forEach { _ = framework.retain($0) }
            return devices
        }
        defer { devices.forEach(framework.release) }
        guard !devices.isEmpty else { throw IPhoneReadError.deviceGone }
        var failure = IPhoneReadError.unreachable
        for device in devices {
            do { return try read(device, id: deviceID, framework) }
            catch let error as IPhoneReadError where error == .unreachable { continue }
            catch let error as IPhoneReadError { failure = error }
        }
        throw failure
    }

    private func read(_ device: UnsafeMutableRawPointer, id: String, _ framework: MobileDevice) throws -> IPhoneAppsReport {
        guard framework.connect(device) == 0 else { throw IPhoneReadError.unreachable }
        defer { _ = framework.disconnect(device) }
        guard framework.isPaired(device) == 1, framework.validatePairing(device) == 0, framework.startSession(device) == 0 else { throw IPhoneReadError.needsTrust }
        defer { _ = framework.stopSession(device) }
        let name = framework.copyValue(device, nil, "DeviceName" as CFString)?.takeRetainedValue() as? String
        let options = ["ApplicationType": "User", "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName", "StaticDiskUsage", "DynamicDiskUsage"]] as [String: Any]
        var found: Unmanaged<CFDictionary>?
        let code = framework.lookup(device, options as CFDictionary, &found)
        guard code == 0, let apps = found?.takeRetainedValue() as? [String: Any] else { throw IPhoneReadError.failed(code) }
        return IPhoneAppsReport(deviceID: id, deviceName: name?.displaySafe, apps: IPhoneApps.rows(from: apps))
    }
}
