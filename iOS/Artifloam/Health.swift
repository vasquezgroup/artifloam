import LocalAuthentication
import Network
import SwiftUI

/// What iOS tells an app about this iPhone at this moment. A plain value, so the scoring can be tested.
struct DeviceReading {
    var free: Int64
    var total: Int64
    var purgeable: Int64
    var passcode: Bool
    var biometrics: String?
    var iosVersion: String
    var model: String
    var lowPower: Bool
    var heat: ProcessInfo.ThermalState
    var battery: Float
    var charging: Bool
    var memory: UInt64
    var cores: Int
    var uptime: TimeInterval

    @MainActor static func current() -> DeviceReading {
        let context = LAContext()
        let passcode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        var biometrics: String?
        switch context.biometryType {
        case .faceID: biometrics = "Face ID"
        case .touchID: biometrics = "Touch ID"
        case .opticID: biometrics = "Optic ID"
        default: biometrics = nil
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let space = DiskSpace.current, info = ProcessInfo.processInfo
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let state = UIDevice.current.batteryState
        return DeviceReading(free: space.free, total: space.total, purgeable: space.purgeable, passcode: passcode, biometrics: biometrics, iosVersion: UIDevice.current.systemVersion, model: model,
                             lowPower: info.isLowPowerModeEnabled, heat: info.thermalState, battery: UIDevice.current.batteryLevel, charging: state == .charging || state == .full,
                             memory: info.physicalMemory, cores: info.activeProcessorCount, uptime: info.systemUptime)
    }
}

struct HealthItem: Identifiable, Equatable {
    enum Level: Int { case good, note, problem }
    let id: String
    let title: LocalizedStringKey
    let value: String
    let level: Level
    var advice: LocalizedStringKey? = nil

    static func == (a: HealthItem, b: HealthItem) -> Bool { a.id == b.id && a.level == b.level }
}

/// Only what iOS really reports. Apple's rules also forbid telling people to restart for no reason, so uptime is only shown.
struct HealthReport {
    let items: [HealthItem]
    let about: [(title: LocalizedStringKey, value: String)]

    /// Out of 100: each thing worth a look costs points, a real problem costs more.
    var score: Int { max(0, 100 - items.reduce(0) { $0 + ($1.level == .problem ? 30 : $1.level == .note ? 10 : 0) }) }

    init(reading r: DeviceReading) {
        var list: [HealthItem] = []
        let share = r.total > 0 ? Double(r.free) / Double(r.total) : 1
        list.append(HealthItem(id: "storage", title: "Storage", value: String(localized: "\(formatted(r.free)) free"), level: share < 0.05 ? .problem : share < 0.1 ? .note : .good,
                               advice: share < 0.1 ? "Run a scan to see what can go. Under 10% free, iOS may slow down and updates can fail." : nil))
        list.append(HealthItem(id: "passcode", title: "Passcode", value: r.passcode ? String(localized: "On") : String(localized: "Off"), level: r.passcode ? .good : .problem,
                               advice: r.passcode ? nil : "Without a passcode, anyone holding this iPhone can open it, and its data isn't protected. Turn it on in Settings, Face ID & Passcode."))
        if let name = r.biometrics { list.append(HealthItem(id: "biometrics", title: "Biometric unlock", value: name, level: .good)) }
        switch r.heat {
        case .serious: list.append(HealthItem(id: "heat", title: "Temperature", value: String(localized: "Hot"), level: .note, advice: "iOS may slow down to cool off. Give it a break from charging or heavy apps."))
        case .critical: list.append(HealthItem(id: "heat", title: "Temperature", value: String(localized: "Very hot"), level: .problem, advice: "Take it out of the sun, stop heavy apps and let it cool down."))
        default: list.append(HealthItem(id: "heat", title: "Temperature", value: String(localized: "Normal"), level: .good))
        }
        if r.battery >= 0 {
            let low = r.battery < 0.2 && !r.charging
            list.append(HealthItem(id: "battery", title: "Battery charge", value: "\(Int(r.battery * 100))%" + (r.charging ? " · " + String(localized: "Charging") : ""), level: low ? .note : .good, advice: low ? "Running low. Charge it soon." : nil))
        }
        list.append(HealthItem(id: "power", title: "Low Power Mode", value: r.lowPower ? String(localized: "On") : String(localized: "Off"), level: .good))
        items = list
        about = [("Model code", r.model), ("iOS", r.iosVersion), ("Memory", ByteCountFormatter.string(fromByteCount: Int64(r.memory), countStyle: .memory)), ("Processor cores", String(r.cores)),
                 ("On for", Duration.seconds(r.uptime).formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 2))), ("iOS can clear by itself", formatted(r.purgeable))]
    }
}

struct HealthView: View {
    @State private var report = HealthReport(reading: .current())
    @State private var network: LocalizedStringKey = "Checking"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DetailPage(theme: .space, title: "Device health") {
            HStack {
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 12)
                    Circle().trim(from: 0, to: Double(report.score) / 100).stroke(StewardTheme.space.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(report.score)").font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of 100").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 148, height: 148).accessibilityElement(children: .ignore).accessibilityLabel("Health score \(report.score) of 100")
                Spacer()
            }.padding(.vertical, 8)
            GlassCard {
                ForEach(report.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: item.level == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(item.level == .good ? StewardTheme.cleanup.accent : item.level == .note ? StewardTheme.space.accent : StewardTheme.files.accent).accessibilityHidden(true)
                            Text(item.title)
                            Spacer()
                            Text(item.value).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                        }
                        if let advice = item.advice { Text(advice).font(.footnote).foregroundStyle(.white.opacity(0.75)) }
                    }.accessibilityElement(children: .combine)
                }
            }
            GlassCard {
                Text("This iPhone").font(.headline)
                ForEach(report.about.indices, id: \.self) { index in LabeledContent(report.about[index].title, value: report.about[index].value) }
                LabeledContent("Connection") { Text(network) }
            }
            Text("Battery wear, cycle counts and available iOS updates aren't shared with apps. You'll find them in Settings, Battery and Settings, General, Software Update.").font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { report = HealthReport(reading: .current()) } }
        .task {
            // Only asks what kind of connection there is. Nothing is sent.
            let monitor = NWPathMonitor()
            let stream = AsyncStream<NWPath> { continuation in
                monitor.pathUpdateHandler = { continuation.yield($0) }
                monitor.start(queue: .global(qos: .utility))
                continuation.onTermination = { _ in monitor.cancel() }
            }
            for await path in stream {
                network = path.status != .satisfied ? "Offline" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Mobile data" : "Connected"
            }
        }
    }
}
