import Foundation

/// A connected iPhone, known only by its identifier until it's read. Getting its name means connecting.
public struct IPhoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    /// On a USB cable, not only reachable over Wi-Fi.
    public let cabled: Bool
    public init(id: String, cabled: Bool = false) {
        self.id = id
        self.cabled = cabled
    }
    public var label: String { "iPhone " + id.suffix(4) }
    public static func == (a: IPhoneDevice, b: IPhoneDevice) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The iPhone to read without asking. Plugging one in says which is meant. A paired iPhone on Wi-Fi may be
    /// someone else's, so it's never read by itself, and neither is one of several on cables.
    public static func automatic(from devices: [IPhoneDevice]) -> IPhoneDevice? {
        let cabled = devices.filter(\.cabled)
        return cabled.count == 1 ? cabled[0] : nil
    }
}

public struct IPhoneAppRow: Identifiable, Equatable, Sendable {
    public enum Advice: Equatable, Sendable { case offloadHelps, offloadFreesAppOnly, offloadKeepsData, cleanInWhatsApp }
    public let name: String
    public let bundleID: String
    public let appBytes: UInt64
    public let dataBytes: UInt64
    /// False when the iPhone reported no sizes for this app.
    public let measured: Bool
    /// The App Store's category, in the language of the iPhone's store.
    public var category: String? = nil
    /// When this app was first downloaded, per the App Store.
    public var firstDownloaded: Date? = nil
    /// The App Store's number for this app. Without one it can't simply be downloaded again.
    public var storeID: String? = nil
    public var id: String { bundleID }
    public var storeURL: URL? { storeID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") } }
    /// Apps whose data is often the only copy, and hard or impossible to get back.
    public enum Risk: Equatable, Sendable { case chats, loginCodes }
    public var risk: Risk? {
        let id = bundleID.lowercased(), lower = name.lowercased()
        if ["net.whatsapp.", "org.whispersystems.signal", "ch.threema."].contains(where: id.hasPrefix) || lower.contains("whatsapp") { return .chats }
        if ["authenticator", "authy", "2fa", "otp auth"].contains(where: { lower.contains($0) || id.contains($0) }) { return .loginCodes }
        return nil
    }
    public var totalBytes: UInt64 { appBytes + dataBytes }
    /// Offloading removes the app and keeps its data, so what it frees is the app part only.
    public var advice: Advice {
        // Deleting WhatsApp can lose chats that aren't backed up, so the general advice would be unsafe here.
        if bundleID.hasPrefix("net.whatsapp.") { return .cleanInWhatsApp }
        if appBytes > dataBytes { return .offloadHelps }
        return dataBytes / 2 >= appBytes ? .offloadKeepsData : .offloadFreesAppOnly
    }
}

/// What the iPhone app gets to show: only what it can't find out by itself. The iPhone app decodes the same JSON.
public struct IPhoneAppList: Codable, Equatable, Sendable {
    public static let bundleID = "com.vasquezgroup.artifloam.iphone"
    public static let fileName = "mac-app-list.json"
    public struct App: Codable, Equatable, Sendable {
        public let name: String
        public let appBytes: UInt64
        public let dataBytes: UInt64
    }
    public let readAt: Date
    public let apps: [App]
    public init(rows: [IPhoneAppRow], readAt: Date = Date()) {
        self.readAt = readAt
        apps = rows.filter(\.measured).sorted { $0.totalBytes > $1.totalBytes }.map { App(name: $0.name, appBytes: $0.appBytes, dataBytes: $0.dataBytes) }
    }
    /// Nil when Artifloam isn't on that iPhone, or there's nothing to send.
    public init?(report: IPhoneAppsReport, readAt: Date = Date()) {
        guard report.apps.contains(where: { $0.bundleID == Self.bundleID }) else { return nil }
        self.init(rows: report.apps, readAt: readAt)
    }
}

extension JSONEncoder {
    static var appList: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

public struct IPhoneAppsReport: Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String?
    public let apps: [IPhoneAppRow]
    /// Everything stored on the iPhone, as it reports. A backup is smaller than this, so it's a safe estimate.
    public var usedBytes: UInt64? = nil
    public var encryptsBackups = false
    public var lastCloudBackup: Date? = nil
    public var lastMacBackup: Date? = nil
    /// The newest backup anywhere. Deleting apps is safer with a recent one.
    public var newestBackup: Date? { [lastCloudBackup, lastMacBackup].compactMap { $0 }.max() }
    public func backupIsOld(now: Date = Date()) -> Bool { newestBackup.map { now.timeIntervalSince($0) > IPhoneBackup.oldAfter } ?? true }
    public var sizesMissing: Bool { !apps.isEmpty && !apps.contains(where: \.measured) }
    public var totalBytes: UInt64 { apps.reduce(0) { $0 + $1.totalBytes } }
}

extension String {
    /// For names people and apps chose. Removes invisible characters, which `displaySafe` would show as a "?" box. "WA Business" arrives with one in front.
    /// The joiner stays, because emoji families and some scripts need it.
    var cleanedName: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { ![.control, .format].contains($0.properties.generalCategory) || $0 == "\u{200D}" }))
    }
}

public enum IPhoneApps {
    /// Only these are taken. The same record holds the Apple ID, which is never read or kept.
    static func storeDetails(_ metadata: Any?) -> (category: String?, firstDownloaded: Date?, storeID: String?) {
        guard let data = metadata as? Data, let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil, nil) }
        let genre = (store["genre"] as? String)?.cleanedName
        let date = ((store["com.apple.iTunesStore.downloadInfo"] as? [String: Any])?["purchaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return (genre?.isEmpty == false ? genre : nil, date, (store["itemId"] as? NSNumber).map { String($0.int64Value) })
    }
    /// iPhones report these as a date or as seconds since 2001, depending on the value.
    static func backupDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? NSNumber, seconds.doubleValue > 0 { return Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
        return nil
    }
    /// The dictionary AMDeviceLookupApplications returns (bundle ID to attributes), biggest app first.
    public static func rows(from lookup: [String: Any]) -> [IPhoneAppRow] {
        lookup.compactMap { key, value -> IPhoneAppRow? in
            guard let attributes = value as? [String: Any] else { return nil }
            let bundleID = attributes["CFBundleIdentifier"] as? String ?? key
            let app = attributes["StaticDiskUsage"] as? NSNumber, data = attributes["DynamicDiskUsage"] as? NSNumber
            let name = (attributes["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
            let store = storeDetails(attributes["iTunesMetadata"])
            return IPhoneAppRow(name: name.cleanedName, bundleID: bundleID.displaySafe, appBytes: UInt64(max(0, app?.int64Value ?? 0)), dataBytes: UInt64(max(0, data?.int64Value ?? 0)), measured: app != nil || data != nil, category: store.category, firstDownloaded: store.firstDownloaded, storeID: store.storeID)
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

    /// 1 is USB. Without this function nothing counts as cabled, so nothing is read by itself.
    static let interfaceType: (@convention(c) (Device) -> Int32)? = {
        guard let handle = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW),
              let found = dlsym(handle, "AMDeviceGetInterfaceType") else { return nil }
        return unsafeBitCast(found, to: (@convention(c) (Device) -> Int32).self)
    }()
    /// Apart from `shared`, so a Mac missing only this can still read. The signature follows ios-deploy; Apple doesn't document it.
    static let uninstall: (@convention(c) (Int32, Device, CFString, Int32, UnsafeRawPointer?, Int32) -> Int32)? = {
        guard let handle = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW),
              let found = dlsym(handle, "AMDeviceSecureUninstallApplication") else { return nil }
        return unsafeBitCast(found, to: (@convention(c) (Int32, Device, CFString, Int32, UnsafeRawPointer?, Int32) -> Int32).self)
    }()
    /// Writes into one app's own Documents folder, which is all this service can reach. Signatures follow ios-deploy; Apple doesn't document them.
    struct AppFolder {
        let open: @convention(c) (Device, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        let socket: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let secureContext: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        let invalidate: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let connect: @convention(c) (Int32, UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        let setSecureContext: @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
        let close: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let openFile: @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UInt64>) -> Int32
        let write: @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafeRawPointer, UInt32) -> Int32
        let closeFile: @convention(c) (UnsafeMutableRawPointer, UInt64) -> Int32
    }
    static let appFolder: AppFolder? = {
        guard let handle = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let open: @convention(c) (Device, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = symbol("AMDeviceCreateHouseArrestService"),
              let socket: @convention(c) (UnsafeMutableRawPointer) -> Int32 = symbol("AMDServiceConnectionGetSocket"),
              let secureContext: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = symbol("AMDServiceConnectionGetSecureIOContext"),
              let invalidate: @convention(c) (UnsafeMutableRawPointer) -> Int32 = symbol("AMDServiceConnectionInvalidate"),
              let connect: @convention(c) (Int32, UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = symbol("AFCConnectionOpen"),
              let setSecureContext: @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32 = symbol("AFCConnectionSetSecureContext"),
              let close: @convention(c) (UnsafeMutableRawPointer) -> Int32 = symbol("AFCConnectionClose"),
              let openFile: @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UInt64>) -> Int32 = symbol("AFCFileRefOpen"),
              let write: @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafeRawPointer, UInt32) -> Int32 = symbol("AFCFileRefWrite"),
              let closeFile: @convention(c) (UnsafeMutableRawPointer, UInt64) -> Int32 = symbol("AFCFileRefClose")
        else { return nil }
        return AppFolder(open: open, socket: socket, secureContext: secureContext, invalidate: invalidate, connect: connect, setSecureContext: setSecureContext, close: close, openFile: openFile, write: write, closeFile: closeFile)
    }()
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
            return (handles.keys.sorted().map { id in IPhoneDevice(id: id, cabled: handles[id]?.contains { MobileDevice.interfaceType?($0) == 1 } ?? false) }, onChange)
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

    /// Whether this iPhone wants its passcode right now, or nil if it can't be asked. Blocks, so call it off the main thread.
    public func isLocked(deviceID: String) -> Bool? {
        guard let framework = MobileDevice.shared else { return nil }
        let devices: [UnsafeMutableRawPointer] = lock.withLock {
            let devices = handles[deviceID] ?? []
            devices.forEach { _ = framework.retain($0) }
            return devices
        }
        defer { devices.forEach(framework.release) }
        guard let device = devices.first, framework.connect(device) == 0 else { return nil }
        defer { _ = framework.disconnect(device) }
        guard framework.isPaired(device) == 1, framework.validatePairing(device) == 0, framework.startSession(device) == 0 else { return nil }
        defer { _ = framework.stopSession(device) }
        return (framework.copyValue(device, nil, "PasswordProtected" as CFString)?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    /// Hands the app list to Artifloam on this iPhone, which can't read it by itself. Blocks, so call it off the main thread.
    /// Only reaches that one app's Documents folder. Throws if the app isn't installed.
    public func send(_ list: IPhoneAppList, deviceID: String) throws {
        guard let framework = MobileDevice.shared, let folder = MobileDevice.appFolder else { throw IPhoneReadError.frameworkMissing }
        let data = try JSONEncoder.appList.encode(list)
        let devices: [UnsafeMutableRawPointer] = lock.withLock {
            let devices = handles[deviceID] ?? []
            devices.forEach { _ = framework.retain($0) }
            return devices
        }
        defer { devices.forEach(framework.release) }
        guard let device = devices.first else { throw IPhoneReadError.deviceGone }
        guard framework.connect(device) == 0 else { throw IPhoneReadError.unreachable }
        defer { _ = framework.disconnect(device) }
        guard framework.isPaired(device) == 1, framework.validatePairing(device) == 0, framework.startSession(device) == 0 else { throw IPhoneReadError.unreachable }
        defer { _ = framework.stopSession(device) }
        var service: UnsafeMutableRawPointer?
        var code = folder.open(device, IPhoneAppList.bundleID as CFString, nil, &service)
        guard code == 0, let service else { throw IPhoneReadError.failed(code) }
        defer { _ = folder.invalidate(service) }
        var connection: UnsafeMutableRawPointer?
        code = folder.connect(folder.socket(service), 0, &connection)
        guard code == 0, let connection else { throw IPhoneReadError.failed(code) }
        defer { _ = folder.close(connection) }
        if let context = folder.secureContext(service) { _ = folder.setSecureContext(connection, context) }
        var file: UInt64 = 0
        // 3 opens for writing and replaces what's there.
        code = folder.openFile(connection, "/Documents/" + IPhoneAppList.fileName, 3, &file)
        guard code == 0 else { throw IPhoneReadError.failed(code) }
        defer { _ = folder.closeFile(connection, file) }
        code = data.withUnsafeBytes { folder.write(connection, file, $0.baseAddress!, UInt32($0.count)) }
        guard code == 0 else { throw IPhoneReadError.failed(code) }
    }

    /// Permanently deletes one app and its data from this iPhone. Blocks, so call it off the main thread.
    /// The person has confirmed this by then. Only the review sheet's confirm button reaches it. Callers must re-read to see what really happened.
    public func uninstall(bundleID: String, deviceID: String) throws {
        guard let framework = MobileDevice.shared else { throw IPhoneReadError.frameworkMissing }
        guard let uninstall = MobileDevice.uninstall else { throw IPhoneReadError.frameworkMissing }
        let devices: [UnsafeMutableRawPointer] = lock.withLock {
            let devices = handles[deviceID] ?? []
            devices.forEach { _ = framework.retain($0) }
            return devices
        }
        defer { devices.forEach(framework.release) }
        guard let device = devices.first else { throw IPhoneReadError.deviceGone }
        guard framework.connect(device) == 0 else { throw IPhoneReadError.unreachable }
        defer { _ = framework.disconnect(device) }
        guard framework.isPaired(device) == 1, framework.validatePairing(device) == 0, framework.startSession(device) == 0 else { throw IPhoneReadError.needsTrust }
        defer { _ = framework.stopSession(device) }
        let code = uninstall(0, device, bundleID as CFString, 0, nil, 0)
        guard code == 0 else { throw IPhoneReadError.failed(code) }
    }

    private func read(_ device: UnsafeMutableRawPointer, id: String, _ framework: MobileDevice) throws -> IPhoneAppsReport {
        guard framework.connect(device) == 0 else { throw IPhoneReadError.unreachable }
        defer { _ = framework.disconnect(device) }
        guard framework.isPaired(device) == 1, framework.validatePairing(device) == 0, framework.startSession(device) == 0 else { throw IPhoneReadError.needsTrust }
        defer { _ = framework.stopSession(device) }
        let name = framework.copyValue(device, nil, "DeviceName" as CFString)?.takeRetainedValue() as? String
        let options = ["ApplicationType": "User", "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName", "StaticDiskUsage", "DynamicDiskUsage", "iTunesMetadata"]] as [String: Any]
        var found: Unmanaged<CFDictionary>?
        let code = framework.lookup(device, options as CFDictionary, &found)
        guard code == 0, let apps = found?.takeRetainedValue() as? [String: Any] else { throw IPhoneReadError.failed(code) }
        func value(_ domain: String, _ key: String) -> CFTypeRef? { framework.copyValue(device, domain as CFString, key as CFString)?.takeRetainedValue() }
        let capacity = value("com.apple.disk_usage", "TotalDataCapacity") as? NSNumber, available = value("com.apple.disk_usage", "TotalDataAvailable") as? NSNumber
        let used = capacity.flatMap { capacity in available.map { UInt64(max(0, capacity.int64Value - $0.int64Value)) } }
        return IPhoneAppsReport(deviceID: id, deviceName: name?.displaySafe, apps: IPhoneApps.rows(from: apps), usedBytes: used, encryptsBackups: value("com.apple.mobile.backup", "WillEncrypt") as? Bool ?? false,
                                lastCloudBackup: IPhoneApps.backupDate(value("com.apple.mobile.backup", "LastCloudBackupDate")), lastMacBackup: IPhoneApps.backupDate(value("com.apple.mobile.backup", "LastiTunesBackupDate")))
    }
}
